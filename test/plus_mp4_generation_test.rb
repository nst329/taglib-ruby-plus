# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'taglib_plus'
require_relative 'support/mp4_investigation_fixture'

# 製品の世代検証を直接試し、stat遅延と内容変更の境界を保証する。
class PlusMP4GenerationTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4
  GENERATION = API.const_get(:Generation, false)

  def setup
    @dir = Dir.mktmpdir('generation-')
    @path = File.join(@dir, "か\u3099-source.m4a")
    @output = File.join(@dir, "か\u3099-output.m4a")
    FileUtils.cp(File.expand_path('data/mp4.m4a', __dir__), @path)
    inject_metadata(@path, keys: ['a'], indices: [1, 0])
    @generations = []
  end

  def teardown
    @generations.each(&:close)
    FileUtils.remove_entry(@dir)
  end

  def generation(mode = :sha256)
    value = GENERATION.new(@path, mode)
    @generations << value
    value
  end

  # stat取得値だけを変更し、fd/pathで異なるctime遅延を再現する。
  def delayed_ctime(value, fd: 1, path: 2)
    original = value.method(:identity)
    calls = 0
    value.define_singleton_method(:identity) do |stat|
      row = original.call(stat)
      row[4] += calls.even? ? fd : path
      calls += 1
      row
    end
  end

  def change_content
    timestamp = File.stat(@path).mtime
    File.open(@path, 'r+b') do |io|
      io.seek(-1, IO::SEEK_END)
      byte = io.read(1).getbyte(0)
      io.seek(-1, IO::SEEK_END)
      io.write((byte ^ 1).chr)
    end
    File.utime(timestamp, timestamp, @path)
  end

  def test_ctime_delays_require_baseline_sha_and_preserve_token
    [[1, 0], [0, 1], [1, 2]].each do |fd, path|
      value = generation
      token = value.token
      delayed_ctime(value, fd: fd, path: path)
      assert_nothing_raised { value.check! }
      assert_equal token, value.token
      strict = generation(:stat)
      delayed_ctime(strict, fd: fd, path: path)
      error = assert_raise(API::Error) { strict.check! }
      assert_equal :source_changed, error.code
      assert_equal :source, error.area
      assert_equal :prepare, error.phase
      assert_equal %i[expected handle path], error.issues.first[:details].keys
    end
  end

  def test_real_changes_are_rejected
    %i[content inode size mtime].each do |change|
      value = generation
      case change
      when :content then change_content
      when :inode
        replacement = File.join(@dir, 'replacement.m4a')
        FileUtils.cp(@path, replacement)
        File.rename(replacement, @path)
      when :size then File.open(@path, 'ab') { |io| io.write('changed') }
      when :mtime
        stat = File.stat(@path)
        File.utime(stat.atime, stat.mtime + 1, @path)
      end
      assert_equal :source_changed, assert_raise(API::Error) { value.check! }.code
    end
  end

  def test_change_during_ctime_hash_is_rejected
    value = generation
    delayed_ctime(value)
    original = value.method(:hash_content)
    path = @path
    value.define_singleton_method(:hash_content) do
      digest = original.call
      stat = File.stat(path)
      File.utime(stat.atime, stat.mtime + 1, path)
      digest
    end
    assert_equal :source_changed, assert_raise(API::Error) { value.check! }.code
  end

  def test_ctime_delayed_repair_uses_product_implementation
    original = File.binread(@path)
    API.open(@path, verification: :sha256) do |file|
      plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
      assert_equal :repairable, plan.status
      delayed_ctime(file.instance_variable_get(:@generation))
      file.apply_limited_repairs(plan: plan, allow: [:remove_invalid_mdta_indices])
      assert_equal true, file.save!(to: @output)[:committed]
      assert_equal original, File.binread(@path)
    end
    API.open(@output) do |file|
      assert_equal :unchanged, file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc).status
    end
    assert_empty Dir.glob(File.join(@dir, 'taglib-plus-*'))
  end

  def test_content_change_after_plan_rejects_apply_and_save
    %i[apply save].each do |operation|
      API.open(@path, verification: :sha256) do |file|
        plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
        file.apply_limited_repairs(plan: plan, allow: [:remove_invalid_mdta_indices]) if operation == :save
        change_content
        delayed_ctime(file.instance_variable_get(:@generation))
        error = assert_raise(API::Error) do
          if operation == :apply
            file.apply_limited_repairs(plan: plan, allow: [:remove_invalid_mdta_indices])
          else
            file.save!(to: @output)
          end
        end
        assert_equal :source_changed, error.code
        assert_equal :prepare, error.phase
        assert_false File.exist?(@output)
      end
    end
  end

  def test_read_failure_keeps_source_area_stat_details_and_read_phase
    API.open(@path) do |file|
      error = assert_raise(API::Error) do
        file.__send__(:read_checked) { delayed_ctime(file.instance_variable_get(:@generation)) }
      end
      assert_equal :source_changed, error.code
      assert_equal :source, error.area
      assert_equal :read, error.phase
      assert_equal %i[expected handle path], error.issues.first[:details].keys
    end
  end

  def test_candidate_replacement_after_verification_is_not_deleted
    original_source = File.binread(@path)
    API.open(@path) do |file|
      file.apply_limited_repairs(plan: file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc),
                                allow: [:remove_invalid_mdta_indices])
      original = file.method(:verify_candidate)
      replacement = File.join(@dir, 'foreign.mp4')
      file.define_singleton_method(:verify_candidate) do |path|
        result = original.call(path)
        File.binwrite(replacement, 'foreign candidate')
        File.rename(replacement, path)
        result
      end
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal :cleanup, error.phase
      assert_equal false, error.committed
      assert_equal 'foreign candidate', File.binread(error.temporary_path)
      assert_equal :source_changed, error.cause.code
      assert_equal :verify, error.cause.phase
      assert_false File.exist?(@output)
      assert_equal original_source, File.binread(@path)
    end
  end

  def test_context_policy_rejects_unknown_handlers_and_unresolved_boundaries
    policy = TagLib::MP4::MetadataContextPolicy
    pair = %w[mdir mdta].map do |handler|
      { handler: handler, keys: [], path: 'moov/udta/meta', parent_offset: 10, parent_end_offset: 100 }
    end
    assert_true policy.safe_pair?(pair)
    [nil, 'zzzz'].each do |handler|
      assert_false policy.safe_pair?([pair.first, pair.last.merge(handler: handler)])
    end
    [nil, 10].each do |ending|
      assert_false policy.safe_pair?(pair.map { |row| row.merge(parent_end_offset: ending) })
    end
    assert_false policy.safe_pair?(pair.map { |row| row.merge(path: nil) })
  end
end
