# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib_plus'
require_relative 'support/mp4_investigation_fixture'

# 公開APIによる独立要否判定、限定除去、保持検証と失敗状態を確認する。
class PlusMP4LimitedRepairTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4
  ALLOW = %i[remove_invalid_mdta_indices remove_broken_quicktime_chapters].freeze

  def setup
    @dir = Dir.mktmpdir('limited-repair-')
    @path = File.join(@dir, 'source.m4a')
    @output = File.join(@dir, 'output.m4a')
    _, error, status = Open3.capture3('ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=1', '-c:a', 'aac', @path)
    assert status.success?, error
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # 正常Neroと専用QTを生成し、同一参照の重複だけで壊れたQTを再現する。
  def seed_chapters(broken: true)
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'Nero')], style: :nero)
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'QT')], style: :quicktime)
      assert file.save_chapters
    end
    return unless broken
    edit_fixture(@path) do |moov|
      audio = fixture_tracks(moov).find { |track| fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'soun' }
      audio[:children] << Marshal.load(Marshal.dump(fixture_child(audio, 'tref')))
    end
  end

  def meta(path)
    fixture_child(fixture_child(read_fixture_moov(path).first, 'udta'), 'meta')
  end

  # mdirの通常itemとmdtaのindexed itemを同じmoov/udtaへ配置する。
  def inject_mdir_mdta_pair(path, keys: %w[a], indices: [1])
    inject_metadata(path, keys: keys, indices: indices)
    edit_fixture(path) do |moov|
      udta = fixture_child(moov, 'udta')
      mdta = fixture_child(udta, 'meta')
      title = fixture_child(mdta, 'ilst')[:children].pop
      handler = [0, 0].pack('N2') + 'mdir' + "\0".b * 13
      mdir = parse_boxes(atom_box('meta', [0].pack('N') + atom_box('hdlr', handler) +
        atom_box('free', 'padding') + atom_box('ilst', render_boxes([title])))).first
      mdta[:children] << { type: 'free', data: 'mdta-padding'.b }
      udta[:children].unshift(mdir)
    end
  end

  def metadata_contexts(path)
    udta = fixture_child(read_fixture_moov(path).first, 'udta')
    udta[:children].select { |node| node[:type] == 'meta' }
  end

  def metadata_handler(meta)
    fixture_child(meta, 'hdlr')[:data].byteslice(8, 4)
  end

  def test_both_repairs_preserve_original_raw_metadata_nero_and_media
    seed_chapters
    inject_metadata(@path, keys: %w[a b], indices: [1, 0, 2, 3, 0xffffffff, 1])
    original = File.binread(@path)
    expected = meta(@path)
    fixture_child(expected, 'ilst')[:children].select! { |item| [1, 2].include?(item[:type].unpack1('N')) || item[:type] == "\xa9nam".b }
    API.open(@path) do |file|
      plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
      assert_equal :repairable, plan.status
      assert_equal ALLOW, plan.required_operations
      assert_equal [0, 3, 0xffffffff], plan.metadata[:removed].map { |item| item[:index] }
      file.apply_limited_repairs(plan: plan, allow: ALLOW)
      result = file.save!(to: @output, snapshots: [:metadata, :chapters])
      assert_equal ALLOW, result[:operations]
      assert_equal true, result[:committed]
      assert_equal Digest::SHA256.hexdigest(original), result[:source_digest]
      assert_equal Digest::SHA256.file(@output).hexdigest, result[:output_digest]
    end
    assert_equal original, File.binread(@path)
    assert_equal render_boxes([expected]), render_boxes([meta(@output)])
    roots = [@path, @output].map { |path| parse_boxes(File.binread(path)) }
    assert_equal roots[0].select { |node| node[:type] == 'mdat' }, roots[1].select { |node| node[:type] == 'mdat' }
    API.open(@output) do |file|
      assert_nil file.read_chapters(style: :quicktime)
      assert_equal ['Nero'], file.read_chapters(style: :nero).map(&:title)
      assert_equal :unchanged, file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc).status
    end
  end

  def test_metadata_permission_does_not_reject_quicktime_only
    seed_chapters
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal [:remove_broken_quicktime_chapters], plan.required_operations
      file.apply_limited_repairs(plan: plan, allow: ALLOW)
      assert file.save!(to: @output)[:committed]
    end
  end

  def test_metadata_only_preserves_normal_quicktime
    seed_chapters(broken: false)
    inject_metadata(@path, keys: %w[a], indices: [0, 1, 2])
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal [:remove_invalid_mdta_indices], plan.required_operations
      file.apply_limited_repairs(plan: plan, allow: ALLOW)
      file.save!(to: @output)
    end
    assert_equal ['QT'], API.open(@output) { |file| file.read_chapters(style: :quicktime).map(&:title) }
  end

  def test_normal_input_is_noop
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal :unchanged, plan.status
      assert_equal [], file.apply_limited_repairs(plan: plan, allow: ALLOW)
      assert_equal false, file.save![:changed]
    end
    assert_equal false, File.exist?(@output)
  end

  def test_safe_mdir_mdta_pair_is_diagnosed_and_saved_unchanged
    inject_mdir_mdta_pair(@path, indices: [1])
    original_contexts = metadata_contexts(@path).map { |context| render_boxes([context]) }
    API.open(@path) do |file|
      report = file.diagnose(:metadata)
      assert_equal :complete, report[:status]
      assert_equal [], report[:issues]
      plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
      assert_equal :unchanged, plan.status
      assert_equal :metadata_complete, plan.metadata[:reason_code]
      assert_equal [], file.apply_limited_repairs(plan: plan, allow: ALLOW)
      file.save!(to: @output)
    end
    assert_equal original_contexts, metadata_contexts(@output).map { |context| render_boxes([context]) }
    API.open(@output) do |file|
      assert_equal :unchanged, file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc).status
    end
  end

  def test_safe_pair_removes_only_invalid_mdta_indices_and_preserves_mdir
    seed_chapters(broken: false)
    inject_mdir_mdta_pair(@path, keys: %w[a b], indices: [1, 0, 2, 0xffffffff])
    original = File.binread(@path)
    before = metadata_contexts(@path)
    mdir_raw = render_boxes([before.find { |context| metadata_handler(context) == 'mdir' }])
    output = @output
    API.open(@path) do |file|
      plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
      assert_equal :repairable, plan.status
      assert_equal [:remove_invalid_mdta_indices], plan.required_operations
      assert_equal [0, 0xffffffff], plan.metadata[:removed].map { |row| row[:index] }
      file.apply_limited_repairs(plan: plan, allow: ALLOW)
      result = file.save!(to: output)
      assert_equal true, result[:committed]
    end
    assert_equal original, File.binread(@path)
    after = metadata_contexts(output)
    assert_equal %w[mdir mdta], after.map { |context| metadata_handler(context) }
    assert_equal mdir_raw, render_boxes([after.find { |context| metadata_handler(context) == 'mdir' }])
    mdta = after.find { |context| metadata_handler(context) == 'mdta' }
    assert_equal [[1].pack('N'), [2].pack('N')], fixture_child(mdta, 'ilst')[:children].map { |item| item[:type] }
    assert_equal ['QT'], API.open(output) { |file| file.read_chapters(style: :quicktime).map(&:title) }
    API.open(output) do |file|
      assert_equal :unchanged, file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc).status
    end
  end

  def test_unsafe_multiple_context_sets_remain_blocked
    %i[three same_mdir same_mdta separate_udta].each do |variant|
      path = File.join(@dir, "#{variant}.m4a")
      FileUtils.cp(@path, path)
      inject_mdir_mdta_pair(path, indices: [1])
      edit_fixture(path) do |moov|
        udta = fixture_child(moov, 'udta')
        contexts = udta[:children].select { |node| node[:type] == 'meta' }
        case variant
        when :three
          udta[:children] << Marshal.load(Marshal.dump(contexts.first))
        when :same_mdir
          udta[:children].delete(contexts.find { |node| metadata_handler(node) == 'mdta' })
          duplicate = Marshal.load(Marshal.dump(contexts.find { |node| metadata_handler(node) == 'mdir' }))
          udta[:children] << duplicate
        when :same_mdta
          udta[:children].delete(contexts.find { |node| metadata_handler(node) == 'mdir' })
          duplicate = Marshal.load(Marshal.dump(contexts.find { |node| metadata_handler(node) == 'mdta' }))
          udta[:children] << duplicate
        when :separate_udta
          mdta = contexts.find { |node| metadata_handler(node) == 'mdta' }
          udta[:children].delete(mdta)
          moov[:children] << { type: 'udta', children: [mdta] }
        end
      end
      API.open(path) do |file|
        plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
        assert_equal :blocked, plan.status, variant
        assert_equal :multiple_meta, plan.metadata[:reason_code], variant
        assert_raise(API::Error) { file.apply_limited_repairs(plan: plan, allow: ALLOW) }
      end
    end
  end

  def test_malformed_pair_is_blocked_by_diagnosis_and_planning
    %i[unknown_handler missing_handler unknown_child duplicate_ilst].each do |variant|
      path = File.join(@dir, "#{variant}.m4a")
      FileUtils.cp(@path, path)
      inject_mdir_mdta_pair(path)
      edit_fixture(path) do |moov|
        mdir = fixture_child(fixture_child(moov, 'udta'), 'meta')
        case variant
        when :unknown_handler then fixture_child(mdir, 'hdlr')[:data][8, 4] = 'zzzz'
        when :missing_handler then mdir[:children].reject! { |node| node[:type] == 'hdlr' }
        when :unknown_child then mdir[:children] << { type: 'zzzz', data: 'unknown'.b }
        when :duplicate_ilst
          mdir[:children] << Marshal.load(Marshal.dump(fixture_child(mdir, 'ilst')))
        end
      end
      original = File.binread(path)
      API.open(path) do |file|
        report = file.diagnose(:metadata)
        assert_not_equal :complete, report[:status], variant
        assert_not_empty report[:issues], variant
        plan = file.plan_limited_repairs
        assert_equal :blocked, plan.status, variant
        assert_raise(API::Error) { file.apply_limited_repairs(plan: plan, allow: ALLOW) }
      end
      assert_equal original, File.binread(path)
    end
  end

  def test_explicit_indexed_layout_handles_fourcc_shaped_index
    inject_metadata(@path, keys: ['a'], indices: [1, 'zzzz'.unpack1('N'), 0xffffffff])
    edit_fixture(@path) { |moov| fixture_child(fixture_child(fixture_child(moov, 'udta'), 'meta'), 'ilst')[:children].pop }
    API.open(@path) do |file|
      assert_equal :blocked, file.plan_limited_repairs.status
      plan = file.plan_limited_repairs(mdta_layout: :indexed)
      assert_equal [0x7a7a7a7a, 0xffffffff], plan.metadata[:removed].map { |row| row[:index] }
      file.apply_limited_repairs(plan: plan, allow: ALLOW)
      file.save!(to: @output)
    end
    assert_equal [1], fixture_child(meta(@output), 'ilst')[:children].map { |item| item[:type].unpack1('N') }
  end

  def test_bad_keys_are_blocked_even_when_quicktime_is_removable
    seed_chapters
    inject_metadata(@path, keys: ['a'], indices: [0])
    edit_fixture(@path) { |moov| fixture_child(fixture_child(fixture_child(moov, 'udta'), 'meta'), 'keys')[:data][4, 4] = [2].pack('N') }
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal :blocked, plan.status
      assert_equal :required, plan.quicktime[:status]
      assert_raise(API::Error) { file.apply_limited_repairs(plan: plan, allow: ALLOW) }
      assert_equal false, file.changes[:changed]
    end
  end

  def test_missing_permission_and_other_session_plan_are_rejected
    inject_metadata(@path, keys: ['a'], indices: [0])
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      error = assert_raise(API::Error) { file.apply_limited_repairs(plan: plan, allow: []) }
      assert_equal :repair_not_allowed, error.code
      API.open(@path) do |other|
        error = assert_raise(API::Error) { other.apply_limited_repairs(plan: plan, allow: ALLOW) }
        assert_equal :invalid_plan, error.code
      end
      assert_equal false, file.changes[:changed]
    end
  end

  def test_source_change_invalidates_plan
    inject_metadata(@path, keys: ['a'], indices: [0])
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      File.open(@path, 'ab') { |io| io.write('changed') }
      error = assert_raise(API::Error) { file.apply_limited_repairs(plan: plan, allow: ALLOW) }
      assert_equal :source_changed, error.code
    end
  end

  def test_in_place_save_is_refused
    inject_metadata(@path, keys: ['a'], indices: [0])
    API.open(@path) do |file|
      file.apply_limited_repairs(plan: file.plan_limited_repairs, allow: ALLOW)
      error = assert_raise(API::Error) { file.save! }
      assert_equal :separate_output_required, error.code
    end
  end

  def test_tampered_survivor_is_rejected_and_plan_can_retry
    inject_metadata(@path, keys: ['a'], indices: [0, 1])
    original = File.binread(@path)
    API.open(@path) do |file|
      file.apply_limited_repairs(plan: file.plan_limited_repairs, allow: ALLOW)
      prepare = file.method(:prepare_candidate)
      file.define_singleton_method(:prepare_candidate) do |path, **args|
        prepare.call(path, **args)
        data = File.binread(path).sub('opaque-1', 'altered!')
        File.binwrite(path, data)
      end
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal false, error.committed
      assert_equal false, File.exist?(@output)
      assert_equal original, File.binread(@path)
      file.singleton_class.remove_method(:prepare_candidate)
      assert file.save!(to: @output)[:committed]
    end
  end

  def test_plan_reads_moov_once_and_reuses_it_for_metadata_and_signatures
    seed_chapters
    inject_metadata(@path, keys: ['a'], indices: [0, 1, 2])
    _, start, finish = read_fixture_moov(@path)
    klass = API.const_get(:HeaderReader, false)
    original = klass.instance_method(:read_mp4_bytes)
    calls = []
    klass.define_method(:read_mp4_bytes) do |io, offset, count|
      calls << [offset, count] unless io.is_a?(StringIO)
      original.bind_call(self, io, offset, count)
    end
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal ALLOW, plan.required_operations
    end
    full = [start, finish - start]
    assert_equal 1, calls.count(full)
    after = calls.drop(calls.index(full) + 1)
    assert_empty after.select { |offset, count| offset >= start && offset + count <= finish },
      'metadata and preservation must use cached moov bytes'
  ensure
    klass.define_method(:read_mp4_bytes, original) if original
    klass.send(:private, :read_mp4_bytes) if original
  end

  def test_planning_observations_are_shared_with_diagnostics
    seed_chapters
    inject_metadata(@path, keys: ['a'], indices: [0, 1])
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal :repairable, plan.status
      file.define_singleton_method(:read_native) { raise 'planning diagnostics must not reparse' }
      assert_equal :complete, file.diagnose(:chapter_references)[:status]
      assert_equal :complete, file.diagnose(:chapter_timing)[:status]
      assert_equal :malformed, file.diagnose(:chapters)[:status]
    end
  end

  def test_output_quicktime_verification_uses_one_structural_analysis
    seed_chapters
    inject_metadata(@path, keys: ['a'], indices: [0, 1])
    klass = TagLib::MP4::ChapterReferences
    original = klass.method(:new)
    calls = 0
    API.open(@path) do |file|
      file.apply_limited_repairs(plan: file.plan_limited_repairs, allow: ALLOW)
      klass.define_singleton_method(:new) do |*args, **kwargs|
        calls += 1
        original.call(*args, **kwargs)
      end
      file.save!(to: @output)
    end
    assert_equal 1, calls
  ensure
    klass.define_singleton_method(:new, original) if original
  end

  def test_copy_and_independent_scan_are_each_performed_once
    seed_chapters
    inject_metadata(@path, keys: ['a'], indices: [0, 1, 2])
    stream = API.const_get(:Stream, false)
    original = stream.method(:scan)
    calls = []
    stream.define_singleton_method(:scan) do |path, **options|
      calls << options
      original.call(path, **options)
    end
    API.open(@path) do |file|
      file.apply_limited_repairs(plan: file.plan_limited_repairs, allow: ALLOW)
      file.save!(to: @output)
    end
    assert_equal 2, calls.size
    assert_equal 1, calls.count { |options| options[:destination] }
    assert_not_nil calls.first[:replacement]
    assert_equal({}, calls.last)
  ensure
    stream.define_singleton_method(:scan, original) if original
  end

  def test_empty_keys_remove_every_numeric_item_without_removing_ordinary_item
    inject_metadata(@path, keys: [], indices: [1, 0, 0xffffffff, 1])
    API.open(@path) do |file|
      plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
      assert_equal [1, 0, 0xffffffff, 1], plan.metadata[:removed].map { |row| row[:index] }
      file.apply_limited_repairs(plan: plan, allow: ALLOW)
      file.save!(to: @output)
    end
    assert_equal ["\xa9nam".b], fixture_child(meta(@output), 'ilst')[:children].map { |row| row[:type] }
  end

  def test_invalid_survivor_structure_is_blocked
    inject_metadata(@path, keys: ['a'], indices: [0, 1])
    edit_fixture(@path) do |moov|
      metadata = fixture_child(fixture_child(moov, 'udta'), 'meta')
      fixture_child(metadata, 'ilst')[:children][1][:data] = atom_box('oops', ''.b)
    end
    API.open(@path) do |file|
      plan = file.plan_limited_repairs
      assert_equal :blocked, plan.status
      assert_equal :malformed, plan.metadata[:reason_code]
    end
  end

  def test_cleanup_failure_reports_published_output
    inject_metadata(@path, keys: ['a'], indices: [0])
    API.open(@path) do |file|
      file.apply_limited_repairs(plan: file.plan_limited_repairs, allow: ALLOW)
      file.define_singleton_method(:cleanup_candidate) { |_temporary| raise IOError, 'injected cleanup failure' }
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal true, error.committed
      assert_equal :cleanup, error.phase
      assert File.exist?(@output)
      API.open(@output) do |published|
        GC.start
        assert File.exist?(error.temporary_path), 'cleanup failure must leave the reported path under explicit ownership'
        assert_equal false, published.changes[:changed]
      end
      assert_raise(API::Error) { file.changes }
      File.unlink(error.temporary_path) if File.exist?(error.temporary_path)
    end
  end
end
