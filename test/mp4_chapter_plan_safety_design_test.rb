# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib_plus'
require_relative 'support/mp4_investigation_fixture'

# 現行の拒否とraw参照解除を実sample付きfixtureで比較し、設計の前提を検証する。
class MP4ChapterPlanSafetyDesignTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  def setup
    @dir = Dir.mktmpdir('chapter-plan-design-')
    @path = File.join(@dir, 'source.mp4')
    @output = File.join(@dir, 'output.mp4')
    subtitle = File.join(@dir, 'subtitle.srt')
    File.write(subtitle, "1\n00:00:00,000 --> 00:00:00,800\n通常字幕\n")
    _, error, status = Open3.capture3('ffmpeg', '-v', 'error',
      '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1',
      '-f', 'lavfi', '-i', 'sine=duration=1', '-i', subtitle,
      '-map', '0', '-map', '1', '-map', '2', '-c:v', 'mpeg4', '-c:a', 'aac',
      '-c:s', 'mov_text', '-metadata', 'title=保持対象', @path)
    assert status.success?, error
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.tag.item_map.insert('covr', TagLib::MP4::Item.from_cover_art_list([
        TagLib::MP4::CoverArt.new(TagLib::MP4::CoverArt::JPEG,
          File.binread(File.join(__dir__, 'data/globe_east_90.jpg')))
      ]))
      file.set_chapters([TagLib::MP4::Chapter.new(0, '開始'), TagLib::MP4::Chapter.new(500, '本編')], style: :nero)
      assert file.save
    end
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # 規格profileのtitlはraw保持し、chapter専用修復の保存後もpayloadを残す。
  def test_titl_is_preserved_by_limited_quicktime_removal
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'QT')], style: :quicktime)
      assert file.save_chapters
    end
    title = [0, (5 << 10) | (14 << 5) | 7].pack('Nn') + "タイトル\0".b
    edit_fixture(@path) { |moov| fixture_child(moov, 'udta')[:children] << { type: 'titl', data: title } }
    audio_id = fixture_tracks(read_fixture_moov(@path).first).find do |track|
      fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'soun'
    end.then { |track| fixture_track_id(track) }
    add_reference(audio_id, [chapter_track_id])
    original = Digest::SHA256.file(@path).hexdigest
    API.open(@path) do |file|
      formats = file.diagnose(:chapters)[:data][:formats]
      assert_equal :complete, formats[:nero][:status]
      assert_equal :unsupported, formats[:quicktime][:status]
      assert_equal :complete, file.diagnose(:structure)[:status]
      %i[chapter_references chapter_timing].each do |area|
        report = file.diagnose(area)
        assert_equal :complete, report[:status]
      end
      plan = file.plan_quicktime_chapter_removal
      assert_equal :removable, plan.status
      file.remove_quicktime_chapters(plan: plan)
      file.save!(to: @output)
    end
    assert_equal title, fixture_child(fixture_child(read_fixture_moov(@output).first, 'udta'), 'titl')[:data]
    assert_equal original, Digest::SHA256.file(@path).hexdigest
    API.open(@output) { |file| assert_equal :absent, file.plan_quicktime_chapter_removal.status }
  end

  # 字幕source拒否とは独立に、欠落chapだけの既存解除が全mediaを保持することを確かめる。
  def test_missing_references_from_video_audio_and_subtitle_can_be_detached_without_track_deletion
    inject_references
    original = preserved_snapshot(@path)
    source_hash = Digest::SHA256.file(@path).hexdigest
    API.open(@path) do |file|
      rows = file.diagnose(:chapter_references)[:data][:references]
      assert_equal %w[sbtl soun vide], rows.map { |row| row[:source_handler] }.sort
      assert rows.all? { |row| row[:status] == :missing && !row[:target_exists] }
      assert_equal [], file.diagnose(:chapter_timing)[:data][:tracks]
      plan = file.plan_quicktime_chapter_removal
      assert_equal :subtitle_source, plan.reason_code
      subtitle = rows.find { |row| row[:source_handler] == 'sbtl' }
      assert_include plan.message, "source_track_id=#{subtitle[:source_track_id]} handler=sbtl target_track_id=0 target_exists=false"
      limited = file.plan_limited_repairs
      assert_equal :repairable, limited.status
      assert_equal [:remove_dangling_chapter_references], limited.required_operations
      rejection = assert_raise(API::Error) do
        file.apply_limited_repairs(plan: limited, allow: [:remove_broken_quicktime_chapters])
      end
      assert_equal :repair_not_allowed, rejection.code
      assert_equal source_hash, Digest::SHA256.file(@path).hexdigest
      file.apply_limited_repairs(plan: limited, allow: [:remove_dangling_chapter_references])
      file.save!(to: @output)
    end
    assert_equal source_hash, Digest::SHA256.file(@path).hexdigest
    assert_equal original, preserved_snapshot(@output)
    API.open(@output) do |file|
      assert_equal [], file.diagnose(:chapter_references)[:data][:references]
      assert_equal :absent, file.plan_quicktime_chapter_removal.status
      assert_equal [[0, '開始'], [500, '本編']], file.read_chapters(style: :nero).map { |chapter| [chapter.start_ms, chapter.title] }
    end
  end

  def test_dangling_reference_plan_registers_only_missing_rows
    inject_references
    original = preserved_snapshot(@path)
    API.open(@path) do |file|
      plan = file.plan_dangling_chapter_reference_removal
      assert_equal :repairable, plan.status
      assert_equal :missing_reference, plan.reason_code
      assert_equal 3, plan.references.size
      assert_equal 3, plan.issues.size
      assert plan.frozen?
      assert plan.references.frozen?
      assert_equal plan.references, file.remove_dangling_chapter_references(plan: plan)
      file.save!(to: @output)
    end
    assert_equal original, preserved_snapshot(@output)
    API.open(@output) do |file|
      assert_equal :unchanged, file.plan_dangling_chapter_reference_removal.status
    end
  end

  # 同じchap内の欠落・実在を選択解除し、実在参照の順序を残す。
  def test_mixed_references_keep_existing_subtitle_targets_and_other_reference_types
    inject_references(mixed: true)
    before = preserved_snapshot(@path)
    expected = nil
    API.open(@path) do |file|
      rows = file.diagnose(:chapter_references)[:data][:references]
      missing = rows.select { |row| row[:status] == :missing }
      expected = rows.reject { |row| row[:status] == :missing }.map { |row| [row[:source_track_id], row[:target_track_id]] }
      assert_equal 6, missing.size
      assert_equal :subtitle_source, file.plan_quicktime_chapter_removal.reason_code
      plan = file.plan_dangling_chapter_reference_removal
      assert_equal missing, plan.references
      file.remove_dangling_chapter_references(plan: plan)
      file.save!(to: @output)
    end
    assert_equal before, preserved_snapshot(@output)
    API.open(@output) do |file|
      rows = file.diagnose(:chapter_references)[:data][:references]
      assert_equal expected, rows.map { |row| [row[:source_track_id], row[:target_track_id]] }
      assert rows.all? { |row| row[:target_exists] && row[:reference_index].zero? }
      assert_equal :subtitle_source, file.plan_quicktime_chapter_removal.reason_code
    end
  end

  def test_unknown_atom_blocks_reference_detachment
    inject_references
    edit_fixture(@path) { |moov| fixture_child(moov, 'udta')[:children] << { type: 'zzzz', data: 'unknown'.b } }
    original = Digest::SHA256.file(@path).hexdigest
    API.open(@path) do |file|
      assert_equal :unsupported, file.diagnose(:chapter_references)[:status]
      assert_equal :blocked, file.plan_quicktime_chapter_removal.status
      limited = file.plan_limited_repairs
      assert_equal :blocked, limited.status
      blocked = assert_raise(API::Error) { file.apply_limited_repairs(plan: limited, allow: []) }
      assert_equal :repair_blocked, blocked.code
      assert_raise(API::Error) { file.detach_chapter_references(references: []) }
    end
    assert_equal original, Digest::SHA256.file(@path).hexdigest
  end

  def test_titl_outside_movie_udta_and_malformed_payload_remain_blocked
    title = [0, (5 << 10) | (14 << 5) | 7].pack('Nn') + "タイトル\0".b
    edit_fixture(@path) do |moov|
      track = fixture_tracks(moov).first
      track[:children] << { type: 'udta', children: [{ type: 'titl', data: title }] }
    end
    API.open(@path) do |file|
      report = file.diagnose(:chapter_references)
      assert_equal :unsupported, report[:status]
      assert_include report[:issues].first[:message], 'titl location'
      assert_equal 'moov/udta/titl', report[:issues].first[:location]
    end

    edit_fixture(@path) do |moov|
      udta = fixture_child(moov, 'udta')
      fixture_tracks(moov).each { |track| track[:children].reject! { |child| child[:type] == 'udta' } }
      udta[:children] << { type: 'titl', data: [0, (5 << 10) | (14 << 5) | 7].pack('Nn') + 'unterminated'.b }
    end
    API.open(@path) do |file|
      report = file.diagnose(:chapter_references)
      assert_equal :malformed, report[:status]
      assert_include report[:issues].first[:message], 'titl UTF-8'
      assert_equal 'moov/udta/titl', report[:issues].first[:location]
    end
  end

  def test_failed_verification_keeps_original_and_cleans_partial_output
    inject_references
    original = Digest::SHA256.file(@path).hexdigest
    inventory = Dir.children(@dir).sort
    API.open(@path) do |file|
      file.detach_chapter_references(references: file.diagnose(:chapter_references)[:data][:references])
      file.define_singleton_method(:verify_candidate) { |_| raise IOError, 'injected verification failure' }
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_false error.committed
      assert_equal :verify, error.phase
    end
    assert_equal original, Digest::SHA256.file(@path).hexdigest
    assert_false File.exist?(@output)
    assert_equal inventory, Dir.children(@dir).sort
  end

  # raw構造診断の読取範囲を観測し、mdat本文と同一診断の再読込を避ける契約を固定する。
  def test_reference_diagnostics_skip_mdat_payload_and_reuse_same_report
    inject_references
    roots = parse_boxes(File.binread(@path))
    cursor = 0
    ranges = roots.filter_map do |root|
      size = render_boxes([root]).bytesize
      range = [cursor + (root[:extended] ? 16 : 8), cursor + size] if root[:type] == 'mdat'
      cursor += size
      range
    end
    reads = []
    API.open(@path, verification: :stat) do |file|
      reader = file.send(:header_reader)
      original = reader.method(:read_mp4_bytes)
      reader.define_singleton_method(:read_mp4_bytes) do |io, offset, length|
        reads << [offset, length]
        original.call(io, offset, length)
      end
      report = file.diagnose(:chapter_references)
      assert_equal :complete, report[:status]
      assert_false reads.empty?
      assert reads.none? { |offset, length| ranges.any? { |first, last| offset < last && offset + length > first } }
      first_reads = reads.dup
      assert_same report, file.diagnose(:chapter_references)
      assert_equal first_reads, reads
    end
  end

  # titl検証・保持署名・参照編集が、一回取得したmoovだけで完結することを確認する。
  def test_limited_plan_with_titl_reuses_moov_without_payload_rereads
    inject_references
    title = [0, (5 << 10) | (14 << 5) | 7].pack('Nn') + "保持対象\0".b
    edit_fixture(@path) { |moov| fixture_child(moov, 'udta')[:children] << { type: 'titl', data: title } }
    _, start, finish = read_fixture_moov(@path)
    reads = []
    API.open(@path) do |file|
      reader = file.send(:header_reader)
      original = reader.method(:read_mp4_bytes)
      reader.define_singleton_method(:read_mp4_bytes) do |io, offset, length|
        reads << [offset, length] unless io.is_a?(StringIO)
        original.call(io, offset, length)
      end
      plan = file.plan_limited_repairs
      assert_equal :repairable, plan.status
      assert_equal [:remove_dangling_chapter_references], plan.required_operations
    end
    full_moov = [start, finish - start]
    assert_equal 1, reads.count(full_moov)
    assert_empty reads.drop(reads.index(full_moov) + 1).select { |offset, length| offset >= start && offset + length <= finish },
      'titl validation and preservation must reuse the captured moov'
  end

  def test_duplicate_track_ids_block_missing_target_inference
    inject_references
    edit_fixture(@path) do |moov|
      tracks = fixture_tracks(moov)
      header = fixture_child(tracks.last, 'tkhd')[:data]
      header[header.getbyte(0) == 1 ? 20 : 12, 4] = [fixture_track_id(tracks.first)].pack('N')
    end
    original = Digest::SHA256.file(@path).hexdigest
    API.open(@path) do |file|
      report = file.diagnose(:chapter_references)
      assert_equal :malformed, report[:status]
      assert_equal 'duplicate track ID', report[:issues].first[:message]
      assert_raise(API::Error) { file.detach_chapter_references(references: []) }
    end
    assert_equal original, Digest::SHA256.file(@path).hexdigest
  end

  private

  def chapter_track_id
    moov, = read_fixture_moov(@path)
    track = fixture_tracks(moov).find do |candidate|
      fixture_child(fixture_child(candidate, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text'
    end
    fixture_track_id(track)
  end

  def add_reference(source_id, ids)
    edit_fixture(@path) do |moov|
      source = fixture_tracks(moov).find { |track| fixture_track_id(track) == source_id }
      source[:children] << { type: 'tref', children: [{ type: 'chap', data: ids.pack('N*') }] }
    end
  end

  # 全sourceに欠落参照と非chap参照を注入し、通常字幕sampleは変更しない。
  def inject_references(mixed: false)
    edit_fixture(@path) do |moov|
      tracks = fixture_tracks(moov)
      audio = tracks.find { |track| fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'soun' }
      target = fixture_track_id(audio)
      tracks.each do |track|
        ids = mixed ? [0, target, 88_888] : [0]
        track[:children] << { type: 'tref', children: [
          { type: 'chap', data: ids.pack('N*') }, { type: 'cdsc', data: [target].pack('N') }
        ] }
      end
    end
  end

  # 期待値は製品parserから生成せず、chap以外の全track atomと全payloadを比較する。
  def preserved_snapshot(path)
    roots = parse_boxes(File.binread(path))
    each_fixture_atom(roots) do |node|
      node[:children]&.reject! { |child| child[:type] == 'chap' }
    end
    moov = roots.find { |node| node[:type] == 'moov' }
    { tracks: render_boxes(fixture_tracks(moov)),
      udta: render_boxes([fixture_child(moov, 'udta')]),
      mdat: roots.select { |node| node[:type] == 'mdat' }.map { |node| Digest::SHA256.hexdigest(node[:data]) },
      packets: packet_snapshot(path) }
  end

  # packet内容と時刻をffprobeで独立観測し、コンテナの絶対posだけを比較から外す。
  def packet_snapshot(path)
    output, error, status = Open3.capture3('ffprobe', '-v', 'error', '-show_packets',
      '-show_data_hash', 'sha256', '-show_streams', '-of', 'json', path)
    assert status.success?, error
    data = JSON.parse(output)
    { packets: data.fetch('packets').map { |packet| packet.reject { |key, _| key == 'pos' } },
      streams: data.fetch('streams').map { |stream| stream.slice('index', 'codec_name', 'codec_type', 'time_base', 'duration_ts') } }
  end
end
