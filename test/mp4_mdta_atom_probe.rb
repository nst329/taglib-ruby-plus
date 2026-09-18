#!/usr/bin/env ruby
# frozen_string_literal: true

# A small, dependency-free MP4 atom probe used by the mdta design review.
# It intentionally does not load TagLib: its job is to show the bytes that
# FFmpeg/TagLib wrote, including mdta keys and typed data payloads.

require "json"

Atom = Struct.new(:type, :offset, :size, :header_size, :payload_offset, :end_offset, :children, keyword_init: true)

class Mp4AtomProbe
  CONTAINERS = %w[moov trak mdia minf dinf stbl edts mvex udta meta ilst].freeze

  def initialize(path)
    @path = path
    @bytes = File.binread(path)
  end

  def report
    top_level = parse_children(0, @bytes.bytesize)
    moov = top_level.find { |atom| atom.type == "moov" }
    udta = moov&.children&.find { |atom| atom.type == "udta" }
    metas = udta ? udta.children.select { |atom| atom.type == "meta" } : []

    {
      "file" => @path,
      "size" => @bytes.bytesize,
      "scope" => "moov/udta/meta",
      "has_moov" => !moov.nil?,
      "metas" => metas.map { |meta| describe_meta(meta) }
    }
  end

  def check!(expect_mdta: false, required_values: [])
    errors = []
    result = report
    errors << "moov atom is missing" unless result.fetch("has_moov")
    metas = result.fetch("metas")
    if expect_mdta && metas.none? { |meta| meta["handler"] == "mdta" }
      errors << "moov/udta/meta with mdta handler is missing"
    end
    required_values.each do |key, expected_text|
      found = metas.any? do |meta|
        next false unless meta["handler"] == "mdta"

        meta.fetch("values").any? do |value|
          mdta_key = meta.fetch("keys")[value.fetch("index") - 1]
          mdta_key && mdta_key.fetch("key") == key && value["text"] == expected_text
        end
      end
      errors << "mdta value #{key.inspect}=#{expected_text.inspect} is missing" unless found
    end
    metas.each_with_index do |meta, meta_index|
      next unless meta["handler"] == "mdta"

      key_count = meta.fetch("keys").length
      meta.fetch("invalid_value_indices").each do |index|
        errors << "meta[#{meta_index}] ilst index #{index} has no keys entry"
      end
      meta.fetch("values").each do |value|
        index = value.fetch("index")
        errors << "meta[#{meta_index}] ilst index #{index} has no keys entry" if index.zero? || index > key_count
      end
    end

    return true if errors.empty?

    errors.each { |error| warn "ERROR: #{error}" }
    false
  end

  private

  def parse_children(start_offset, end_offset, parent_type = nil)
    atoms = []
    offset = start_offset
    while offset < end_offset
      atom = parse_atom(offset, end_offset)
      atom.children = if CONTAINERS.include?(atom.type) || parent_type == "ilst"
                        child_start = atom.type == "meta" ? atom.payload_offset + 4 : atom.payload_offset
                        parse_children(child_start, atom.end_offset, atom.type)
                      else
                        []
                      end
      atoms << atom
      offset = atom.end_offset
    end
    raise "atom boundary mismatch at #{offset}, expected #{end_offset}" unless offset == end_offset

    atoms
  end

  def parse_atom(offset, limit)
    raise "truncated atom header at #{offset}" if offset + 8 > limit

    size32 = uint32(offset)
    type = @bytes.byteslice(offset + 4, 4)
    header_size = 8
    size = size32
    if size32 == 1
      raise "truncated extended atom header at #{offset}" if offset + 16 > limit

      size = uint64(offset + 8)
      header_size = 16
    elsif size32.zero?
      size = limit - offset
    end

    raise "invalid atom size #{size} for #{type.inspect} at #{offset}" if size < header_size || offset + size > limit

    Atom.new(
      type: type,
      offset: offset,
      size: size,
      header_size: header_size,
      payload_offset: offset + header_size,
      end_offset: offset + size
    )
  end

  def describe_meta(meta)
    handler = handler_type(meta)
    ilst = meta.children.find { |child| child.type == "ilst" }
    result = {
      "offset" => meta.offset,
      "size" => meta.size,
      "handler" => display_bytes(handler),
      "keys" => [],
      "mdta_items" => [],
      "values" => [],
      "invalid_value_indices" => [],
      "ilst_items" => []
    }

    if (keys = meta.children.find { |child| child.type == "keys" })
      result["keys"] = parse_keys(keys)
    end

    return result unless ilst

    ilst.children.each do |item|
      data_items = item.children.select { |child| child.type == "data" }.map { |data| parse_data(data) }
      mdta_index = item.type.unpack1("N")
      numeric_mdta_item = handler == "mdta" && item.type.getbyte(0).zero?
      if numeric_mdta_item
        if mdta_index <= result["keys"].length
          result["mdta_items"] << { "index" => mdta_index, "data" => data_items }
          data_items.each { |data| result["values"] << data.merge("index" => mdta_index) }
        else
          result["invalid_value_indices"] << mdta_index
        end
      else
        result["ilst_items"] << {
          "name" => display_bytes(item.type),
          "data" => data_items
        }
      end
    end

    result
  end

  def handler_type(meta)
    hdlr = meta.children.find { |child| child.type == "hdlr" }
    return "" unless hdlr && hdlr.size >= hdlr.header_size + 12

    @bytes.byteslice(hdlr.payload_offset + 8, 4)
  end

  def parse_keys(atom)
    raise "truncated keys header at #{atom.offset}" if atom.payload_offset + 8 > atom.end_offset

    count = uint32(atom.payload_offset + 4)
    offset = atom.payload_offset + 8
    count.times.map do |index|
      raise "truncated key entry #{index + 1} at #{offset}" if offset + 8 > atom.end_offset

      size = uint32(offset)
      raise "invalid key entry #{index + 1} size #{size}" if size < 8 || offset + size > atom.end_offset

      namespace = @bytes.byteslice(offset + 4, 4)
      key = @bytes.byteslice(offset + 8, size - 8)
      offset += size
      {
        "index" => index + 1,
        "namespace" => display_bytes(namespace),
        "key" => display_bytes(key)
      }
    end
  end

  def parse_data(atom)
    type = uint32(atom.payload_offset)
    locale = uint32(atom.payload_offset + 4)
    payload = @bytes.byteslice(atom.payload_offset + 8, atom.end_offset - atom.payload_offset - 8) || "".b
    result = {
      "data_type" => type,
      "locale" => locale,
      "bytes" => payload.bytesize,
      "hex" => payload.unpack1("H*")
    }
    result["text"] = payload.dup.force_encoding(Encoding::UTF_8) if type == 1 && payload.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    result
  end

  def display_bytes(value)
    return "" if value.nil?

    text = value.dup.force_encoding(Encoding::UTF_8)
    return text if text.valid_encoding? && text.match?(/\A[\x20-\x7e]*\z/)

    "0x#{value.unpack1("H*")}"
  end

  def uint32(offset)
    value = @bytes.byteslice(offset, 4)
    raise "truncated uint32 at #{offset}" unless value && value.bytesize == 4

    value.unpack1("N")
  end

  def uint64(offset)
    value = @bytes.byteslice(offset, 8)
    raise "truncated uint64 at #{offset}" unless value && value.bytesize == 8

    value.unpack1("Q>")
  end
