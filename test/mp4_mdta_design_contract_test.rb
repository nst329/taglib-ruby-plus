# frozen_string_literal: true

# Contract tests for the patched TagLib and the Ruby save boundary.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"
require "rbconfig"
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__),
                   File.expand_path("../ext/taglib_base", __dir__),
                   File.expand_path("../ext/taglib_mp4", __dir__))
require "taglib/base"
require "taglib/mp4"

class Mp4MdtaDesignContractTest < Minitest::Test
  def setup
    @baseline = ENV["MDTA_BASELINE"]
    @io_fault = ENV["MDTA_IO_FAULT"]
    skip "set MDTA_BASELINE and MDTA_IO_FAULT to run design contract probes" unless @baseline && @io_fault

    @dir = Dir.mktmpdir("mdta-contract-")
    @source = File.join(@dir, "source.mp4")
    run!(RbConfig.ruby, File.join(__dir__, "generate_mp4_mdta_fixture.rb"), @source)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def run!(*args)
    output, error, result = Open3.capture3(*args)
    assert result.success?, "#{args.inspect}\n#{output}\n#{error}"
    output
  end

  def saved_copy
    path = File.join(@dir, "saved.mp4")
    original = Digest::SHA256.file(@source).hexdigest
    run!(@baseline, @source, path)
    assert_equal original, Digest::SHA256.file(@source).hexdigest
    path
  end

  def test_reopened_title_is_asserted_and_wrong_title_is_rejected
    path = saved_copy
    run!(@baseline, "--verify", path)
    _, _, result = Open3.capture3(@baseline, "--verify", @source)
    refute result.success?, "mdta-only input must fail the normal-title expectation"
    invalid = File.join(@dir, "invalid.mp4")
    File.binwrite(invalid, "not an MP4")
    _, _, result = Open3.capture3(@baseline, "--verify", invalid)
    refute result.success?
  end

  def test_discarded_writes_are_reported_as_save_failure
    before = Digest::SHA256.file(@source).hexdigest
    output = run!(@io_fault, @source)
    assert_match(/save=0 discarded=[1-9]/, output)
    assert_equal before, Digest::SHA256.file(@source).hexdigest
  end

  def test_mdat_damage_passes_tag_and_atom_checks_but_fails_payload_comparison
    path = saved_copy
    bytes = File.binread(path)
    offset = 0
    payload = nil
    while offset < bytes.bytesize
      size, type = bytes.byteslice(offset, 8).unpack("Na4")
      raise "unsupported fixture atom" if size < 8
      if type == "mdat"
        payload = offset + 8
        break
      end
      offset += size
    end
    refute_nil payload
    original_payload = bytes.byteslice(payload..)
    bytes.setbyte(payload + 8, bytes.getbyte(payload + 8) ^ 0xff)
    File.binwrite(path, bytes)
    run!(@baseline, "--verify", path)
    run!(RbConfig.ruby, File.join(__dir__, "mp4_mdta_atom_probe.rb"), "--check", path)
    refute_equal Digest::SHA256.hexdigest(original_payload),
                 Digest::SHA256.hexdigest(File.binread(path).byteslice(payload..))
  end

  def test_direct_map_edits_are_visible_without_tag_setter
    path = saved_copy
    TagLib::MP4::File.open(path) do |file|
      map = file.tag.item_map
      assert map.include?("\u00a9nam")
      map.erase("\u00a9nam")
      assert_equal "MDTA Title", file.tag.title
      map.insert("\u00a9nam", TagLib::MP4::Item.new(["Map title"]))
      assert_equal "Map title", file.tag.title
      map.clear
      assert_equal "MDTA Title", file.tag.title
    end
  end

  def test_rename_commits_even_when_next_open_raises_and_old_handle_is_stale
    path = File.join(@dir, "original")
    temp = File.join(@dir, "temp")
    File.binwrite(path, "old")
    File.binwrite(temp, "new")
    old = File.open(path, "rb")
    begin
      assert_raises(IOError) do
        File.rename(temp, path)
        raise IOError, "injected reopen failure"
      end
      assert_equal "new", File.binread(path)
      assert_equal "old", old.read
      # Proposed failure action: invalidate the handle even though rebind failed.
      old.close
      assert_raises(IOError) { old.read }
    ensure
      old.close unless old.closed?
    end
  end
end
