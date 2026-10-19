# frozen_string_literal: true

require 'test/unit'
require 'taglib_plus'
require_relative 'support/mp4_investigation_fixture'
require 'tmpdir'
require 'open3'
require 'json'

class MP4SampleBoundariesTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  # 実File#readの要求位置とbytesを独立に記録する（statやseekは数えない）。
  module ReadObserver
    def open(*args, **kwargs, &block)
      observer = Thread.current[:boundary_read_observer]
      return super unless block && observer && args.first == observer[:path]
      super(*args, **kwargs) do |io|
        original = io.method(:read)
        io.define_singleton_method(:read) do |*read_args|
          observer[:reads] << [pos, read_args.first]
          observer[:action]&.call(io)
          original.call(*read_args)
        end
        block.call(io)
      end
    end
  end
  ::File.singleton_class.prepend(ReadObserver)

  setup do
    @dir = Dir.mktmpdir('sample-boundaries-')
    @path = File.join(@dir, 'synthetic.mp4')
    write_fixture
  end

  teardown do
    Thread.current[:boundary_read_observer] = nil
    FileUtils.remove_entry(@dir)
  end

  def box(type, raw)
    atom_box(type, raw)
  end

  def timing(scale, duration)
    [0, 0, 0, scale, duration, 0].pack('N6')
  end

  # 正解: 7 samples。chunk位置8/20/40、sample size 3/5/2/4/6/1/3。
  # DTS 0/100/200/300/380/460/540、decode終端620。製品parserは使用しない。
  def write_fixture(fixed: nil, compact: nil, co64: false, edit: nil, overrides: {}, extra: '',
                    sample_count: 7, mdat_size: 128, descriptions: nil, dref: nil, fragment: false, media_duration: 620)
    sizes = [3, 5, 2, 4, 6, 1, 3]
    sample = "\0".b * 28
    sample[6, 2] = [1].pack('n')
    sample[16, 2] = [2].pack('n')
    sample[24, 4] = [48000 << 16].pack('N')
    size_table = if compact
                   data = case compact
                          when 4 then sizes.each_slice(2).map { |a, b| (a << 4) | (b || 0) }.pack('C*')
                          when 8 then sizes.pack('C*')
                          when 16 then sizes.pack('n*')
                          end
                   box('stz2', [0, compact, sample_count].pack('N3') + data)
                 else
                   box('stsz', [0, fixed || 0, sample_count].pack('N3') + (fixed ? ''.b : sizes.pack('N*')))
                 end
    tables = {
      stsd: box('stsd', [0, 1].pack('N2') + (descriptions || box('mp4a', sample))),
      stts: box('stts', [0, 2, 3, 100, 4, 80].pack('N*')),
      stsc: box('stsc', [0, 2, 1, 2, 1, 3, 3, 1].pack('N*')),
      sizes: size_table,
      offsets: box(co64 ? 'co64' : 'stco', [0, 3].pack('N2') + [8, 20, 40].pack(co64 ? 'Q>*' : 'N*'))
    }.merge(overrides)
    tkhd = "\0".b * 84
    tkhd[12, 4] = [17].pack('N')
    tkhd[20, 4] = [600].pack('N')
    edit_box = edit ? box('edts', box('elst', edit)) : ''.b
    reference = dref || [0, 1].pack('N2') + box('url ', [1].pack('N'))
    mdia = box('mdhd', timing(48000, media_duration)) + box('hdlr', [0, 0].pack('N2') + 'soun' + "\0" * 12) +
      box('minf', box('dinf', box('dref', reference)) + box('stbl', tables.values.join + extra))
    moov = box('moov', box('mvhd', timing(1000, 600).ljust(100, "\0")) + (fragment ? box('mvex', '') : '') +
      box('trak', box('tkhd', tkhd) + edit_box + box('mdia', mdia)))
    File.open(@path, 'wb') do |io|
      io.write([mdat_size + 8].pack('N') + 'mdat')
      io.seek(mdat_size, IO::SEEK_CUR) # sparse mdat。本文は読まず、巨大配列も生成しない。
      io.write(moov)
    end
  end

  def read(**options)
    API.open(@path) { |file| file.sample_boundaries(track_id: 17, **options) }
  end

  def malformed(**options)
    write_fixture(**options)
    error = assert_raise(API::Error) { read }
    assert_equal :malformed, error.code
    assert_equal :sample_boundaries, error.area
  end

  def test_public_api_raw_boundaries_and_detached_immutable_result
    before = File.binread(@path)
    original_stat = File.stat(@path)
    result = API.open(@path) do |file|
      file.define_singleton_method(:read_native) { raise 'native must not be opened' }
      assert_equal 17, file.info[:tracks].first[:id]
      file.sample_boundaries(track_id: 17)
    end
    assert_equal :complete, result[:status]
    data = result[:data]
    assert_equal 48000, data[:media_timescale]
    assert_equal 7, data[:sample_count]
    assert_equal 620, data[:decode_end]
    assert_equal({ index: 0, offset: 8, size: 3, dts: 0, pts: 0, duration: 100 }, data[:first])
    assert_equal({ index: 6, offset: 47, size: 3, dts: 540, pts: 540, duration: 80 }, data[:last])
    assert_equal :raw_media, data[:time_axis]
    assert_equal :absent, data[:composition_offsets]
    assert_equal true, data[:last_is_max_raw_presentation_end]
    assert_equal 'mp4a', data[:sample_descriptions].first[:fourcc]
    assert result.frozen?
    assert data[:sample_descriptions].first[:raw].frozen?
    assert_equal before, File.binread(@path)
    assert_equal original_stat.mtime, File.stat(@path).mtime
    assert_equal original_stat.size, File.size(@path)
    assert_equal 64, result[:tables_digest].size
  end

  def test_fixed_sizes_co64_and_compact_sizes
    write_fixture(fixed: 4, co64: true)
    result = read
    assert_equal :complete, result[:status]
    assert_equal [48, 4], result[:data][:last].values_at(:offset, :size)
    [4, 8, 16].each do |field|
      write_fixture(compact: field)
      assert_equal :complete, read[:status]
      assert_equal [47, 3], read[:data][:last].values_at(:offset, :size)
    end
  end

  def test_priming_and_trim_edit_does_not_change_raw_times
    edit = [0, 1, 10, 100, 1, 0].pack('N3l>nn')
    write_fixture(edit: edit)
    result = read
    assert_equal :complete, result[:status]
    assert_equal 0, result[:data][:first][:pts]
    assert_equal 540, result[:data][:last][:pts]
    assert_equal 100, result[:data][:edits].first[:media_time]
    assert_equal 10, result[:data][:edits].first[:segment_duration]
    # edit適用後は -100/48000 秒から開始し、表示終端は10/1000秒。
    assert_equal Rational(-1, 480), Rational(result[:data][:first][:pts] - 100, 48000)
    assert_equal 620, result[:data][:decode_end]
    write_fixture(edit: [0x01000000, 1, 10, 100, 1, 0].pack('N2Q>q>nn'))
    assert_equal 100, read[:data][:edits].first[:media_time]
  end

  def test_count_mismatch_truncation_and_timing_overflow
    malformed(media_duration: 619)
    malformed(overrides: { stts: box('stts', [0, 1, 6, 100].pack('N*')) })
    malformed(overrides: { stts: box('stts', [0, 1, 7].pack('N*')) })
    malformed(overrides: { stts: box('stts', [0, 1, 7, 0].pack('N*')) })
    malformed(overrides: { stts: box('stts', [0, 1, 0xffffffff, 0xffffffff].pack('N*')) })
    malformed(overrides: { sizes: box('stsz', [0, 0, 7, 3].pack('N*')) })
    malformed(overrides: { offsets: box('co64', [0, 3, 8].pack('N2Q>')) })
  end

  def test_truncated_required_track_headers_are_malformed
    %w[tkhd mvhd mdhd hdlr].each do |type|
      write_fixture
      edit_fixture(@path) do |moov|
        each_fixture_atom([moov]) { |a| a[:data] = a[:data].byteslice(0, 16) if a[:type] == type }
      end
      error = assert_raise(API::Error) { read }
      assert_equal :malformed, error.code
    end
  end

  def test_description_switch_encryption_and_unknown_entry_extensions
    sample = "\0".b * 28
    sample[6, 2] = [1].pack('n')
    sample[16, 2] = [2].pack('n')
    sample[24, 4] = [48000 << 16].pack('N')
    two = box('stsd', [0, 2].pack('N2') + box('mp4a', sample) * 2)
    write_fixture(overrides: { stsd: two, stsc: box('stsc', [0, 2, 1, 2, 1, 3, 3, 2].pack('N*')) })
    assert_equal :unsupported, read[:status]
    assert read[:issues].any? { |i| i[:code] == :multiple_sample_descriptions }
    write_fixture(descriptions: box('enca', sample + box('sinf', '')))
    assert_equal :unsupported, read[:status]
    write_fixture(descriptions: box('mp4a', sample + box('zzzz', '')))
    assert_equal :sample_entry_extension, read[:issues].first[:code]
    sample[6, 2] = [2].pack('n')
    malformed(descriptions: box('mp4a', sample))
  end

  def test_oversized_table_is_rejected_before_body_allocation_or_read
    write_fixture(overrides: { stts: box('stts', [0, 10000].pack('N2') + [1, 1].pack('N2') * 10000) })
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    result, reads = observe { read(max_table_bytes: 1024) }
    allocated = GC.stat(:total_allocated_objects) - allocated
    assert_equal :limit, result[:status]
    assert_equal :max_table_bytes, result[:issues].last[:code]
    assert_operator reads.map(&:last).max, :<, 1024
    assert_operator reads.sum(&:last), :<, 1024
    assert_operator allocated, :<, 10000
  end

  def test_invalid_chunk_mapping_ranges_and_overlap
    [[1, 2, 1, 3, 2, 1], [2, 2, 1, 3, 3, 1], [1, 2, 1, 1, 3, 1],
     [1, 2, 1, 4, 3, 1], [1, 2, 1, 3, 3, 2], [1, 0, 1, 3, 3, 1]].each do |rows|
      malformed(overrides: { stsc: box('stsc', [0, 2, *rows].pack('N*')) })
    end
    [[0, 20, 40], [8, 20, 135], [8, 12, 40], [8, 8, 40], [8, 20, 0xffffffffffffffff]].each do |offsets|
      malformed(overrides: { offsets: box('co64', [0, 3].pack('N2') + offsets.pack('Q>*')) })
    end
    # 物理chunkの順序が逆でも、重ならずmdat内なら有効。
    write_fixture(overrides: { offsets: box('stco', [0, 3, 40, 20, 8].pack('N*')) })
    assert_equal :complete, read[:status]
    assert_equal 15, read[:data][:last][:offset]
  end

  def test_ctts_zero_and_nonzero_and_invalid_count
    write_fixture(extra: box('ctts', [0, 2, 3, 0, 4, 0].pack('N*')))
    assert_equal :complete, read[:status]
    assert_equal :zero, read[:data][:composition_offsets]
    write_fixture(extra: box('ctts', [0x01000000, 1, 7, -1].pack('N3l>')))
    result = read
    assert_equal :unsupported, result[:status]
    assert_nil result[:data][:last][:pts]
    assert_equal :unsupported, result[:coverage].find { |c| c[:check] == :composition_timing }[:status]
    malformed(extra: box('ctts', [0, 1, 8, 0].pack('N*')))
    malformed(fixed: 1, sample_count: 0x80000000, media_duration: 0xffffffff,
      overrides: { stts: box('stts', [0, 1, 0x80000000, 0xffffffff].pack('N*')) },
      extra: box('ctts', [0, 1, 0x80000000, 0xffffffff].pack('N*')))
  end

  def test_unsupported_structures_have_specific_reasons
    %w[sgpd sbgp senc saiz saio stss zzzz].each do |type|
      write_fixture(extra: box(type, [0].pack('N')))
      result = read
      assert_equal :unsupported, result[:status], type
      assert result[:issues].any? { |i| i[:message].include?(type) }
    end
    write_fixture(fragment: true)
    assert_equal :fragmented, read[:issues].first[:code]
    write_fixture(edit: [0, 2, 10, -1, 1, 0, 10, 0, 1, 0].pack('N3l>nnNl>nn'))
    assert_equal :edit_list, read[:issues].first[:code]
    write_fixture(dref: [0, 1].pack('N2') + box('url ', [0].pack('N') + 'external'))
    assert_equal :unsupported, read[:status]
    # 非対応boxがあっても既知tableの破損は例外。
    malformed(extra: box('sgpd', ''), overrides: { stts: box('stts', [0, 1, 8, 100].pack('N*')) })
  end

  def test_aggregate_limits_and_arguments
    result = read
    assert_equal :complete, read(max_table_bytes: result[:counts][:table_bytes], max_table_entries: result[:counts][:table_entries])[:status]
    assert_equal :max_table_bytes, read(max_table_bytes: result[:counts][:table_bytes] - 1)[:issues].last[:code]
    assert_equal :max_table_entries, read(max_table_entries: result[:counts][:table_entries] - 1)[:issues].last[:code]
    assert_equal :limit, read(max_table_bytes: 1)[:status]
    assert_equal :limit, read(max_table_entries: 1)[:status]
    [0, -1, nil, 1.5].each { |v| assert_raise(ArgumentError) { read(max_table_bytes: v) } }
    API.open(@path) { |file| assert_raise(ArgumentError) { file.sample_boundaries(track_id: 99) } }
  end

  def test_atom_parser_limits_and_truncated_root_are_distinct
    raw = box('free', '')
    18.times { raw = box('moov', raw) }
    File.binwrite(@path, raw)
    assert_equal :limit, read[:status]
    assert_equal :atom_depth, read[:issues].first[:code]
    write_fixture
    File.open(@path, 'ab') { |io| io.write('bad') }
    error = assert_raise(API::Error) { read }
    assert_equal :malformed, error.code
    assert_kind_of TagLib::MP4::MdtaSaveError, error.cause
  end

  def observe(action = nil)
    observer = { path: File.realpath(@path), reads: [], action: action }
    Thread.current[:boundary_read_observer] = observer
    value = yield
    [value, observer[:reads]]
  ensure
    Thread.current[:boundary_read_observer] = nil
  end

  def test_io_failure_preserves_cause_and_generation_conflicts_propagate
    API.open(@path) do |file|
      failure = IOError.new('injected read error')
      error = assert_raise(API::Error) do
        observe(->(_) { raise failure }) { file.sample_boundaries(track_id: 17) }
      end
      assert_equal :io, error.code
      assert_same failure, error.cause
    end
    API.open(@path) do |file|
      changed = false
      action = lambda do |_|
        next if changed
        changed = true
        File.open(@path, 'r+b') { |io| io.seek(9); io.write('X') }
      end
      error = assert_raise(API::Error) { observe(action) { file.sample_boundaries(track_id: 17) } }
      assert_equal :source_changed, error.code
    end
    API.open(@path) do |file|
      replacement = @path + '.new'
      FileUtils.cp(@path, replacement)
      File.rename(replacement, @path)
      assert_equal :source_changed, assert_raise(API::Error) { file.sample_boundaries(track_id: 17) }.code
    end
  end

  def test_read_volume_is_independent_of_mdat_size_and_matches_actual_reads
    measurements = [128, 64 * 1024 * 1024].map do |size|
      write_fixture(mdat_size: size)
      result, reads = observe { read }
      assert_equal :complete, result[:status]
      assert reads.none? { |offset, bytes| offset >= 8 && offset < size + 8 && bytes.positive? }, reads.inspect
      assert_equal reads.size, result[:counts][:read_calls]
      assert_equal reads.sum { |_, n| n }, result[:counts][:bytes_read]
      [result[:counts][:read_calls], result[:counts][:bytes_read]]
    end
    assert_equal measurements.first, measurements.last
    puts "sample boundary I/O (128B/64MiB mdat): #{measurements.inspect}"
  end

  def test_fixed_size_huge_sample_count_uses_compressed_tables_and_bounded_allocations
    n = 100_000_000
    write_fixture(fixed: 1, sample_count: n, mdat_size: n, media_duration: n,
      overrides: { stts: box('stts', [0, 1, n, 1].pack('N*')),
                   stsc: box('stsc', [0, 1, 1, n, 1].pack('N*')),
                   offsets: box('stco', [0, 1, 8].pack('N*')) })
    GC.start
    before = GC.stat(:total_allocated_objects)
    result = read(max_table_entries: 10)
    allocated = GC.stat(:total_allocated_objects) - before
    assert_equal :complete, result[:status]
    assert_equal [n - 1, n + 7, n - 1, 1], result[:data][:last].values_at(:index, :offset, :dts, :duration)
    assert_operator allocated, :<, 10_000
    assert_operator result[:counts][:bytes_read], :<, 4096
    puts "100M fixed samples: #{allocated} allocated objects; #{result[:counts].inspect}"
  end

  def test_existing_fixture_and_ffprobe_edit_axis_comparison
    path = 'test/data/mp4.m4a'
    result = API.open(path) { |file| file.sample_boundaries(track_id: 1) }
    assert_equal :complete, result[:status]
    probe = '/Users/nasu/Bin/ffprobe'
    omit('ffprobe not installed') unless File.executable?(probe)
    stdout, stderr, status = Open3.capture3(probe, '-v', 'error', '-select_streams', 'a:0',
      '-show_packets', '-show_entries', 'packet=pos,size,dts,pts,duration', '-of', 'json', path)
    assert status.success?, stderr
    packets = JSON.parse(stdout).fetch('packets') # テスト専用oracle。製品では呼ばない。
    assert_equal result[:data][:sample_count], packets.size
    [[:first, packets.first], [:last, packets.last]].each do |key, packet|
      sample = result[:data][key]
      assert_equal sample[:offset], Integer(packet['pos'])
      assert_equal sample[:size], Integer(packet['size'])
      origin = result[:data][:edits]&.first&.fetch(:media_time) || 0
      assert_equal sample[:dts] - origin, packet['dts']
      assert_equal sample[:pts] - origin, packet['pts']
      assert_operator packet['duration'], :<=, sample[:duration]
    end
  end

  def test_real_ffmpeg_priming_edit_and_group_rejection
    ffmpeg, ffprobe = '/Users/nasu/Bin/ffmpeg', '/Users/nasu/Bin/ffprobe'
    omit('ffmpeg/ffprobe not installed') unless [ffmpeg, ffprobe].all? { |p| File.executable?(p) }
    _, stderr, status = Open3.capture3(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i',
      'sine=frequency=440:sample_rate=44100:duration=0.317', '-c:a', 'aac', '-y', @path)
    assert status.success?, stderr
    result = API.open(@path) { |f| f.sample_boundaries(track_id: 1) }
    assert_equal :unsupported, result[:status] # ffmpegのroll groupを無視しない。
    assert result[:issues].any? { |i| i[:message].include?('sgpd') }
    data = result[:data]
    assert_equal 1024, data[:edits].first[:media_time]
    stdout, stderr, status = Open3.capture3(ffprobe, '-v', 'error', '-show_packets', '-of', 'json', @path)
    assert status.success?, stderr
    packets = JSON.parse(stdout).fetch('packets')
    [[:first, packets.first], [:last, packets.last]].each do |key, packet|
      sample = data[key]
      assert_equal sample[:offset], Integer(packet['pos'])
      assert_equal sample[:size], Integer(packet['size'])
      assert_equal sample[:pts] - 1024, packet['pts']
    end
    assert_equal 0, data[:first][:pts]
    assert_equal(-1024, packets.first['pts'])
    assert_equal data[:decode_end], data[:last][:pts] + data[:last][:duration]
    # groupなしの対応構造を別途作る。元入力のgroupを無視して採用する意味ではない。
    edit_fixture(@path) do |moov|
      each_fixture_atom([moov]) do |atom|
        atom[:children].reject! { |a| %w[sgpd sbgp].include?(a[:type]) } if atom[:type] == 'stbl'
      end
    end
    supported = API.open(@path) { |f| f.sample_boundaries(track_id: 1) }
    assert_equal :complete, supported[:status]
    assert_equal data[:first], supported[:data][:first]
    assert_equal data[:last], supported[:data][:last]
  end
end
