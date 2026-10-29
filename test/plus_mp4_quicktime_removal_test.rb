# frozen_string_literal: true

require 'test/unit'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib_plus'
require_relative 'support/mp4_investigation_fixture'

# 合成MP4で、正常Neroを保持したQuickTime限定除去の公開契約を検証する。
class PlusMP4QuickTimeRemovalTest < Test::Unit::TestCase
  include MP4InvestigationFixture

  API = TagLib::Plus::MP4

  def setup
    @dir = Dir.mktmpdir('plus-mp4-quicktime-removal-')
    @path = File.join(@dir, 'fixture.m4a')
    create_base
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'Nero開始'), TagLib::MP4::Chapter.new(500, 'Nero本編')], style: :nero)
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'QT開始'), TagLib::MP4::Chapter.new(500, 'QT本編')], style: :quicktime)
      assert file.save_chapters
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_read_selected_nero_and_plan_removal_of_broken_quicktime_keeps_non_target_content
    add_audio_reference
    original = independent_snapshot(@path)
    source_bytes = File.binread(@path)
    output = File.join(@dir, 'removed.m4a')
    API.open(@path) do |file|
      assert_equal %w[Nero開始 Nero本編], file.read_chapters(style: :nero).map(&:title)
      assert_raise(API::Error) { file.chapters }
      plan = file.plan_quicktime_chapter_removal
      assert_equal :removable, plan.status
      assert_equal :quicktime_broken, plan.reason
      assert_equal true, plan.references.size >= 2
      assert_equal :multiple_references,
        file.diagnose(:chapters)[:data][:formats][:quicktime][:reason_code]
      assert plan.frozen?
      assert plan.references.frozen?
      removed = file.remove_quicktime_chapters(plan: plan)
      assert_equal plan.references, removed
      result = file.save!(to: output)
      assert_equal File.expand_path(output), result[:output_path]
    end

    assert_equal source_bytes, File.binread(@path)
    actual = independent_snapshot(output, target_track_id: original[:quicktime_track_id])
    assert_equal original[:nero_payload_sha256], actual[:nero_payload_sha256]
    assert_equal original[:metadata], actual[:metadata]
    assert_equal original[:mdat_sha256], actual[:mdat_sha256]
    assert_equal original[:non_target_tracks], actual[:non_target_tracks]
    assert_equal [], actual[:chapter_references]
    assert_equal false, actual[:track_ids].include?(original[:quicktime_track_id])
    API.open(output) do |file|
      assert_equal %w[Nero開始 Nero本編], file.read_chapters(style: :nero).map(&:title)
      assert_nil file.read_chapters(style: :quicktime)
      assert_equal :absent, file.diagnose(:chapters)[:data][:formats][:quicktime][:status]
    end
  end

  def test_normal_quicktime_is_not_removable_and_absence_is_distinct
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :complete, plan.status
      assert_equal :quicktime_complete, plan.reason
      error = assert_raise(API::Error) { file.remove_quicktime_chapters(plan: plan) }
      assert_equal :quicktime_complete, error.code
    end

    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.remove_quicktime_chapters
      assert file.save_chapters
    end
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :absent, plan.status
      assert_equal :quicktime_absent, plan.reason
      assert_nil file.read_chapters(style: :quicktime)
      assert_equal %w[Nero開始 Nero本編], file.read_chapters(style: :nero).map(&:title)
    end
  end

  def test_policy_selects_quicktime_and_removes_broken_nero
    break_nero
    output = File.join(@dir, 'policy-removed.m4a')
    API.open(@path) do |file|
      selection = file.select_chapters
      assert_equal :quicktime, selection.style
      assert_equal %w[QT開始 QT本編], selection.chapters.map(&:title)
      plan = file.plan_broken_chapter_removal
      assert_equal :removable, plan.status
      assert_equal [:nero], plan.remove_styles
      file.define_singleton_method(:load_metadata) { raise 'source metadata must not be loaded for chapter removal' }
      file.remove_broken_chapters(plan: plan)
      result = file.save!(to: output)
      assert_instance_of API::MetadataSnapshot, result.fetch(:snapshots).fetch(:metadata)
    end
    API.open(output) do |file|
      assert_equal :quicktime, file.select_chapters.style
      assert_equal %w[QT開始 QT本編], file.select_chapters.chapters.map(&:title)
      assert_nil file.read_chapters(style: :nero)
    end
  end

  def test_explicit_samples_ignore_broken_nero_and_both_broken_formats_can_be_removed
    break_nero
    API.open(@path) do |file|
      assert_not_nil file.chapter_samples(style: :quicktime)
    end
    edit_fixture(@path) do |moov|
      track = fixture_tracks(moov).find do |node|
        fixture_child(fixture_child(node, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text'
      end
      stbl = fixture_child(fixture_child(fixture_child(track, 'mdia'), 'minf'), 'stbl')
      fixture_child(stbl, 'stsz')[:data][12, 4] = [1].pack('N')
    end
    output = File.join(@dir, 'both-removed.m4a')
    original = File.binread(@path)
    API.open(@path) do |file|
      plan = file.plan_broken_chapter_removal
      assert_equal :removable, plan.status
      assert_equal %i[nero quicktime], plan.remove_styles
      file.remove_broken_chapters(plan: plan)
      assert file.save!(to: output)[:changed]
    end
    assert_equal original, File.binread(@path)
    API.open(output) do |file|
      assert_nil file.read_chapters(style: :nero)
      assert_nil file.read_chapters(style: :quicktime)
    end
  end

  def test_broken_chapter_plan_skips_timing_and_renders_unchanged_size_once
    break_nero
    API.open(@path) do |file|
      analysis = file.send(:read_structure) do |native|
        report = TagLib::MP4.const_get(:ChapterReader, false).read(native).report
        TagLib::MP4::BrokenChapterRemovalReferences.new(native, chapter_report: report, remove_nero: true)
      end
      assert_nil analysis.timing_report
      render = analysis.method(:render)
      moov_renders = []
      analysis.define_singleton_method(:render) do |atom, delta|
        moov_renders << delta if atom[:type] == 'moov'
        render.call(atom, delta)
      end
      assert_not_nil analysis.repair_plan
      assert_equal [0], moov_renders
      file.plan_broken_chapter_removal
      assert_not_nil file.diagnose(:chapter_timing).fetch(:data).fetch(:tracks)
    end
  end

  def test_broken_chapter_removal_rejects_changed_output_metadata_without_source_snapshot
    break_nero
    original = File.binread(@path)
    output = File.join(@dir, 'changed-metadata.m4a')
    corrupt_metadata = lambda do |path|
      edit_fixture(path) do |moov|
        meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
        item = fixture_child(meta, 'ilst').fetch(:children).first
        data = item.fetch(:data).dup
        data.setbyte(data.bytesize - 1, data.getbyte(data.bytesize - 1) ^ 1)
        item[:data] = data
      end
    end
    API.open(@path) do |file|
      plan = file.plan_broken_chapter_removal
      file.remove_broken_chapters(plan: plan)
      prepare = file.method(:prepare_candidate)
      file.define_singleton_method(:prepare_candidate) do |path, changed:|
        prepare.call(path, changed: changed)
        corrupt_metadata.call(path)
      end
      file.define_singleton_method(:load_metadata) { raise 'source metadata must not be loaded' }
      error = assert_raise(API::Error) { file.save!(to: output) }
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_match(/preservation verification failed/, error.message)
    end
    assert_equal original, File.binread(@path)
    assert_equal false, File.exist?(output)
  end

  def test_broken_quicktime_with_absent_nero_is_allowed_and_time_mismatch_is_a_candidate
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.remove_nero_chapters
      assert file.save_chapters
    end
    add_audio_reference
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :removable, plan.status
      assert_equal :absent, plan.nero_status
      file.remove_quicktime_chapters(plan: plan)
      file.save!
      assert_nil file.read_chapters(style: :nero)
      assert_nil file.read_chapters(style: :quicktime)
    end

    reset_fixture
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.set_chapters(Array.new(15) { |index| TagLib::MP4::Chapter.new((index + 1) * 50, '') }, style: :quicktime)
      assert file.save_chapters
    end
    inject_chapter_timing(@path, movie_scale: 441_000_000, movie_duration: 1_605_653_349_300,
                          track_duration: 3_640_937, edit_rows: [[1_605_653_349_300 & 0xffff_ffff, 0, 65_536]])
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :removable, plan.status
      assert_equal :quicktime_time_mismatch, plan.reason
    end
  end

  def test_video_source_to_dedicated_quicktime_track_is_removable_and_preserves_content
    move_chapter_reference_to_video
    original = independent_snapshot(@path)
    output = File.join(@dir, 'video-source-removed.m4a')

    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :removable, plan.status
      assert_equal :quicktime_broken, plan.reason
      assert_equal ['vide'], plan.references.map { |row| row[:source_handler] }.uniq
      file.remove_quicktime_chapters(plan: plan)
      file.save!(to: output)
    end

    actual = independent_snapshot(output, target_track_id: original[:quicktime_track_id])
    assert_equal original[:nero_payload_sha256], actual[:nero_payload_sha256]
    assert_equal original[:metadata], actual[:metadata]
    assert_equal original[:mdat_sha256], actual[:mdat_sha256]
    assert_equal original[:non_target_tracks], actual[:non_target_tracks]
    assert_equal [], actual[:chapter_references]
    assert_equal %w[Nero開始 Nero本編], API.open(output) { |file| file.read_chapters(style: :nero).map(&:title) }
    assert_nil API.open(output) { |file| file.read_chapters(style: :quicktime) }
    assert_equal :absent, API.open(output) { |file| file.plan_quicktime_chapter_removal.status }
  end

  def test_audio_and_video_chap_references_converging_on_one_dedicated_track_are_removable
    add_audio_reference
    add_video_reference
    output = File.join(@dir, 'audio-video-source-removed.m4a')

    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :removable, plan.status
      assert_equal %w[soun vide], plan.references.map { |row| row[:source_handler] }.uniq.sort
      file.remove_quicktime_chapters(plan: plan)
      file.save!(to: output)
    end

    API.open(output) do |file|
      assert_equal %w[Nero開始 Nero本編], file.read_chapters(style: :nero).map(&:title)
      assert_nil file.read_chapters(style: :quicktime)
      assert_equal :absent, file.plan_quicktime_chapter_removal.status
    end
  end

  def test_video_source_removal_without_nero_is_allowed
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.remove_nero_chapters
      assert file.save_chapters
    end
    move_chapter_reference_to_video

    output = File.join(@dir, 'video-source-without-nero.m4a')
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :removable, plan.status
      assert_equal :absent, plan.nero_status
      file.remove_quicktime_chapters(plan: plan)
      file.save!(to: output)
    end

    API.open(output) do |file|
      assert_nil file.read_chapters(style: :nero)
      assert_nil file.read_chapters(style: :quicktime)
      assert_equal :absent, file.plan_quicktime_chapter_removal.status
    end
  end

  def test_missing_reference_shared_target_unknown_structure_and_nero_error_are_blocked
    add_audio_reference([fixture_track_id(chapter_track) , 999_999])
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :missing_reference, plan.reason
      assert_equal :missing_reference, plan.reason_code
      assert_raise(API::Error) { file.remove_quicktime_chapters(plan: plan) }
    end

    reset_fixture
    add_audio_reference
    add_reference(track_id_for('vide'), [fixture_track_id(chapter_track)], type: 'subt')
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :shared_reference, plan.reason
      assert_equal :shared_reference, plan.reason_code
    end

    reset_fixture
    add_audio_reference
    edit_fixture(@path) do |moov|
      fixture_tracks(moov).first[:children] << { type: 'uuid', data: 'unknown' }
    end
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :unsupported, plan.reason
    end

    reset_fixture
    add_audio_reference
    edit_fixture(@path) do |moov|
      chpl = fixture_child(fixture_child(moov, 'udta'), 'chpl')
      chpl[:data] = chpl[:data].byteslice(0...-1)
    end
    API.open(@path) do |file|
      assert_raise(API::Error) { file.read_chapters(style: :nero) }
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :nero_unreadable, plan.reason
    end
  end

  def test_multiple_real_quicktime_targets_are_blocked
    duplicate_chapter_track
    target_ids = chapter_track_ids
    add_audio_reference(target_ids)

    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :multiple_references, plan.reason_code
      assert_raise(API::Error) { file.remove_quicktime_chapters(plan: plan) }
    end
  end

  def test_subtitle_source_is_distinguished_from_safe_video_source
    add_reference(track_id_for('text'), [fixture_track_id(chapter_track)])

    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :subtitle_source, plan.reason_code
    end
  end

  def test_unknown_source_handler_is_blocked_with_a_distinct_reason_code
    add_unknown_source_reference

    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :unsupported_source_handler, plan.reason_code
    end
  end

  def test_stale_or_modified_plan_is_rejected_before_edit
    add_audio_reference
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      FileUtils.touch(@path)
      error = assert_raise(API::Error) { file.remove_quicktime_chapters(plan: plan) }
      assert_equal :source_changed, error.code
    end

    reset_fixture
    add_audio_reference
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      altered = API::QuickTimeChapterRemovalPlan.new(
        status: :removable, reason: :quicktime_broken, reason_code: :quicktime_broken,
        references: plan.references, target_track_id: plan.target_track_id, nero: plan.nero,
        nero_status: plan.nero_status, nero_chpl_sha256: plan.nero_chpl_sha256,
        source_path: @path, generation_token: file.instance_variable_get(:@generation).send(:token), repair: nil
      )
      error = assert_raise(API::Error) { file.remove_quicktime_chapters(plan: altered) }
      assert_equal :invalid_plan, error.code
    end
  end

  def test_save_and_cleanup_failures_keep_the_plan_and_original
    add_audio_reference
    original = File.binread(@path)
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      file.remove_quicktime_chapters(plan: plan)
      failure = IOError.new('injected verify failure')
      file.define_singleton_method(:verify_candidate) { |_| raise failure }
      error = assert_raise(API::Error) { file.save! }
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_same failure, error.cause
      assert_equal original, File.binread(@path)
      assert_equal :quicktime_chapter_removal, file.changes[:repair]
      file.singleton_class.remove_method(:verify_candidate)
      file.save!
    end
  end

  def test_cleanup_failure_reports_published_repair_output
    add_audio_reference
    output = File.join(@dir, 'cleanup-output.m4a')
    API.open(@path) do |file|
      file.remove_quicktime_chapters(plan: file.plan_quicktime_chapter_removal)
      file.define_singleton_method(:cleanup_candidate) { |_| raise IOError, 'injected cleanup failure' }
      error = assert_raise(API::Error) { file.save!(to: output) }
      assert_equal :cleanup, error.code
      assert_equal true, error.committed
      assert_equal File.expand_path(output), error.output_path
      assert_match(/cleanup failure/, error.cause.message)
      assert File.exist?(output)
      assert_equal :committed_failure, assert_raise(API::Error) { file.changes }.code
    end
    API.open(output) do |file|
      assert_nil file.read_chapters(style: :quicktime)
      assert_equal %w[Nero開始 Nero本編], file.read_chapters(style: :nero).map(&:title)
    end
  end

  private

  def reset_fixture
    create_base
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'Nero開始'), TagLib::MP4::Chapter.new(500, 'Nero本編')], style: :nero)
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'QT開始'), TagLib::MP4::Chapter.new(500, 'QT本編')], style: :quicktime)
      assert file.save_chapters
    end
  end

  def create_base
    output, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-y', '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1',
      '-f', 'lavfi', '-i', 'sine=duration=1', '-map', '0', '-map', '1',
      '-c:v', 'mpeg4', '-c:a', 'aac', @path)
    assert status.success?, "ffmpeg failed: #{output}\n#{error}"
  end

  def chapter_track
    moov, = read_fixture_moov(@path)
    fixture_tracks(moov).find do |track|
      fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text'
    end
  end

  def track_id_for(handler)
    moov, = read_fixture_moov(@path)
    track = fixture_tracks(moov).find do |candidate|
      fixture_child(fixture_child(candidate, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == handler
    end
    fixture_track_id(track)
  end

  def add_audio_reference(ids = nil)
    target = fixture_track_id(chapter_track)
    ids ||= [target]
    add_reference(track_id_for('soun'), ids)
    add_reference(track_id_for('soun'), ids) if ids == [target]
  end

  def add_video_reference
    add_reference(track_id_for('vide'), [fixture_track_id(chapter_track)])
  end

  def move_chapter_reference_to_video
    edit_fixture(@path) do |moov|
      audio = fixture_tracks(moov).find { |track| fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'soun' }
      video = fixture_tracks(moov).find { |track| fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'vide' }
      chapter_trefs = audio[:children].select do |child|
        child[:type] == 'tref' && child[:children].any? { |reference| reference[:type] == 'chap' }
      end
      raise 'fixture audio chapter reference missing' if chapter_trefs.empty?
      audio[:children] -= chapter_trefs
      video[:children].concat(Marshal.load(Marshal.dump(chapter_trefs)))
    end
  end

  def add_reference(source_id, ids, type: 'chap')
    edit_fixture(@path) do |moov|
      source = fixture_tracks(moov).find { |track| fixture_track_id(track) == source_id }
      source[:children] << { type: 'tref', children: [{ type: type, data: ids.pack('N*') }] }
    end
  end

  def break_nero
    edit_fixture(@path) do |moov|
      chpl = fixture_child(fixture_child(moov, 'udta'), 'chpl')
      chpl[:data] = chpl.fetch(:data).byteslice(0...-1)
    end
  end

  def add_unknown_source_reference
    target = fixture_track_id(chapter_track)
    edit_fixture(@path) do |moov|
      source = fixture_tracks(moov).find do |track|
        fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'vide'
      end
      handler = fixture_child(fixture_child(source, 'mdia'), 'hdlr')
      handler[:data][8, 4] = 'zzzz'
      source[:children] << { type: 'tref', children: [{ type: 'chap', data: [target].pack('N') }] }
    end
  end

  def chapter_track_ids
    moov, = read_fixture_moov(@path)
    fixture_tracks(moov).filter_map do |track|
      handler = fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4)
      fixture_track_id(track) if handler == 'text'
    end
  end

  def duplicate_chapter_track
    edit_fixture(@path) do |moov|
      source = chapter_track
      copy = Marshal.load(Marshal.dump(source))
      new_id = fixture_tracks(moov).map { |track| fixture_track_id(track) }.max + 1
      header = fixture_child(copy, 'tkhd')
      data = header.fetch(:data)
      id_offset = data.getbyte(0) == 1 ? 20 : 12
      data[id_offset, 4] = [new_id].pack('N')
      moov[:children] << copy
    end
  end

  def independent_snapshot(path, target_track_id: nil)
    moov, = read_fixture_moov(path)
    tracks = fixture_tracks(moov)
    chapter = tracks.find { |track| fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text' }
    nero = fixture_child(fixture_child(moov, 'udta'), 'chpl')
    metadata = fixture_child(fixture_child(moov, 'udta'), 'meta')
    {
      quicktime_track_id: target_track_id || fixture_track_id(chapter),
      track_ids: tracks.map { |track| fixture_track_id(track) },
      non_target_tracks: tracks.reject { |track| fixture_track_id(track) == (target_track_id || fixture_track_id(chapter)) }.map do |track|
        copy = Marshal.load(Marshal.dump(track))
        copy[:children].reject! { |child| child[:type] == 'tref' }
        render_boxes([copy])
      end,
      nero_payload_sha256: Digest::SHA256.hexdigest(nero[:data]),
      metadata: render_boxes([metadata]),
      mdat_sha256: parse_boxes(File.binread(path)).select { |node| node[:type] == 'mdat' }.map { |node| Digest::SHA256.hexdigest(node[:data]) },
      chapter_references: API.open(path) { |file| file.diagnose(:chapter_references)[:data][:references] }
    }
  end
end
