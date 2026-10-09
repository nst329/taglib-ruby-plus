# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require_relative '../tasks/taglib_patches'

# 重複するnative patch列への追加patchと、再実行時の冪等性を検証する。
class TagLibPatchSetupTest < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('taglib-patch-layers-')
    @source = File.join(@dir, 'source')
    FileUtils.mkdir_p(@source)
    run_git('init', '-q')
    File.write(File.join(@source, 'metadata'), "base\n")
    run_git('add', 'metadata')
    run_git('-c', 'user.name=TagLib Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '-m', '検証用の基準状態')
    @commit = run_git('rev-parse', 'HEAD').strip
    @patches = ["--- a/metadata\n+++ b/metadata\n@@ -1 +1,2 @@\n base\n+mdta\n",
                "--- a/metadata\n+++ b/metadata\n@@ -1,2 +1,2 @@\n base\n-mdta\n+snapshot\n",
                "--- /dev/null\n+++ b/atoms\n@@ -0,0 +1 @@\n+copyright\n"].each_with_index.map do |text, i|
      path = File.join(@dir, "#{i}.patch")
      File.write(path, text)
      path
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def run_git(*args)
    output, error, status = Open3.capture3('git', '-C', @source, *args)
    assert status.success?, error
    output
  end

  def test_fresh_patch_sequence_and_repeated_setup
    2.times { ensure_taglib_patch(@source, @patches, @commit) }
    assert_equal "base\nsnapshot\n", File.read(File.join(@source, 'metadata'))
    assert_equal "copyright\n", File.read(File.join(@source, 'atoms'))
  end

  def test_upgrade_of_existing_overlapping_snapshot_layers
    @patches.first(2).each { |patch| run_git('apply', patch) }
    assert_equal false, system('git', '-C', @source, 'apply', '--reverse', '--check', @patches[0], out: File::NULL, err: File::NULL)
    ensure_taglib_patch(@source, @patches, @commit)
    assert_equal "base\nsnapshot\n", File.read(File.join(@source, 'metadata'))
    assert_equal "copyright\n", File.read(File.join(@source, 'atoms'))
  end
end
