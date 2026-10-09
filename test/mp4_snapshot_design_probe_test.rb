# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
# Select an isolated, already-built binding; never mix native backends in one process.
$LOAD_PATH.unshift(ENV.fetch('MDTA_PROBE_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_snapshot_design_probe'

class MP4SnapshotDesignProbeTest < Test::Unit::TestCase
  P = MP4SnapshotDesignProbe

  # Synthesize two independent MP4s with different keys tables and real subtitle samples.
  def setup
    omit 'isolated binding and MListNew source are required for this manual design probe' unless ENV['MDTA_PROBE_LIB'] && ENV['MLIST_ROOT']
    @dir = Dir.mktmpdir('snapshot-design-')
    @source, @destination = %w[source destination].map { |n| File.join(@dir, "#{n}.mp4") }
    @srt = File.join(@dir, 'subtitle.srt')
    File.write(@srt, "1\n00:00:00,000 --> 00:00:00,800\n字幕\n")
    [@source, @destination].each_with_index do |path, i|
      run!(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'color=size=64x64:rate=10:duration=1',
           '-f', 'lavfi', '-i', 'sine=duration=1', '-i', @srt, '-map', '0', '-map', '1', '-map', '2',
           '-c:v', 'libx264', '-c:a', 'aac', '-c:s', 'mov_text', '-write_btrt', '0', '-metadata:s:s:0', 'language=jpn',
           '-metadata', "#{i.zero? ? 'first' : 'other'}=fixture", '-movflags', 'use_metadata_tags', path)
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def ffmpeg
    ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg')
  end

  def run!(*args)
    out, err, status = Open3.capture3(*args)
    assert status.success?, err
    out
  end

  def values
    [[1, 0, 'first'.b], [1, 1041, 'second'.b], [1, 0, 'first'.b], [33, 7, "\0\xff\0".b], [0xffffffff, 0xffffffff, ''.b]]
  end

  def seed
    TagLib::MP4::File.open(@source, false) do |f|
      { 'cpil' => [:bool, false], 'tmpo' => [:int, -42], 'trkn' => [:int_pair, [1, 2]],
        'rtng' => [:byte, 255], 'tvsn' => [:uint, 0xffffffff], 'plID' => [:long_long, -0x8000000000000000],
        '----:probe:binary' => [:byte_vector_list, ["\0\xff".b, ''.b]] }.each do |key, (kind, value)|
        f.tag.item_map.insert(key, TagLib::MP4::Item.public_send("from_#{kind}", value))
      end
      f.tag.item_map.insert('desc', TagLib::MP4::Item.from_string_list(%w[first second first]))
      art = File.binread(File.join(__dir__, 'data/globe_east_90.jpg'))
      f.tag.item_map.insert('covr', TagLib::MP4::Item.from_cover_art_list([TagLib::MP4::CoverArt.new(TagLib::MP4::CoverArt::JPEG, art)] * 2))
      %w[shared new-key].each { |key| f.tag.replace_mdta_items(key, values.map { |t, l, d| { data_type: t, locale: l, data: d } }) }
      assert f.save
    end
    TagLib::MP4::File.open(@source, false) { |f| P.capture(f.tag) }
  end

  def test_detached_snapshot_roundtrip_across_indices_and_repetition
    snapshot = seed
    GC.start
    assert snapshot.frozen?
    assert_raise(FrozenError) { snapshot[:mdta].last.last << 'x' }
    TagLib::MP4::File.open(@destination, false) do |f|
      f.tag.replace_mdta_items('filler', [{ data_type: 1, locale: 0, data: 'extra' }])
      f.tag.replace_mdta_items('shared', [{ data_type: 1, locale: 0, data: 'destination' }])
      index = f.tag.mdta_item('shared').key_index
      before_media = f.send(:mdat_payload_signature, @destination)
      restored_index = nil
      2.times do |pass|
        assert_same f.tag, P.restore(f, snapshot)
        assert f.save
        actual = P.capture(f.tag)
        assert_equal P.logical(snapshot), P.logical(actual)
        current_index = f.tag.mdta_item('shared').key_index
        if pass.zero?
          assert_not_equal index, current_index, 'counterexample: removing destination-only keys compacts existing indices'
          restored_index = current_index
        else
          assert_equal restored_index, current_index
        end
        assert_not_equal snapshot[:mdta].map { |r| r[1] }, actual[:mdta].map { |r| r[1] }, 'structural comparison must detect keys/index differences'
        assert_equal before_media, f.send(:mdat_payload_signature, @destination)
      end
    end
  end

  def test_late_failure_preserves_pending_state_disk_and_public_map
    snapshot = seed
    TagLib::MP4::File.open(@destination, false) do |f|
      f.tag.set_property('comment', 'pending')
      before = P.capture(f.tag)
      disk = Digest::SHA256.file(@destination).hexdigest
      map = f.tag.item_map
      assert_raise(P::Unsupported) { P.restore(f, snapshot, fail_after_key: 'new-key') }
      assert_equal before, P.capture(f.tag)
      assert_equal disk, Digest::SHA256.file(@destination).hexdigest
      assert_equal true, f.send(:metadata_dirty?)
      assert_equal ['pending'], map['©cmt'].to_string_list
      invalid = { items: snapshot[:items], mdta: snapshot[:mdta].map(&:dup) }
      invalid[:mdta][-1][2] = -1
      assert_raise(TagLib::MP4::MdtaItemError) { P.restore(f, invalid) }
      assert_equal before, P.capture(f.tag)
      assert f.save
      assert_equal before, P.capture(f.tag)
    end
  end

  def test_all_ruby_item_kinds_are_detached_but_unknown_is_rejected
    TagLib::MP4::File.open(@destination, false) do |f|
      samples = { bool: false, int: -42, int_pair: [1, 2], byte: 255, uint: 0xffffffff,
                  long_long: -0x8000000000000000, string_list: ['a', 'a', ''], byte_vector_list: ["\0\xff".b, ''.b] }
      samples.each { |kind, payload| f.tag.item_map.insert("----:probe:#{kind}", TagLib::MP4::Item.public_send("from_#{kind}", payload)) }
      copy = P.capture(f.tag)
      samples.each { |kind, payload| assert_equal payload, copy[:items].find { |row| row[0] == "----:probe:#{kind}" }[2] }
      f.tag.item_map.insert('----:probe:invalid', TagLib::MP4::Item.new)
      assert_raise(P::Unsupported) { P.capture(f.tag) }
    end
  end

  def test_property_normalization_and_native_title_setter_are_distinct
    TagLib::MP4::File.open(@source, false) do |f|
      { 'title' => 'title', 'artist' => 'artist', 'description' => 'description', 'TVShowName' => 'show' }.each do |property, key|
        f.tag.replace_mdta_items(key, [{ data_type: 1, locale: 0, data: 'mdta' }])
        f.tag.set_property(property, 'ordinary')
        assert_nil f.tag.mdta_item(key)
        assert_equal ['ordinary'], f.tag.property_values(property)
      end
      f.tag.replace_mdta_items('title', [{ data_type: 1, locale: 0, data: 'mdta' }])
      f.tag.title = 'native setter'
      assert_equal 'mdta', f.tag.mdta_item('title').data
      assert_equal 'native setter', f.tag.title
      assert f.save
    end
  end

  def test_item_writer_width_is_not_the_ruby_integer_range
    TagLib::MP4::File.open(@destination, false) do |f|
      before = Digest::SHA256.file(@destination).hexdigest
      f.tag.item_map.insert('tmpo', TagLib::MP4::Item.from_int(0x10000))
      assert_equal 0x10000, f.tag.item_map['tmpo'].to_int
      error = assert_raise(TagLib::MP4::MdtaSaveError) { f.save }
      assert_equal false, error.committed
      assert_equal :verify, error.phase
      assert_equal before, Digest::SHA256.file(@destination).hexdigest
      assert_equal 0x10000, f.tag.item_map['tmpo'].to_int
    end
  end

  # Edit only synthetic terminal metadata and rebuild ancestor sizes; samples stay untouched.
  def rewrite_boxes(bytes, &edit)
    offset = 0
    result = ''.b
    while offset < bytes.bytesize
      size, type = bytes.byteslice(offset, 8).unpack('Na4')
      raise 'unsupported fixture atom' if size < 8 || offset + size > bytes.bytesize
      payload = bytes.byteslice(offset + 8, size - 8)
      payload = rewrite_boxes(payload, &edit) if %w[moov udta].include?(type)
      if type == 'meta'
        payload = payload.byteslice(0, 4) + rewrite_boxes(payload.byteslice(4..), &edit)
      elsif type == 'ilst'
        payload = edit.call(payload)
      end
      result << [payload.bytesize + 8].pack('N') << type.b << payload
      offset += size
    end
    result
  end

  def test_key_only_entry_is_invisible_to_flat_api
    first_key = nil
    TagLib::MP4::File.open(@source, false) { |f| first_key = f.tag.mdta_items.first.key }
    bytes = rewrite_boxes(File.binread(@source)) do |ilst|
      size = ilst.unpack1('N')
      ilst.byteslice(size..)
    end
    File.binwrite(@source, bytes)
    TagLib::MP4::File.open(@source, false) do |f|
      assert_nil f.tag.mdta_item(first_key), 'counterexample: flat API cannot distinguish a key-only entry from absence'
      assert_empty P.capture(f.tag)[:mdta].select { |r| r[0] == first_key }
    end
  end

  def test_invalid_index_is_read_only_and_explicitly_refused
    bytes = rewrite_boxes(File.binread(@source)) do |ilst|
      modified = ilst.dup
      modified[4, 4] = [0].pack('N')
      modified
    end
    File.binwrite(@source, bytes)
    before = Digest::SHA256.file(@source).hexdigest
    TagLib::MP4::File.open(@source, false) do |f|
      assert_equal :unsupported, f.tag.mdta_status if f.tag.mdta_status != :unknown
      assert_raise(TagLib::MP4::MdtaItemError) { f.tag.replace_mdta_items('new', [{ data_type: 1, locale: 0, data: 'x' }]) }
    end
    assert_equal before, Digest::SHA256.file(@source).hexdigest
  end

  def test_single_setter_loss_and_order_sensitive_comparison
    seed
    TagLib::MP4::File.open(@source, false) do |f|
      expected = P.capture(f.tag)
      rows = expected[:mdta].select { |r| r[0] == 'shared' }
      require File.join(ENV.fetch('MLIST_ROOT'), 'libs/media/mp4_tag_metadata_snapshot')
      Mp4TagMetadataSnapshot.capture(f.tag).restore_to(f.tag)
      assert f.save
      actual = P.capture(f.tag)
      assert_equal [rows.last], actual[:mdta].select { |r| r[0] == 'shared' }
      assert_not_equal P.logical(expected), P.logical(actual)
      reordered = { items: expected[:items], mdta: expected[:mdta].reverse }
      assert_not_equal P.logical(expected), P.logical(reordered)
    end
  end

  # Exercise the actual MListNew comparator without its mux/repair dependencies.
  def test_mlist_comparator_accepts_reordered_values_counterexample
    root = ENV.fetch('MLIST_ROOT')
    require File.join(root, 'libs/media/mp4_tag_metadata_snapshot')
    rows = [['shared', 1, 1, 0, 'first'.b], ['shared', 1, 1, 1041, 'second'.b], ['shared', 1, 1, 0, 'first'.b]]
    a = Mp4TagMetadataSnapshot.new(properties: {}, mdta_items: rows, item_map: [])
    b = Mp4TagMetadataSnapshot.new(properties: {}, mdta_items: rows.reverse.rotate, item_map: [])
    assert a.preserved_by?(b), 'counterexample: current comparator treats per-key order as irrelevant'
    assert_not_equal P.logical({ items: [], mdta: a.mdta_items }), P.logical({ items: [], mdta: b.mdta_items })
  end

  # Normalize timestamps by stream time_base and retain duplicate subtitle streams as a multiset.
  def subtitles(path)
    raw = JSON.parse(run!(ffmpeg.sub(/ffmpeg\z/, 'ffprobe'), '-v', 'error', '-select_streams', 's',
      '-show_streams', '-show_packets', '-show_data_hash', 'sha256', '-of', 'json', path))
    raw.fetch('streams').map do |s|
      clock = Rational(s.fetch('time_base'))
      packets = raw.fetch('packets').select { |p| p['stream_index'] == s['index'] }.map do |p|
        [Rational(p.fetch('pts')) * clock, Rational(p.fetch('duration', 0)) * clock, p.fetch('data_hash')]
      end
      [s['codec_name'], s['extradata_hash'], s.fetch('tags', {}).slice('language', 'title'), s['disposition'], packets]
    end.sort_by(&:inspect)
  end

  def test_subtitles_survive_audio_conversion_and_duplicate_mux_but_loss_is_detected
    baseline = subtitles(@source)
    changed_config = File.join(@dir, 'changed-config.mp4')
    run!(ffmpeg, '-v', 'error', '-i', @source, '-map', '0', '-c', 'copy', '-c:a', 'aac', changed_config)
    assert_not_equal baseline, subtitles(changed_config), 'default mux adds btrt codec bytes; strict preservation rejects it'
    converted = File.join(@dir, 'converted.mp4')
    run!(ffmpeg, '-v', 'error', '-i', @source, '-map', '0', '-c', 'copy', '-c:a', 'aac', '-write_btrt', '0', converted)
    assert_equal baseline, subtitles(converted)
    doubled = File.join(@dir, 'doubled.mp4')
    run!(ffmpeg, '-v', 'error', '-i', @source, '-map', '0:v', '-map', '0:a', '-map', '0:s', '-map', '0:s', '-c', 'copy', '-write_btrt', '0', doubled)
    actual = subtitles(doubled)
    # FFmpeg may choose a different default disposition for the second stream.
    assert_equal 2, actual.length
    assert_equal [baseline.first.last] * 2, actual.map(&:last)
    assert_not_equal actual, baseline, 'duplicate subtitles must not collapse during comparison'
    stripped = File.join(@dir, 'stripped.mp4')
    run!(ffmpeg, '-v', 'error', '-i', @source, '-map', '0:v', '-map', '0:a', '-c', 'copy', stripped)
    assert_not_equal baseline, subtitles(stripped)
    changed = Marshal.load(Marshal.dump(baseline))
    changed[0][-1][0][0] += Rational(1, 1000)
    assert_not_equal baseline, changed
    TagLib::MP4::File.open(converted, false) { |f| f.tag.set_property('comment', 'save'); assert f.save }
    assert_equal baseline, subtitles(converted)
  end
end
