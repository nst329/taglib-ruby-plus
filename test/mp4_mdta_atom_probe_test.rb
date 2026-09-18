# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"

class Mp4MdtaAtomProbeTest < Minitest::Test
  PROBE = File.expand_path("mp4_mdta_atom_probe.rb", __dir__)

  def test_repeated_data_keeps_its_parent_item
    first = item(1, data(1, "first") + data(33, "\x00\xff".b))
    second = item(1, data(1, "second"))
    with_mp4(mp4(mdta_meta(first + second))) do |path|
      output, error, status = Open3.capture3(RbConfig.ruby, PROBE, "--json", "--expect-mdta", "--require-value=title=first", path)
      assert status.success?, error

      meta = JSON.parse(output).fetch("metas").first
      assert_equal [2, 1], meta.fetch("mdta_items").map { |entry| entry.fetch("data").length }
      assert_equal [1, 1], meta.fetch("mdta_items").map { |entry| entry.fetch("index") }
      assert_equal 33, meta.fetch("mdta_items").first.fetch("data")[1].fetch("data_type")
      refute meta.fetch("mdta_items").first.fetch("data")[1].key?("text")
    end
  end

  def test_expected_mdta_must_exist_in_moov_udta
    track_meta = box("trak", box("mdia", mdta_meta(item(1, data(1, "track")))))
    with_mp4(box("moov", track_meta)) do |path|
      _output, error, status = Open3.capture3(RbConfig.ruby, PROBE, "--expect-mdta", path)
      refute status.success?
      assert_match(/moov\/udta\/meta with mdta handler is missing/, error)
    end
  end

  def test_required_value_rejects_keys_without_values
    with_mp4(mp4(mdta_meta("".b))) do |path|
      _output, error, status = Open3.capture3(RbConfig.ruby, PROBE, "--expect-mdta", "--require-value=title=missing", path)
      refute status.success?
      assert_match(/mdta value "title"="missing" is missing/, error)
    end
  end

  def test_mixed_mdta_and_raw_four_byte_title_atom
    title_name = [0xa9, 0x6e, 0x61, 0x6d].pack("C*")
    normal_title = box(title_name, data(1, "normal title"))
    with_mp4(mp4(mdta_meta(item(1, data(1, "mdta title")) + normal_title))) do |path|
      output, error, status = Open3.capture3(RbConfig.ruby, PROBE, "--json", "--expect-mdta", path)
      assert status.success?, error

      meta = JSON.parse(output).fetch("metas").first
      assert_equal "mdta title", meta.fetch("mdta_items").first.fetch("data").first.fetch("text")
      assert_equal "0xa96e616d", meta.fetch("ilst_items").first.fetch("name")
      assert_equal "normal title", meta.fetch("ilst_items").first.fetch("data").first.fetch("text")
    end
  end

  def test_empty_input_fails_check
    with_mp4("".b) do |path|
      _output, error, status = Open3.capture3(RbConfig.ruby, PROBE, "--check", path)
      refute status.success?
      assert_match(/moov atom is missing/, error)
    end
  end

  private

  def with_mp4(bytes)
    Tempfile.create(["mdta-probe-", ".mp4"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      yield file.path
    end
  end

  def mp4(ilst_items)
    box("moov", box("udta", ilst_items))
  end

  def mdta_meta(ilst_items)
    handler = box("hdlr", [0, 0].pack("N2") + "mdta" + "\x00".b * 12)
    key = "title".b
    keys = box("keys", [0, 1, key.bytesize + 8].pack("N3") + "mdta" + key)
    box("meta", [0].pack("N") + handler + keys + box("ilst", ilst_items))
  end

  def item(index, payload)
    box([index].pack("N"), payload)
  end

  def data(type, payload)
    box("data", [type, 0].pack("N2") + payload.b)
  end

  def box(type, payload)
    [payload.bytesize + 8].pack("N") + type.b + payload.b
  end
end
