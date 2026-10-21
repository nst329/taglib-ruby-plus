# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'
require 'json'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib_plus'
require_relative 'support/mp4_investigation_fixture'
require_relative 'support/exclusive_publication_design_probe'

# 本体の保存処理へ試験専用の確定境界を差し込み、実renameと現行契約の不足を観測する。
class MP4SeparateOutputPublicationDesignTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4
  OPERATION = :remove_dangling_chapter_references

  def setup
    omit('actual exclusive rename probe requires macOS') unless RUBY_PLATFORM.include?('darwin')
    @dir = Dir.mktmpdir('exclusive-publication-design-')
    @path = File.join(@dir, '原本.mp4')
    @output = File.join(@dir, '別出力.mp4')
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
    @source_digest = Digest::SHA256.file(@path).hexdigest
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def test_current_link_path_keeps_result_and_snapshot_contracts
    API.open(@path) do |file|
      result = file.save!(to: @output, snapshots: [:metadata, :chapters])
      assert_equal @source_digest, result[:source_digest]
      assert_equal @source_digest, result[:output_digest]
      assert_equal %i[chapters metadata], result[:snapshots].keys.sort
    end
    assert_equal @source_digest, Digest::SHA256.file(@path).hexdigest
  end

  # linkと実renameの両方で保持条件と本文処理回数を比較し、fallbackに全面コピーを足さない。
  def test_limited_repair_fallback_preserves_content_with_identical_io_work
    inject_missing_references
    source_digest = Digest::SHA256.file(@path).hexdigest
    before = preserved_content(@path)
    runs = [nil, *ExclusivePublicationDesignProbe::UNSUPPORTED].map.with_index do |link_error, index|
      probe = ExclusivePublicationDesignProbe.new(link_error: link_error)
      output = File.join(@dir, "repaired-#{index}.mp4")
      result, work = save_limited_with_probe(probe, output)
      assert_equal before, preserved_content(output)
      assert_equal source_digest, Digest::SHA256.file(@path).hexdigest
      assert_equal Digest::SHA256.file(output).hexdigest, result[:output_digest]
      assert_equal [OPERATION], result[:operations]
      assert_equal true, result[:committed]
      assert_equal output, result[:output_path]
      assert_equal %i[chapters metadata], result[:snapshots].keys.sort
      API.open(output) { |file| assert_equal [], file.diagnose(:chapter_references)[:data][:references] }
      identity = File.stat(output).then { |stat| [stat.dev, stat.ino, stat.size] }
      assert_equal probe.candidate_identity, identity
      assert_false File.exist?(probe.candidate_path)
      assert_equal(link_error ? %i[link exclusive_rename] : [:link], probe.calls)
      [result, work]
    end
    runs.drop(1).each do |result, work|
      assert_equal runs[0][0][:output_digest], result[:output_digest]
      assert_equal runs[0][1], work
      assert_equal({ prepare_candidate: 1, verify_candidate: 1, write_copy: 1, scan: 2 }, work)
    end
  end

  def test_real_exclusive_rename_preserves_existing_output_and_symlink
    [false, true].each_with_index do |symlink, index|
      output = File.join(@dir, "conflict-#{index}.mp4")
      destination = File.join(@dir, "other-writer-#{index}")
      File.binwrite(destination, 'other writer')
      probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP,
        before_rename: ->(_candidate, path) { symlink ? File.symlink(destination, path) : File.binwrite(path, 'other writer') })
      API.open(@path) do |file|
        attach_probe(file, probe)
        error = assert_raise(API::Error) { file.save!(to: output) }
        assert_equal :publish, error.phase
        assert_equal false, error.committed
        assert_kind_of Errno::EEXIST, error.cause
        assert_equal 'other writer', File.binread(output)
        assert_equal symlink, File.symlink?(output)
        assert_equal 'other writer', File.binread(destination)
        assert_false File.exist?(error.temporary_path)
      end
    end
    assert_equal @source_digest, Digest::SHA256.file(@path).hexdigest
  end

  def test_current_link_conflict_does_not_overwrite_competitor
    API.open(@path) do |file|
      original = file.method(:publish_candidate)
      file.define_singleton_method(:publish_candidate) do |candidate, output, **options|
        File.binwrite(output, 'competitor')
        original.call(candidate, output, **options)
      end
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_kind_of Errno::EEXIST, error.cause
      assert_equal 'competitor', File.binread(@output)
      assert_false error.committed
    end
  end

  def test_link_rejection_never_triggers_fallback
    [Errno::EEXIST, Errno::EACCES, Errno::ENOSPC, Errno::EIO, Errno::ETIMEDOUT].each do |failure|
      probe = ExclusivePublicationDesignProbe.new(link_error: failure)
      API.open(@path) do |file|
        attach_probe(file, probe)
        error = assert_raise(API::Error) { file.save!(to: @output) }
        assert_kind_of failure, error.cause
        assert_equal [:link], probe.calls
        assert_equal :publish, error.phase
        assert_false File.exist?(@output)
        assert_equal @source_digest, Digest::SHA256.file(@path).hexdigest
        if [Errno::EIO, Errno::ETIMEDOUT].include?(failure)
          assert_equal :unknown, error.publication_status
          assert_nil error.committed
          assert_true File.exist?(error.temporary_path)
        else
          assert_equal :not_committed, error.publication_status
          assert_false error.committed
          assert_false File.exist?(error.temporary_path)
        end
      end
    end
  end

  def test_fallback_rejection_does_not_copy_or_retry
    [Errno::ENOTSUP, Errno::EACCES, Errno::ENOSPC, Errno::EIO].each do |failure|
      probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP, rename_error: failure)
      API.open(@path) do |file|
        attach_probe(file, probe)
        error = assert_raise(API::Error) { file.save!(to: @output) }
        assert_kind_of failure, error.cause
        assert_equal %i[link exclusive_rename], probe.calls
        assert_false File.exist?(@output)
        assert_equal @source_digest, Digest::SHA256.file(@path).hexdigest
        if failure == Errno::EIO
          assert_equal :unknown, error.publication_status
          assert_nil error.committed
          assert_true File.exist?(error.temporary_path)
        else
          assert_equal :not_committed, error.publication_status
          assert_false error.committed
          assert_false File.exist?(error.temporary_path)
        end
      end
    end
  end

  def test_generation_and_verification_failure_do_not_publish
    %i[prepare_candidate verify_candidate].each do |stage|
      probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP)
      API.open(@path) do |file|
        file.metadata = file.metadata.with(properties: { title: '更新' })
        attach_probe(file, probe)
        file.define_singleton_method(stage) { |*_, **_| raise IOError, 'injected pre-publication failure' }
        error = assert_raise(API::Error) { file.save!(to: @output) }
        assert_empty probe.calls
        assert_false error.committed
        assert_false File.exist?(@output)
        assert_false File.exist?(error.temporary_path)
        assert_equal @source_digest, Digest::SHA256.file(@path).hexdigest
      end
    end
  end

  def test_rename_success_cleanup_failure_has_historical_temporary_path
    probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP)
    API.open(@path) do |file|
      attach_probe(file, probe)
      file.define_singleton_method(:cleanup_candidate) { |_| raise IOError, 'injected cleanup failure' }
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal :cleanup, error.phase
      assert_equal true, error.committed
      assert_equal @output, error.output_path
      assert_equal probe.candidate_path, error.temporary_path
      assert_false File.exist?(error.temporary_path)
      assert_equal 'injected cleanup failure', error.cause.message
      assert_equal @source_digest, Digest::SHA256.file(@output).hexdigest
      assert_equal :committed_failure, assert_raise(API::Error) { file.changes }.code
    end
  end

  def test_publish_failure_and_cleanup_failure_keep_original_cause_chain
    probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP, rename_error: Errno::EACCES)
    API.open(@path) do |file|
      attach_probe(file, probe)
      file.define_singleton_method(:cleanup_candidate) { |_| raise IOError, 'cleanup failed too' }
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal :cleanup, error.phase
      assert_equal false, error.committed
      assert_equal :publish, error.cause.phase
      assert_kind_of Errno::EACCES, error.cause.cause
      assert_include error.message, 'cleanup failed too'
      assert_true File.exist?(error.temporary_path)
      assert_false File.exist?(@output)
    end
  end

  # 通信結果が不明な場合はcleanupを行わず、候補を所有者へ返す。
  def test_timeout_retains_candidate_and_blocks_session_reuse
    probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP, rename_error: Errno::ETIMEDOUT)
    API.open(@path) do |file|
      attach_probe(file, probe)
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal :publish, error.phase
      assert_equal :unknown, error.publication_status
      assert_nil error.committed
      assert_kind_of Errno::ETIMEDOUT, error.cause
      assert_true File.exist?(error.temporary_path)
      assert_false File.exist?(@output)
      refused = assert_raise(API::Error) { file.changes }
      assert_equal :publication_unknown, refused.code
      assert_equal :unknown, refused.publication_status
      assert_equal @source_digest, Digest::SHA256.file(@path).hexdigest
    end
  end

  def test_rename_then_timeout_reports_committed_and_blocks_session_reuse
    probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP,
      after_rename: ->(_candidate, _output) { raise Errno::ETIMEDOUT, 'simulated lost acknowledgement' })
    API.open(@path) do |file|
      attach_probe(file, probe)
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal true, error.committed
      assert_equal :committed, error.publication_status
      assert_equal :publish, error.phase
      assert_kind_of Errno::ETIMEDOUT, error.cause
      assert_equal @source_digest, Digest::SHA256.file(@output).hexdigest
      assert_false File.exist?(error.temporary_path)
      refused = assert_raise(API::Error) { file.changes }
      assert_equal :committed_failure, refused.code
    end
  end

  def test_timeout_before_rename_retains_candidate_and_blocks_session_reuse
    probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP, rename_error: Errno::ETIMEDOUT)
    API.open(@path) do |file|
      attach_probe(file, probe)
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_nil error.committed
      assert_equal :unknown, error.publication_status
      assert_true File.exist?(error.temporary_path)
      assert_false File.exist?(@output)
      assert_equal :publication_unknown, assert_raise(API::Error) { file.changes }.code
    end
  end

  def test_normal_metadata_save_and_in_place_generation_adoption
    API.open(@path) do |file|
      file.metadata = file.metadata.with(properties: { title: '別出力更新' })
      probe = ExclusivePublicationDesignProbe.new(link_error: Errno::ENOTSUP)
      attach_probe(file, probe)
      result = file.save!(to: @output, snapshots: [:metadata, :chapters])
      assert_equal ['別出力更新'], result[:snapshots][:metadata].properties[:title]
      assert_equal Digest::SHA256.file(@output).hexdigest, result[:output_digest]
      assert_equal @source_digest, Digest::SHA256.file(@path).hexdigest
    end
    API.open(@path) do |file|
      file.metadata = file.metadata.with(properties: { title: '原本置換' })
      file.save!
      assert_equal ['原本置換'], file.metadata.properties[:title]
      assert_equal false, file.changes[:changed]
    end
  end

  private

  # テストのみに確定方式を差し込み、製品の候補生成・修復・検証・cleanupはそのまま使う。
  def attach_probe(file, probe)
    original_rename = file.method(:exclusive_rename_candidate)
    file.define_singleton_method(:link_candidate) do |candidate, output|
      probe.link(candidate, output)
    end
    file.define_singleton_method(:exclusive_rename_candidate) do |candidate, output, publication:, link_error:|
      probe.before_rename(candidate, output)
      if probe.rename_error
        failure = probe.rename_error.is_a?(Class) ? probe.rename_error.new('injected rename failure') : probe.rename_error
        publication.unknown!
        publication.not_committed! if TagLib::Plus::MP4::Publication::ExclusiveRename.definitive_error?(failure)
        raise failure
      end
      original_rename.call(candidate, output, publication: publication, link_error: link_error)
      probe.after_rename(candidate, output)
    end
  end

  def inject_missing_references
    edit_fixture(@path) do |moov|
      tracks = fixture_tracks(moov)
      target = fixture_track_id(tracks.first)
      tracks.each do |track|
        track[:children] << { type: 'tref', children: [
          { type: 'chap', data: [0].pack('N') }, { type: 'cdsc', data: [target].pack('N') }
        ] }
      end
    end
  end

  # 実処理をTracePointで数え、グローバルmethodの差替えや追加コピーを避ける。
  def save_limited_with_probe(probe, output)
    work = { prepare_candidate: 0, verify_candidate: 0, write_copy: 0, scan: 0 }
    api_file = API::File
    repair = TagLib::MP4::ChapterReferenceRepair
    stream = API.const_get(:Stream, false).singleton_class
    trace = TracePoint.new(:call) do |event|
      relevant = (event.defined_class == api_file && %i[prepare_candidate verify_candidate].include?(event.method_id)) ||
        (event.defined_class == repair && event.method_id == :write_copy) ||
        (event.defined_class == stream && event.method_id == :scan)
      work[event.method_id] += 1 if relevant
    end
    result = API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal :repairable, plan.status
      file.apply_limited_repairs(plan: plan, allow: [OPERATION])
      attach_probe(file, probe)
      trace.enable { file.save!(to: output, snapshots: [:metadata, :chapters]) }
    end
    [result, work]
  ensure
    trace&.disable
  end

  # 独立parserとffprobeで、解除対象chap以外のatom・packet・時刻を比較する。
  def preserved_content(path)
    roots = parse_boxes(File.binread(path))
    each_fixture_atom(roots) { |node| node[:children]&.reject! { |child| child[:type] == 'chap' } }
    moov = roots.find { |node| node[:type] == 'moov' }
    output, error, status = Open3.capture3('ffprobe', '-v', 'error', '-show_packets',
      '-show_data_hash', 'sha256', '-show_streams', '-of', 'json', path)
    assert status.success?, error
    probe = JSON.parse(output)
    { tracks: render_boxes(fixture_tracks(moov)),
      udta: render_boxes([fixture_child(moov, 'udta')]),
      mdat: roots.select { |node| node[:type] == 'mdat' }.map { |node| Digest::SHA256.hexdigest(node[:data]) },
      packets: probe.fetch('packets').map { |packet| packet.reject { |key, _| key == 'pos' } },
      streams: probe.fetch('streams').map { |stream| stream.slice('index', 'codec_name', 'codec_type', 'time_base', 'duration_ts') } }
  end
end
