# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'digest'
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'taglib_plus'
require_relative '../support/mp4_investigation_fixture'

# 製品変更前にctime許容と内容変更拒否の境界を検証する。SMB実機の再現とは区別する。
class SMBGenerationDesignTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4
  GENERATION = API.const_get(:Generation, false)

  # 製品実装と比較するため、旧設計の厳格境界を残したprobe用module。
  module VerifiedCtimeProbe
    private

    # fd/pathの実体・size・mtimeを固定し、ctime差だけを事前SHAと比較する。
    def check_stat!
      return super unless @digest

      before = [identity(@io.stat), identity(::File.stat(@path))]
      changed! unless before.all? { |row| row[0, 4] == @identity[0, 4] }
      return if before.all? { |row| row == @identity }

      changed! unless hash_content == @digest && Digest::SHA256.file(@path).hexdigest == @digest
      after = [identity(@io.stat), identity(::File.stat(@path))]
      changed! unless after.all? { |row| row[0, 4] == @identity[0, 4] }
      # planのtokenは変えず、同じ基準内容に対する検証だけを許可する。
    end
  end

  def setup
    @dir = Dir.mktmpdir('smb-generation-design-')
    @path = File.join(@dir, 'source.m4a')
    @output = File.join(@dir, 'output.m4a')
    FileUtils.cp(File.expand_path('../data/mp4.m4a', __dir__), @path)
    inject_metadata(@path, keys: ['a'], indices: [1, 0])
  end

  def teardown
    @generations&.each(&:close)
    FileUtils.remove_entry(@dir)
  end

  def generation(verification = :stat, prototype: false)
    value = GENERATION.new(@path, verification)
    value.extend(VerifiedCtimeProbe) if prototype
    (@generations ||= []) << value
    value
  end

  # 例: fd=+1秒/path=+2秒のctime反映差を、内容や他のstat値を変えず再現する。
  def simulate_stat_difference(value, field: 4, fd_delta: 1, path_delta: 2)
    original = value.method(:identity)
    calls = 0
    value.define_singleton_method(:identity) do |stat|
      row = original.call(stat)
      row[field] += calls.even? ? fd_delta : path_delta
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

  def test_current_stat_mode_rejects_identical_content_for_ctime_differences
    [[1, 0], [0, 1], [1, 2]].each do |fd_delta, path_delta|
      value = generation
      before = Digest::SHA256.file(@path).hexdigest
      simulate_stat_difference(value, fd_delta: fd_delta, path_delta: path_delta)
      error = assert_raise(API::Error) { value.check! }
      assert_equal :source_changed, error.code
      assert_equal before, Digest::SHA256.file(@path).hexdigest
    end
  end

  def test_existing_strict_mode_allows_ctime_after_content_comparison
    value = generation(:sha256)
    simulate_stat_difference(value)
    assert_nothing_raised { value.check! }
  end

  def test_current_phase_reports_prepare_during_read_and_verify_inside_save
    API.open(@path) do |file|
      value = file.instance_variable_get(:@generation)
      error = assert_raise(API::Error) do
        file.__send__(:read_checked) { simulate_stat_difference(value) }
      end
      assert_equal :prepare, error.phase
    end
    API.open(@path) do |file|
      plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
      file.apply_limited_repairs(plan: plan, allow: [:remove_invalid_mdta_indices])
      prepare = file.method(:prepare_candidate)
      inject = method(:simulate_stat_difference)
      value = file.instance_variable_get(:@generation)
      file.define_singleton_method(:prepare_candidate) do |path, **args|
        prepare.call(path, **args)
        inject.call(value)
      end
      error = assert_raise(API::Error) { file.save!(to: @output) }
      assert_equal :source_changed, error.code
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_false File.exist?(@output)
    end
  end

  def test_verified_ctime_prototype_preserves_plan_token_and_succeeds
    value = generation(:sha256, prototype: true)
    token = value.token
    simulate_stat_difference(value)
    assert_nothing_raised { value.check! }
    assert_equal token, value.token
  end

  def test_prototype_rejects_real_content_change_even_with_restored_mtime
    value = generation(:sha256, prototype: true)
    change_content
    simulate_stat_difference(value)
    assert_equal :source_changed, assert_raise(API::Error) { value.check! }.code
  end

  def test_prototype_rejects_inode_replacement_size_and_mtime_changes
    %i[inode size mtime].each do |change|
      value = generation(:sha256, prototype: true)
      case change
      when :inode
        copy = File.join(@dir, 'replacement.m4a')
        FileUtils.cp(@path, copy)
        File.rename(copy, @path)
      when :size
        File.open(@path, 'ab') { |io| io.write('changed') }
      when :mtime
        simulate_stat_difference(value, field: 3)
      end
      assert_equal :source_changed, assert_raise(API::Error) { value.check! }.code
    end
  end

  def test_verified_ctime_plan_apply_save_succeeds_on_same_public_session
    API.open(@path, verification: :sha256) do |file|
      value = file.instance_variable_get(:@generation)
      value.extend(VerifiedCtimeProbe)
      plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
      assert_equal :repairable, plan.status
      original = File.binread(@path)
      simulate_stat_difference(value)
      file.apply_limited_repairs(plan: plan, allow: [:remove_invalid_mdta_indices])
      result = file.save!(to: @output)
      assert_equal true, result[:committed]
      assert_equal original, File.binread(@path)
    end
    API.open(@output) do |file|
      assert_equal :unchanged, file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc).status
    end
  end

  def test_content_change_after_plan_rejects_apply_and_save
    %i[apply save].each do |operation|
      API.open(@path, verification: :sha256) do |file|
        value = file.instance_variable_get(:@generation)
        value.extend(VerifiedCtimeProbe)
        plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
        file.apply_limited_repairs(plan: plan, allow: [:remove_invalid_mdta_indices]) if operation == :save
        change_content
        simulate_stat_difference(value)
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
end
