# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'open3'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_investigation_fixture'

# 設計前に現行挙動を固定する調査テスト。不正値を推測で補正せず、失敗と原本保護も検証する。
class MP4RepairInvestigationTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  MOVIE_SCALE = 441_000_000
  MOVIE_DURATION = 1_605_653_349_300
  MEDIA_DURATION = 3_640_937
  MEDIA_MOVIE_TICKS = MEDIA_DURATION * MOVIE_SCALE / 1000
  TRUNCATED_DURATION = 0xd865c3b4

  def setup
    @dir = Dir.mktmpdir('mp4-repair-investigation-')
    @path = File.join(@dir, 'synthetic.mp4')
    _out, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1', '-f', 'lavfi', '-i', 'sine=duration=1',
      '-c:v', 'mpeg4', '-c:a', 'aac', '-movflags', '+use_metadata_tags', '-metadata', 'title=fixture', @path)
    assert status.success?, error
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  # native writerで16サンプルを作り、その後は独立parserで時間フィールドだけを差し替える。
  def seed_timing(track_duration: MEDIA_DURATION, edit_rows: [[TRUNCATED_DURATION, 0, 65_536]], movie_duration: MOVIE_DURATION)
    TagLib::MP4::File.open(@path, false) do |file|
      file.set_chapters(Array.new(15) { |index| TagLib::MP4::Chapter.new((index + 1) * 50, '') }, style: :quicktime)
      assert file.save_chapters
    end
    inject_chapter_timing(@path, movie_scale: MOVIE_SCALE, movie_duration: movie_duration,
      track_duration: track_duration, edit_rows: edit_rows)
  end

  def timing(path = @path)
    TagLib::MP4::File.open(path, false) { |file| file.chapter_timing_diagnostics.first }
  end

  def probe_chapters(path, *options)
    output, error, status = Open3.capture3(ENV.fetch('FFPROBE', 'ffprobe'), '-v', 'error', *options,
      '-show_chapters', '-of', 'json', path)
    assert status.success?, error
    JSON.parse(output).fetch('chapters', [])
  end

  # 保存が生成した一時出力を観測し、既存の検証をそのまま実行して原本置換を許可しない。
  def capture_metadata_save(file)
    observed = {}
    verifier = file.method(:verify_saved_copy)
    file.define_singleton_method(:verify_saved_copy) do |path, expected, *args, **keywords|
      TagLib::MP4::File.open(path, false) do |read|
        observed[:expected] = expected
        observed[:actual] = read.send(:metadata_snapshot)
      end
      verifier.call(path, expected, *args, **keywords)
    end
    yield observed
  end

  # 設計候補の実験に限定する。ゼロindexを推測で割り当てず、元bytesを一時コピーへ戻す。
  def install_opaque_preservation_prototype(file, prepare_native: false)
    original = read_fixture_moov(file.name).first
    metadata = fixture_child(fixture_child(original, 'udta'), 'meta')
    opaque = fixture_child(metadata, 'ilst')[:children].select { |node| node[:type] == [0].pack('N') }
    raise 'prototype requires leading zero-index items' if opaque.empty?
    keys = fixture_child(metadata, 'keys')
    handler = fixture_child(metadata, 'hdlr')
    editor = method(:edit_fixture)
    lookup = method(:fixture_child)
    native_save = file.method(:save_temporary_copy)
    if prepare_native
      file.define_singleton_method(:copy_tag_state_to) do |destination|
        items = tag.item_map.to_a.reject { |key, _item| key.empty? }.map do |key, item|
          [key, *tag.send(:snapshot_item_value, item)]
        end
        destination.tag.restore_metadata_snapshot(TagLib::MP4::MetadataSnapshot.new(items: items, mdta: []))
      end
    end
    file.define_singleton_method(:save_temporary_copy) do |path, write_metadata:|
      if prepare_native
        editor.call(path) do |moov|
          target = lookup.call(lookup.call(moov, 'udta'), 'meta')
          target[:children].reject! { |node| node[:type] == 'keys' }
          lookup.call(target, 'hdlr')[:data][8, 4] = 'mdir'
          lookup.call(target, 'ilst')[:children].reject! { |node| node[:type] == [0].pack('N') }
        end
      end
      native_save.call(path, write_metadata: write_metadata)
      editor.call(path) do |moov|
        target = lookup.call(lookup.call(moov, 'udta'), 'meta')
        raise 'prototype lost metadata container' unless target
        target[:children].reject! { |node| %w[hdlr keys].include?(node[:type]) }
        target[:children].unshift(handler, keys)
        ilst = lookup.call(target, 'ilst')
        ilst[:children] = opaque + ilst[:children].reject { |node| node[:type] == [0].pack('N') }
      end
    end
  end

  def raw_opaque_metadata(path)
    moov = read_fixture_moov(path).first
    metadata = fixture_child(fixture_child(moov, 'udta'), 'meta')
    [render_boxes([fixture_child(metadata, 'hdlr'), fixture_child(metadata, 'keys')]),
     render_boxes(fixture_child(metadata, 'ilst')[:children].select { |node| node[:type] == [0].pack('N') })]
  end

  def test_after_save_restoration_alone_is_backend_dependent
    inject_metadata(@path, keys: %w[first second], indices: [0, 0])
    raw_before = raw_opaque_metadata(@path)
    original = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      legacy_view = file.tag.item_map.to_a.any? { |key, _item| key.empty? }
      install_opaque_preservation_prototype(file)
      file.tag.title = 'updated-with-opaque-preservation'
      if legacy_view
        assert file.save
        assert_equal 'updated-with-opaque-preservation', file.tag.title
      else
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal :taglib_save, error.phase
        assert_equal false, error.committed
        assert_equal original, Digest::SHA256.file(@path).hexdigest
      end
    end
    assert_equal raw_before, raw_opaque_metadata(@path)
  end

  def test_two_stage_test_only_prototype_updates_title_and_retains_opaque_bytes
    inject_metadata(@path, keys: %w[first second], indices: [0, 0])
    raw_before = raw_opaque_metadata(@path)
    TagLib::MP4::File.open(@path, false) do |file|
      install_opaque_preservation_prototype(file, prepare_native: true)
      file.tag.title = 'updated-with-opaque-preservation'
      assert file.save
      assert_equal 'updated-with-opaque-preservation', file.tag.title
    end
    assert_equal raw_before, raw_opaque_metadata(@path)
  end

  def test_fixture_editor_refuses_external_paths_and_symlinks_to_them
    Dir.mktmpdir('mp4-investigation-external-') do |outside|
      path = File.join(outside, 'protected.mp4')
      FileUtils.cp(@path, path)
      link = File.join(@dir, 'external-link.mp4')
      File.symlink(path, link)
      before = Digest::SHA256.file(path).hexdigest
      [path, link].each do |candidate|
        assert_raise(ArgumentError) { edit_fixture(candidate) { |moov| moov[:children].clear } }
      end
      assert_equal before, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_valid_indexed_metadata_and_regular_title_roundtrip
    inject_metadata(@path, keys: %w[first second], indices: [1, 2, 1])
    TagLib::MP4::File.open(@path, false) do |file|
      before = file.tag.metadata_snapshot
      assert_equal %w[first second], before.mdta.map(&:first)
      assert_equal 2, before.mdta.first.last.size
      file.tag.title = 'updated'
      assert file.save
      after = file.tag.metadata_snapshot
      assert_equal before.mdta, after.mdta
      assert_equal 'updated', file.tag.title
    end
  end

  def test_existing_native_verification_cannot_detect_loss_of_a_second_opaque_atom
    inject_metadata(@path, keys: %w[first second], indices: [0, 0])
    raw_before = raw_opaque_metadata(@path)
    TagLib::MP4::File.open(@path, false) do |file|
      install_opaque_preservation_prototype(file, prepare_native: true)
      prototype = file.method(:save_temporary_copy)
      editor = method(:edit_fixture)
      lookup = method(:fixture_child)
      file.define_singleton_method(:save_temporary_copy) do |path, write_metadata:|
        prototype.call(path, write_metadata: write_metadata)
        editor.call(path) do |moov|
          metadata = lookup.call(lookup.call(moov, 'udta'), 'meta')
          ilst = lookup.call(metadata, 'ilst')
          position = ilst[:children].rindex { |node| node[:type] == [0].pack('N') }
          ilst[:children].delete_at(position)
        end
      end
      file.tag.title = 'updated'
      # native viewは元から1件に潰れており、現行の保存検証だけでは2件目の喪失を検出できない。
      assert file.save
    end
    assert_not_equal raw_before, raw_opaque_metadata(@path)
  end

  def test_zero_index_items_collapse_in_native_view_and_are_lost_by_writer
    inject_metadata(@path, keys: %w[first second], indices: [0, 0])
    original = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      invalid = file.tag.metadata_diagnostics.issues.select { |issue| issue[:code] == :invalid_index }
      assert_equal [0, 0], invalid.map { |issue| issue[:key_index] }
      assert_raise(TagLib::MP4::MetadataSnapshotError) { file.tag.metadata_snapshot }
      # legacyは空キー1件へ潰れ、groupedは公開viewへ出さず保存を拒否する。
      empty_count = file.tag.item_map.to_a.count { |key, _item| key.empty? }
      assert_include [0, 1], empty_count
      capture_metadata_save(file) do |observed|
        file.tag.title = 'updated'
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal false, error.committed
        if empty_count == 1
          assert_equal :verify, error.phase
          assert observed[:expected][:items].to_h.key?('')
          assert_equal false, observed[:actual][:items].to_h.key?('')
          assert_not_equal observed[:expected][:mdta_keys], observed[:actual][:mdta_keys]
        else
          assert_equal :taglib_save, error.phase
          assert_empty observed
        end
      end
    end
    assert_equal original, Digest::SHA256.file(@path).hexdigest
    assert_empty Dir.glob("#{@path}.taglib-mdta-*")
    moov = parse_boxes(File.binread(@path)).find { |node| node[:type] == 'moov' }
    meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
    assert_equal 2, fixture_child(meta, 'ilst')[:children].count { |node| node[:type] == [0].pack('N') }
  end

  def test_nonzero_out_of_range_index_is_not_repaired_by_position
    inject_metadata(@path, keys: %w[first second], indices: [3])
    original = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      invalid = file.tag.metadata_diagnostics.issues.select { |issue| issue[:code] == :invalid_index }
      assert_equal [3], invalid.map { |issue| issue[:key_index] }
      assert_raise(TagLib::MP4::MetadataSnapshotError) { file.tag.metadata_snapshot }
    end
    assert_equal original, Digest::SHA256.file(@path).hexdigest
  end

  def test_reversed_keys_and_zero_items_have_no_recoverable_key_association
    two = File.join(@dir, 'reversed.mp4')
    FileUtils.cp(@path, two)
    inject_metadata(@path, keys: %w[first second], indices: [0, 0])
    inject_metadata(two, keys: %w[second first], indices: [0, 0])
    rows = [@path, two].map do |path|
      TagLib::MP4::File.open(path, false) { |file| file.tag.item_map.to_a.map { |key, item| [key, item.type, item.to_string_list] } }
    end
    assert_equal rows.first, rows.last, '同じnative viewからkeys順による割当を確定することはできない'
  end

  # chapter時間atomを注入せず、native writer自身に高timescaleの不整合を生成させる。
  def seed_native_writer_error
    # chapterの時間atomは注入しない。高timescaleのmovie headerだけを入力条件として作る。
    edit_fixture(@path) do |moov|
      movie = fixture_child(moov, 'mvhd')
      original = movie[:data]
      suffix = original.getbyte(0) == 1 ? 32 : 20
      movie[:data] = [0x01000000].pack('N') + [0, 0].pack('Q>2') + [MOVIE_SCALE].pack('N') + [MOVIE_DURATION].pack('Q>') + original.byteslice(suffix..)
    end
    TagLib::MP4::File.open(@path, false) do |file|
      file.set_chapters(Array.new(15) { |index| TagLib::MP4::Chapter.new((index + 1) * 227_000, '') }, style: :quicktime)
      assert file.save_chapters
      assert_equal 15, file.chapter_snapshot.quicktime.size
    end
  end

  def test_native_chapter_writer_preserves_movie_units_and_64_bit_duration
    seed_native_writer_error
    report = timing
    assert_equal({ version: 1, duration: MOVIE_DURATION, timescale: MOVIE_SCALE }, report[:movie])
    assert_equal({ version: 0, duration: MEDIA_DURATION, timescale: 1000 }, report[:media])
    assert_equal({ version: 1, duration: MOVIE_DURATION }, report[:track_header])
    assert_equal({ sample_count: 16, duration: MEDIA_DURATION }, report[:stts])
    assert_equal [{ version: 1, segment_duration: MOVIE_DURATION, media_time: 0, media_rate: 65_536 }], report[:edits]
    assert_equal 16, probe_chapters(@path).size
    assert_equal 16, probe_chapters(@path, '-ignore_editlist', '1').size
  end

  # 修復後に必要となるv1単一identity editの読取を、製品へ入れる前に試す。
  def prototype_timing_reader(file)
    reader_class = Class.new(TagLib::MP4.const_get(:ChapterReader)) do
      private

      def validate_edit_list(track)
        edts = child(track, 'edts', required: false)
        return unless edts
        bytes = payload(child(edts, 'elst'))
        return super unless bytes.getbyte(0) == 1
        unless bytes.bytesize == 28 && bytes.byteslice(0, 8) == [0x01000000, 1].pack('N2') &&
               bytes.byteslice(16, 12) == [0, 65_536].pack('q>l>')
          reject!('unsupported chapter edit list', :unsupported)
        end
      end
    end
    reader_class.new(file)
  end

  def test_full_movie_duration_candidate_restores_all_samples_without_changing_media
    seed_native_writer_error
    before_chapters, before_media = TagLib::MP4::File.open(@path, false) do |file|
      [file.chapter_snapshot.quicktime, file.send(:mdat_payload_signature, @path)]
    end
    inject_chapter_timing(@path, movie_scale: MOVIE_SCALE, movie_duration: MOVIE_DURATION,
      track_duration: MOVIE_DURATION, edit_rows: [[MOVIE_DURATION, 0, 65_536]])
    report = timing
    assert_empty report[:observations]
    assert_equal 1, report[:track_header][:version]
    assert_equal 1, report[:edits].first[:version]
    assert_equal MOVIE_DURATION, report[:track_header][:duration]
    assert_equal MOVIE_DURATION, report[:edits].first[:segment_duration]
    assert_equal({ sample_count: 16, duration: MEDIA_DURATION }, report[:stts])
    TagLib::MP4::File.open(@path, false) do |file|
      assert_equal before_chapters, file.chapter_snapshot.quicktime
      reader = prototype_timing_reader(file)
      reader.require_complete!
      assert_equal before_chapters, reader.values[:quicktime]
      assert_equal before_media, file.send(:mdat_payload_signature, @path)
    end
    assert_equal 16, probe_chapters(@path).size
  end

  def test_version_one_reader_prototype_still_rejects_nonidentity_edits
    seed_native_writer_error
    [[[MOVIE_DURATION, 1000, 65_536]], [[MOVIE_DURATION, -1, 65_536]],
     [[MOVIE_DURATION, 0, 131_072]], [[MOVIE_DURATION, 0, 0]]].each do |edits|
      inject_chapter_timing(@path, movie_scale: MOVIE_SCALE, movie_duration: MOVIE_DURATION,
        track_duration: MOVIE_DURATION, edit_rows: edits)
      TagLib::MP4::File.open(@path, false) do |file|
        reader = prototype_timing_reader(file)
        error = assert_raise(TagLib::MP4::ChapterSnapshotError) { reader.require_complete! }
        assert_equal :unsupported, error.code
      end
    end
  end

  def test_corrupt_chapter_timing_is_only_observed_and_needs_64_bit_duration
    seed_timing
    original = Digest::SHA256.file(@path).hexdigest
    report = timing
    assert_equal [:tkhd_elst_duration_mismatch, :elst_matches_movie_duration_low32], report[:observations]
    assert_equal({ sample_count: 16, duration: MEDIA_DURATION }, report[:stts])
    assert_equal 0, report[:track_header][:version]
    exact_duration = report[:stts][:duration] * report[:movie][:timescale] / report[:media][:timescale]
    assert_equal MEDIA_MOVIE_TICKS, exact_duration
    assert_equal 132_300, MOVIE_DURATION - exact_duration
    assert_equal 300, (MOVIE_DURATION - exact_duration) * 1_000_000 / MOVIE_SCALE
    assert_equal TRUNCATED_DURATION, MOVIE_DURATION & 0xffffffff
    assert_not_equal TRUNCATED_DURATION, exact_duration & 0xffffffff
    assert_operator exact_duration, :>, 0xffffffff
    assert_equal :not_attempted, report[:correction]
    assert_equal original, Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) { |file| assert_equal 15, file.chapter_snapshot.quicktime.size }
  end

  def test_equal_tkhd_and_elst_can_still_be_a_legitimate_short_edit
    seed_timing(track_duration: TRUNCATED_DURATION)
    report = timing
    assert_equal [:elst_matches_movie_duration_low32], report[:observations]
    assert_equal TRUNCATED_DURATION, report[:track_header][:duration]
    assert_equal TRUNCATED_DURATION, report[:edits].first[:segment_duration]
    assert_equal :not_attempted, report[:correction]
  end

  def test_full_span_identity_edit_with_distinct_timescales_is_consistent
    seed_timing(track_duration: MOVIE_DURATION, edit_rows: [[MOVIE_DURATION, 0, 65_536]])
    report = timing
    assert_empty report[:observations]
    assert_equal 1, report[:track_header][:version]
    assert_equal 1, report[:edits].first[:version]
  end

  def test_empty_edit_trim_repeat_rate_and_dwell_are_not_full_span_identity
    cases = [
      [[(MEDIA_DURATION - 1000) * MOVIE_SCALE / 1000, 1000, 65_536]],
      [[MOVIE_SCALE, -1, 65_536], [MEDIA_MOVIE_TICKS, 0, 65_536]],
      [[MEDIA_MOVIE_TICKS / 2, 0, 65_536], [MEDIA_MOVIE_TICKS / 2, 0, 65_536]],
      [[MEDIA_MOVIE_TICKS / 2, 0, 131_072]],
      [[MOVIE_DURATION, 0, 0]]
    ]
    cases.each_with_index do |edits, index|
      path = File.join(@dir, "edit-#{index}.mp4")
      # 一つの正常fixtureから時間atomだけを変え、metadata／mediaは触らない。
      seed_timing(track_duration: MOVIE_DURATION, edit_rows: [[MOVIE_DURATION, 0, 65_536]]) if index.zero?
      FileUtils.cp(@path, path)
      inject_chapter_timing(path, movie_scale: MOVIE_SCALE, movie_duration: [MOVIE_DURATION, edits.sum(&:first)].max,
        track_duration: edits.sum(&:first), edit_rows: edits)
      report = timing(path)
      assert_empty report[:observations]
      assert_equal :not_attempted, report[:correction]
      assert_equal edits.map { |duration, time, rate| [duration, time, rate] },
        report[:edits].map { |edit| edit.values_at(:segment_duration, :media_time, :media_rate) }
    end
  end

  def test_missing_edit_list_and_shorter_media_do_not_imply_full_movie_intent
    seed_timing(track_duration: MEDIA_MOVIE_TICKS, edit_rows: nil, movie_duration: MOVIE_DURATION * 2)
    report = timing
    assert_empty report[:observations]
    assert_nil report[:edits]
    assert_operator report[:movie][:duration], :>, report[:track_header][:duration]
    assert_equal :not_attempted, report[:correction]
  end

  def test_no_edit_media_conversion_allows_only_one_movie_tick_rounding
    seed_timing(track_duration: MEDIA_MOVIE_TICKS + 1, edit_rows: nil)
    assert_empty timing[:observations]
    inject_chapter_timing(@path, movie_scale: MOVIE_SCALE, movie_duration: MOVIE_DURATION,
      track_duration: MEDIA_MOVIE_TICKS + 2, edit_rows: nil)
    assert_equal [:tkhd_media_duration_mismatch], timing[:observations]
  end

  def test_mdhd_stts_disagreement_cannot_determine_a_unique_correction
    seed_timing(track_duration: MEDIA_MOVIE_TICKS, edit_rows: nil)
    edit_fixture(@path) do |moov|
      chapter = fixture_tracks(moov).find do |track|
        fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text'
      end
      fixture_child(fixture_child(chapter, 'mdia'), 'mdhd')[:data][16, 4] = [MEDIA_DURATION + 1].pack('N')
    end
    report = timing
    assert_equal [:mdhd_stts_duration_mismatch], report[:observations]
    assert_equal :not_attempted, report[:correction]
  end

  # 実ファイルは明示された場合だけ読み、一時コピー以外の保存を禁止する。
  def test_real_file_reference_repair_editlist_behavior_and_metadata_failure
    source = ENV['MP4_REPAIR_REAL_FILE']
    omit 'MP4_REPAIR_REAL_FILE is required for the read-only real-file probe' unless source
    source_digest = Digest::SHA256.file(source).hexdigest
    copy = File.join(@dir, 'real-reference-repair.mp4')
    FileUtils.cp(source, copy)
    TagLib::MP4::File.open(copy, false) do |file|
      report = file.chapter_reference_diagnostics
      assert_equal [[1, 0, 0], [2, 0, 0], [2, 1, 4], [3, 0, 0]],
        report.map { |row| row.values_at(:source_track_id, :tref_index, :target_track_id) }
      assert_equal 3, file.remove_dangling_chapter_references.size
      assert file.save_chapters
      assert_equal 15, file.chapter_snapshot.quicktime.size
      assert_equal [:tkhd_elst_duration_mismatch, :elst_matches_movie_duration_low32], file.chapter_timing_diagnostics.first[:observations]
    end
    assert_equal 1, probe_chapters(copy).size
    assert_equal 16, probe_chapters(copy, '-ignore_editlist', '1').size
    assert_equal 16, probe_chapters(copy, '-advanced_editlist', '0').size
    repaired_digest = Digest::SHA256.file(copy).hexdigest
    TagLib::MP4::File.open(copy, false) do |file|
      capture_metadata_save(file) do |observed|
        file.tag.title = 'investigation-only'
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal false, error.committed
        if observed.empty?
          assert_equal :taglib_save, error.phase
        else
          assert_equal :verify, error.phase
          assert observed[:expected][:items].to_h.key?('')
          assert_equal false, observed[:actual][:items].to_h.key?('')
          assert_not_equal observed[:expected][:mdta_keys], observed[:actual][:mdta_keys]
        end
      end
    end
    assert_equal repaired_digest, Digest::SHA256.file(copy).hexdigest
    # 失敗を再現した同じ一時コピーで、raw保持案が既存の全保存検証も通るか検証する。
    raw_before = raw_opaque_metadata(copy)
    TagLib::MP4::File.open(copy, false) do |file|
      install_opaque_preservation_prototype(file, prepare_native: true)
      file.tag.title = 'investigation-only'
      assert file.save
      assert_equal 'investigation-only', file.tag.title
      assert_equal 15, file.chapter_snapshot.quicktime.size
    end
    assert_equal raw_before, raw_opaque_metadata(copy)
    assert_equal source_digest, Digest::SHA256.file(source).hexdigest
    TagLib::MP4::File.open(copy, false) { |file| assert_equal 15, file.chapter_snapshot.quicktime.size }
    assert_empty Dir.glob("#{copy}.taglib-mdta-*")
  end
end
