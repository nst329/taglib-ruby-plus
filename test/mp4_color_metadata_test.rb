# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'digest'
require 'open3'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib/base'
require 'taglib/mp4'

# 独立生成したstsdで短いcolrと隣接atom、複数entry、境界拒否を検証する。
class MP4ColorMetadataTest < Test::Unit::TestCase
  def box(type, payload, extended: false)
    extended ? [1].pack('N') + type + [payload.bytesize + 16].pack('Q>') + payload : [payload.bytesize + 8].pack('N') + type + payload
  end

  def track(id, entries)
    header = "\0".b * 84
    header[12, 4] = [id].pack('N')
    stsd = box('stsd', [0, entries.size].pack('N2') + entries.join.b)
    box('trak', box('tkhd', header) + box('mdia', box('hdlr', "\0".b * 8 + 'vide' + "\0".b * 12) +
      box('minf', box('stbl', stsd))))
  end

  def entry(*colors, type: 'avc1', extended: false)
    box(type, "\0".b * 78 + colors.join.b, extended: extended)
  end

  # nativeのcodec判定に依存せず、公開診断を最小構造の原本へ直接適用する。
  def diagnose(data)
    Dir.mktmpdir('colr-fixture-') do |dir|
      path = File.join(dir, 'fixture.mp4')
      File.binwrite(path, data)
      file = TagLib::MP4::File.allocate
      file.define_singleton_method(:name) { path }
      before = Digest::SHA256.file(path).hexdigest
      report = file.color_metadata_diagnostics
      assert_equal before, Digest::SHA256.file(path).hexdigest
      yield report, path if block_given?
      report
    end
  end

  def test_short_nclx_does_not_read_adjacent_atom_or_guess_range
    color = box('colr', 'nclx' + [1, 1, 1].pack('n3'))
    report = diagnose(box('moov', track(1, [entry(color, box('free', "\x80".b))])))
    row = report[:entries].first[:colr].first
    assert_equal [1, 1, 1], row.values_at(:color_primaries, :transfer_characteristics, :matrix_coefficients)
    assert_equal :malformed, row[:status]
    assert_equal [:short_color_payload], row[:issues]
    assert_false row[:range_field_present]
    assert_nil row[:range_byte]
    assert_nil row[:full_range]
    assert_equal Digest::SHA256.hexdigest(color), row[:raw_digest]
    assert_raise(FrozenError) { row[:issues] << :changed }
  end

  def test_normal_nclx_nclc_unknown_multiple_tracks_entries_and_extended_headers
    colors = [box('colr', 'nclx' + [1, 2, 3].pack('n3') + "\x80".b, extended: true),
              box('colr', 'nclc' + [4, 5, 6].pack('n3')), box('colr', 'prof' + 'opaque')]
    report = diagnose(box('moov', track(7, [entry(*colors, extended: true), entry(box('colr', 'nclx' + [9, 10, 11].pack('n3') + "\0".b))]) +
      track(8, [entry(box('colr', 'nclc' + [12, 13, 14].pack('n3')))]), extended: true))
    assert_equal [7, 7, 8], report[:entries].map { |row| row[:track_id] }
    assert_equal [1, 2, 1], report[:entries].map { |row| row[:sample_entry_number] }
    rows = report[:entries].first[:colr]
    assert_equal [0, 1, 2], rows.map { |row| row[:colr_index] }
    assert_equal 16, rows.first[:header_size]
    assert_true rows.first[:full_range]
    assert_nil rows[1][:full_range]
    assert_equal :unsupported_color_type, rows[2][:unsupported_reason]
    assert_nil rows[2][:color_primaries]
    assert_false report[:entries][1][:colr].first[:full_range]
    assert rows.all? { |row| row[:offset] >= row[:parent_payload_offset] && row[:end_offset] <= row[:parent_end] }
  end

  def test_partial_fields_and_reserved_bits
    ['nclx', 'nclx' + [2].pack('n'), 'nclx' + [2, 3].pack('n2')].each_with_index do |data, index|
      row = diagnose(box('moov', track(1, [entry(box('colr', data))])))[:entries].first[:colr].first
      assert_equal index >= 1 ? 2 : nil, row[:color_primaries]
      assert_equal index >= 2 ? 3 : nil, row[:transfer_characteristics]
      assert_nil row[:matrix_coefficients]
      assert_nil row[:full_range]
    end
    row = diagnose(box('moov', track(1, [entry(box('colr', 'nclx' + [1, 1, 1].pack('n3') + "\x81".b))])))[:entries].first[:colr].first
    assert_include row[:issues], :nonzero_reserved_range_bits
    assert_equal 129, row[:range_byte]
  end

  def test_boundaries_extended_header_and_entry_count_fail_explicitly
    bad_colors = [[100].pack('N') + 'colr' + 'nclx', [1].pack('N') + 'colr' + "\0".b * 4,
                  [4].pack('N') + 'colr', 'short']
    bad_colors.each do |color|
      error = assert_raise(TagLib::MP4::ColorMetadataError) { diagnose(box('moov', track(1, [entry(color)]))) }
      assert_equal :malformed, error.code
      assert_not_nil error.cause
    end
    data = box('moov', track(1, [entry]))
    offset = data.index('stsd') + 8
    data[offset, 4] = [2].pack('N')
    assert_raise(TagLib::MP4::ColorMetadataError) { diagnose(data) }
  end

  def test_unknown_sample_entry_is_explicit_and_payload_limit_is_enforced
    report = diagnose(box('moov', track(1, [entry(type: 'zzzz')])))
    assert_equal :unsupported_sample_entry_layout, report[:entries].first[:unsupported_reason]
    error = assert_raise(TagLib::MP4::ColorMetadataError) do
      diagnose(box('moov', track(1, [entry(box('colr', 'prof' + "x" * (1024 * 1024)))])))
    end
    assert_equal :limit, error.code
  end

  def test_large_mdat_is_skipped
    diagnose(box('moov', track(1, [entry]))) do |_report, path|
      File.open(path, 'ab') do |io|
        io.write([1].pack('N') + 'mdat' + [128 * 1024 * 1024].pack('Q>'))
        io.truncate(io.pos + 128 * 1024 * 1024 - 16)
      end
      file = TagLib::MP4::File.allocate
      file.define_singleton_method(:name) { path }
      original = file.method(:read_mp4_bytes)
      read_bytes = 0
      file.define_singleton_method(:read_mp4_bytes) do |io, offset, length|
        read_bytes += length
        original.call(io, offset, length)
      end
      assert_equal :complete, file.color_metadata_diagnostics[:status]
      assert_operator read_bytes, :<, 1024
    end
  end

  def test_atom_count_and_aggregate_payload_read_limits
    error = assert_raise(TagLib::MP4::ColorMetadataError) do
      diagnose(box('moov', track(1, [entry(box('free', ''.b) * 50_001)])))
    end
    assert_match(/count exceeds limit/, error.message)
    color = box('colr', 'prof' + 'x' * (1024 * 1024 - 4))
    error = assert_raise(TagLib::MP4::ColorMetadataError) do
      diagnose(box('moov', track(1, [entry(color * 33)])))
    end
    assert_equal :limit, error.code
    assert_match(/read limit/, error.message)
  end
end