end

json = ARGV.delete("--json")
check = ARGV.delete("--check")
expect_mdta = ARGV.delete("--expect-mdta")
required_values = ARGV.grep(/\A--require-value=/).map do |option|
  key, value = option.delete_prefix("--require-value=").split("=", 2)
  abort "invalid --require-value: #{option}" unless key && value

  [key, value]
end
ARGV.delete_if { |option| option.start_with?("--require-value=") }
path = ARGV.shift
abort "usage: #{File.basename($PROGRAM_NAME)} [--json] [--check] [--expect-mdta] [--require-value=KEY=TEXT] FILE" unless path
abort "unknown option: #{ARGV.join(" ")}" unless ARGV.empty?

probe = Mp4AtomProbe.new(path)
report = probe.report

if json
  puts JSON.pretty_generate(report)
else
  puts "file=#{report.fetch("file")} size=#{report.fetch("size")}"
  report.fetch("metas").each_with_index do |meta, index|
    puts "meta[#{index}] offset=#{meta.fetch("offset")} size=#{meta.fetch("size")} handler=#{meta.fetch("handler")}"
    meta.fetch("keys").each do |key|
      puts "  key[#{key.fetch("index")}] #{key.fetch("namespace")}:#{key.fetch("key")}"
    end
    meta.fetch("mdta_items").each_with_index do |item, item_index|
      puts "  mdta_item[#{item_index}] index=#{item.fetch("index")} data_atoms=#{item.fetch("data").length}"
    end
    meta.fetch("values").each do |value|
      key = meta.fetch("keys")[value.fetch("index") - 1]
      key_name = key ? "#{key.fetch("namespace")}:#{key.fetch("key")}" : "<missing>"
      text = value["text"] ? " text=#{value.fetch("text").inspect}" : ""
      puts "  value[#{value.fetch("index")}] #{key_name} type=#{value.fetch("data_type")} locale=#{value.fetch("locale")} bytes=#{value.fetch("bytes")} hex=#{value.fetch("hex")}#{text}"
    end
    meta.fetch("ilst_items").each do |item|
      puts "  ilst[#{item.fetch("name")}] data=#{item.fetch("data").inspect}"
    end
  end
end

needs_check = check || expect_mdta || !required_values.empty?
abort "mdta key/index check failed" if needs_check && !probe.check!(expect_mdta: !!expect_mdta, required_values: required_values)
