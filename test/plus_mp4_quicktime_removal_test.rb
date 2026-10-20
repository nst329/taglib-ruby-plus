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
    add_video_reference
    API.open(@path) do |file|
      plan = file.plan_quicktime_chapter_removal
      assert_equal :blocked, plan.status
      assert_equal :shared_reference, plan.reason
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

  def add_reference(source_id, ids)
    edit_fixture(@path) do |moov|
      source = fixture_tracks(moov).find { |track| fixture_track_id(track) == source_id }
      source[:children] << { type: 'tref', children: [{ type: 'chap', data: ids.pack('N*') }] }
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
