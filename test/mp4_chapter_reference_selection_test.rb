# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'open3'
require 'digest'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_investigation_fixture'

# 合成fixtureで参照選択・全sample読取・保存保持の公開契約を検証する。
class MP4ChapterReferenceSelectionTest < Test::Unit::TestCase
  include MP4InvestigationFixture

  def setup
    @dir = Dir.mktmpdir('chapter-reference-design-')
    @path = File.join(@dir, 'fixture.mp4')
    captions = File.join(@dir, 'captions.srt')
    File.write(captions, "1\n00:00:00,000 --> 00:00:00,800\nordinary subtitle\n")
    _, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1',
      '-f', 'lavfi', '-i', 'sine=duration=1', '-i', captions,
      '-map', '0', '-map', '1', '-map', '2', '-c:v', 'mpeg4', '-c:a', 'aac', '-c:s', 'mov_text', @path)
    assert status.success?, error
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.set_quicktime_chapters([TagLib::MP4::Chapter.new(0, 'first'), TagLib::MP4::Chapter.new(500, 'last')])
      assert file.save_chapters
      @baseline = file.chapter_sample_snapshot
    end
    moov, = read_fixture_moov(@path)
    @ids = fixture_tracks(moov).to_h do |track|
      handler = fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4)
      [handler, fixture_track_id(track)]
    end
    @target = @baseline.track_id
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def references(mapping)
    edit_fixture(@path) do |moov|
      fixture_tracks(moov).each do |track|
        track[:children].reject! { |node| node[:type] == 'tref' }
        ids = mapping[fixture_track_id(track)]
        next unless ids
        track[:children] << { type: 'tref', children: [{ type: 'chap', data: ids.pack('N*') }] }
      end
    end
  end

  def open_file(&block)
    TagLib::MP4::Internal::File.open(@path, false, &block)
  end

  def snapshot
    open_file(&:chapter_sample_snapshot)
  end

  def test_video_reference_reads_samples_but_native_and_logical_snapshot_remain_limited
    references(@ids.fetch('vide') => [@target])
    before = Digest::SHA256.file(@path).hexdigest
    open_file do |file|
      assert_equal @baseline.samples, file.chapter_sample_snapshot.samples
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_snapshot }
      assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
      assert_empty file.quicktime_chapters # nativeは最初の音声だけを探索する
    end
    assert_equal @baseline.samples, snapshot.samples
    assert_equal @target, snapshot.track_id
    assert_equal before, Digest::SHA256.file(@path).hexdigest
  end

  def test_supplied_shape_selected_removal_keeps_candidate_subtitle_and_media
    references(@ids.fetch('vide') => [@target], @ids.fetch('soun') => [0], @ids.fetch('sbtl') => [0])
    original, = read_fixture_moov(@path)
    subtitle = fixture_tracks(original).find { |track| fixture_track_id(track) == @ids.fetch('sbtl') }
    subtitle_mdia = render_boxes([fixture_child(subtitle, 'mdia')])
    mdat_before = parse_boxes(File.binread(@path)).select { |node| node[:type] == 'mdat' }.map { |node| node[:data] }
    open_file do |file|
      assert_equal [:chapter_candidate, :missing, :missing], file.chapter_reference_diagnostics.map { |row| row[:status] }
      selected = file.chapter_reference_diagnostics.select { |row| row[:target_track_id].zero? }
      assert_equal [0, 0], file.remove_chapter_references(references: selected).map { |row| row[:target_track_id] }
      assert file.save_chapters
      assert_equal [@target], file.chapter_reference_diagnostics.map { |row| row[:target_track_id] }
      assert_equal @baseline.samples, file.chapter_sample_snapshot.samples
    end
    assert_equal @baseline.samples, snapshot.samples
    after, = read_fixture_moov(@path)
    subtitle_after = fixture_tracks(after).find { |track| fixture_track_id(track) == @ids.fetch('sbtl') }
    assert_equal subtitle_mdia, render_boxes([fixture_child(subtitle_after, 'mdia')])
    assert_equal mdat_before, parse_boxes(File.binread(@path)).select { |node| node[:type] == 'mdat' }.map { |node| node[:data] }
  end

  def test_same_target_multiple_sources_differs_from_multiple_targets
    references(@ids.fetch('vide') => [@target], @ids.fetch('soun') => [@target])
    open_file do |file|
      rows = file.chapter_reference_diagnostics
      assert_equal 2, rows.size
      assert_equal [@target], rows.map { |row| row[:target_track_id] }.uniq
      result = file.chapter_sample_snapshot
      assert_equal @baseline.samples, result.samples
      assert_nil result.source_track_id
      assert_equal 2, result.signature_version
      assert_equal 2, result.source_references.size
      assert_raise(FrozenError) { result.source_references.first[:source_track_id] = 0 }
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_snapshot }
    end
    # 独立した2番目のtext trakを複製。共有payloadでも候補IDは別であり曖昧。
    edit_fixture(@path) do |moov|
      track = fixture_tracks(moov).find { |node| fixture_track_id(node) == @target }
      duplicate = Marshal.load(Marshal.dump(track))
      fixture_child(duplicate, 'tkhd')[:data][12, 4] = [99].pack('N')
      moov[:children] << duplicate
    end
    references(@ids.fetch('soun') => [@target, 99])
    open_file do |file|
      assert_equal [:chapter_candidate, :chapter_candidate], file.chapter_reference_diagnostics.map { |row| row[:status] }
      assert_equal [@target, 99], file.chapter_reference_diagnostics.map { |row| row[:target_track_id] }.uniq
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_sample_snapshot }
    end
  end

  def test_mov_text_is_not_candidate_even_when_chap_points_to_it
    references(@ids.fetch('soun') => [@ids.fetch('sbtl')])
    before = File.binread(@path)
    open_file do |file|
      assert_equal [:inappropriate], file.chapter_reference_diagnostics.map { |row| row[:status] }
      assert_empty file.remove_dangling_chapter_references
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_sample_snapshot }
    end
    assert_equal before, File.binread(@path)
  end

  def test_current_dangling_api_removes_nonzero_missing_id_too
    references(@ids.fetch('soun') => [@target, 0, 12345])
    open_file do |file|
      assert_equal [0, 12345], file.remove_dangling_chapter_references.map { |row| row[:target_track_id] }
      assert file.save_chapters
      assert_equal [@target], file.chapter_reference_diagnostics.map { |row| row[:target_track_id] }
      assert @baseline.preserved_equal?(file.chapter_sample_snapshot)
    end
  end

  def test_selected_zero_removal_preserves_nonzero_missing_and_valid_reference
    references(@ids.fetch('soun') => [@target, 0, 12345, @target])
    open_file do |file|
      selected = file.chapter_reference_diagnostics.select { |row| row[:target_track_id].zero? }
      assert_equal selected, file.remove_chapter_references(references: selected)
      assert file.save_chapters
      rows = file.chapter_reference_diagnostics
      assert_equal [@target, 12345, @target], rows.map { |row| row[:target_track_id] }
      assert_equal [0, 1, 2], rows.map { |row| row[:reference_index] }
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_sample_snapshot }
    end
  end

  def test_selected_existing_reference_detaches_without_deleting_shared_track
    references(@ids.fetch('vide') => [@target], @ids.fetch('soun') => [@target])
    before = parse_boxes(File.binread(@path)).select { |node| node[:type] == 'mdat' }.map { |node| node[:data] }
    open_file do |file|
      selected = file.chapter_reference_diagnostics.select { |row| row[:source_handler] == 'vide' }
      assert_equal selected, file.remove_chapter_references(references: selected)
      assert file.save_chapters
      assert @baseline.preserved_equal?(file.chapter_sample_snapshot)
      selected = file.chapter_reference_diagnostics
      file.remove_chapter_references(references: selected)
      assert file.save_chapters
      assert_nil file.chapter_sample_snapshot
    end
    moov, = read_fixture_moov(@path)
    assert_include fixture_tracks(moov).map { |track| fixture_track_id(track) }, @target
    assert_equal before, parse_boxes(File.binread(@path)).select { |node| node[:type] == 'mdat' }.map { |node| node[:data] }
  end

  def test_invalid_selection_is_all_or_nothing_and_pending_plan_is_not_overwritten
    references(@ids.fetch('soun') => [@target, 0])
    before = File.binread(@path)
    open_file do |file|
      row = file.chapter_reference_diagnostics.last
      [[row, row], [row, row.merge(target_track_id: 999)], [row.merge(source_enabled: !row[:source_enabled])], nil].each do |selection|
        error = assert_raise(TagLib::MP4::ChapterReferenceError) { file.remove_chapter_references(references: selection) }
        assert_equal :invalid_selection, error.code
        assert_nil file.instance_variable_get(:@chapter_reference_repair)
      end
      assert_empty file.remove_chapter_references(references: [])
      file.remove_chapter_references(references: [row])
      error = assert_raise(TagLib::MP4::ChapterReferenceError) { file.remove_chapter_references(references: [row]) }
      assert_equal :pending_changes, error.code
      assert_equal before, File.binread(@path)
      assert file.save_chapters
    end
  end

  def test_selected_save_failure_keeps_bytes_and_plan_for_retry
    references(@ids.fetch('soun') => [@target, 0, 12345])
    before = File.binread(@path)
    open_file do |file|
      file.remove_chapter_references(references: file.chapter_reference_diagnostics.select { |row| row[:target_track_id].zero? })
      file.define_singleton_method(:verify_reference_copy) do |*|
        raise TagLib::MP4::MdtaSaveError.new('injected verification failure', phase: :verify)
      end
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
      assert_false error.committed
      assert_equal :verify, error.phase
      assert_equal before, File.binread(@path)
      assert_not_nil file.instance_variable_get(:@chapter_reference_repair)
      file.singleton_class.remove_method(:verify_reference_copy)
      assert file.save_chapters
      assert_equal [@target, 12345], file.chapter_reference_diagnostics.map { |row| row[:target_track_id] }
    end
  end

  def test_multiple_source_signature_preserves_order_and_duplicate_relations
    references(@ids.fetch('vide') => [@target], @ids.fetch('soun') => [@target, @target])
    original = snapshot
    assert original.preserved_equal?(snapshot)
    references(@ids.fetch('vide') => [@target], @ids.fetch('soun') => [@target])
    changed = snapshot
    assert_equal original.samples, changed.samples
    assert_false original.preserved_equal?(changed)
    edit_fixture(@path) do |moov|
      tracks = fixture_tracks(moov)
      video = tracks.find { |track| fixture_track_id(track) == @ids.fetch('vide') }
      audio = tracks.find { |track| fixture_track_id(track) == @ids.fetch('soun') }
      vi, ai = moov[:children].index(video), moov[:children].index(audio)
      moov[:children][vi], moov[:children][ai] = audio, video
    end
    assert_equal changed.samples, snapshot.samples
    assert_false changed.preserved_equal?(snapshot)
  end

  def test_relaxing_source_gate_does_not_accept_invalid_sample_tables
    references(@ids.fetch('vide') => [@target])
    edit_fixture(@path) do |moov|
      track = fixture_tracks(moov).find { |node| fixture_track_id(node) == @target }
      stbl = fixture_child(fixture_child(fixture_child(track, 'mdia'), 'minf'), 'stbl')
      fixture_child(stbl, 'stts')[:data][12, 4] = [0].pack('N')
    end
    before = File.binread(@path)
    assert_raise(TagLib::MP4::ChapterSnapshotError) { snapshot }
    assert_equal before, File.binread(@path)
  end

  def test_disabled_source_is_currently_readable_but_flag_is_missing_from_diagnostics
    edit_fixture(@path) do |moov|
      source = fixture_tracks(moov).find { |node| fixture_track_id(node) == @ids.fetch('soun') }
      header = fixture_child(source, 'tkhd')[:data]
      header[0, 4] = [header.unpack1('N') & ~1].pack('N')
    end
    open_file do |file|
      assert @baseline.preserved_equal?(file.chapter_sample_snapshot)
      assert_false file.chapter_reference_diagnostics.first[:source_enabled]
    end
  end
end
