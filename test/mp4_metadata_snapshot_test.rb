# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'

class MP4MetadataSnapshotTest < Test::Unit::TestCase
  # Real video/audio/mov_text samples and independent mdta keys tables; originals are synthetic.
  def setup
    @dir = Dir.mktmpdir('public-snapshot-')
    @source, @destination = %w[source destination].map { |n| File.join(@dir, "#{n}.mp4") }
    srt = File.join(@dir, 's.srt')
    File.write(srt, "1\n00:00:00,000 --> 00:00:00,800\n字幕\n")
    [@source, @destination].each_with_index do |path, i|
      run!(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'color=size=64x64:rate=10:duration=1',
           '-f', 'lavfi', '-i', 'sine=duration=1', '-i', srt, '-c:v', 'libx264', '-c:a', 'aac',
           '-c:s', 'mov_text', '-write_btrt', '0', '-movflags', 'use_metadata_tags',
           '-metadata', "#{i.zero? ? 'source-only' : 'destination-only'}=fixture", path)
    end
    open_mp4(@source) { |f| omit 'native snapshot patch is required' unless f.tag.metadata_capabilities[:snapshot_v1] }
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

  def open_mp4(path, &block)
    TagLib::MP4::File.open(path, false, &block)
  end

  def snapshot(path)
    open_mp4(path) { |f| f.tag.metadata_snapshot }
  end

  def values
    [[1, 0, 'first'.b], [1, 1041, 'second'.b], [1, 0, 'first'.b], [33, 7, "\0\xff".b], [0xffffffff, 0xffffffff, ''.b]]
  end

  def seed
    open_mp4(@source) do |f|
      { 'cpil' => [:bool, false], 'tmpo' => [:int, -42], 'trkn' => [:int_pair, [1, 2]],
        'rtng' => [:byte, 255], 'tvsn' => [:uint, 0xffffffff], 'plID' => [:long_long, -0x8000000000000000] }.each do |key, (kind, payload)|
        f.tag.item_map.insert(key, TagLib::MP4::Item.public_send("from_#{kind}", payload))
      end
      text = TagLib::MP4::Item.from_string_list([])
      text._set_snapshot_strings(["first second", '', '重複', '重複'])
      f.tag.item_map.insert('desc', text)
      binary = TagLib::MP4::Item.from_byte_vector_list(["\0\xff".b, ''.b, "\0\xff".b])
      binary.set_atom_data_type(8)
      f.tag.item_map.insert('----:probe:uuid', binary)
      art = File.binread(File.join(__dir__, 'data/globe_east_90.jpg'))
      f.tag.item_map.insert('covr', TagLib::MP4::Item.from_cover_art_list([TagLib::MP4::CoverArt.new(13, art)] * 2))
      %w[shared new-key].each { |key| f.tag.replace_mdta_items(key, values.map { |t, l, d| { data_type: t, locale: l, data: d } }) }
      assert f.save
    end
    snapshot(@source)
  end

  def test_close_gc_and_deep_ownership_preserve_all_fields
    captured = seed
    GC.start
    assert captured.frozen?
    assert_raise(FrozenError) { captured.mdta.last.last.last.last << 'x' }
    assert_raise(FrozenError) { captured.items.first[0] << 'x' }
    assert_equal "first second", captured.items.find { |r| r[0] == 'desc' }[3].first
    assert_equal 8, captured.items.find { |r| r[0] == '----:probe:uuid' }[2]
    assert_equal values, captured.mdta.find { |r| r[0] == 'shared' }[2]
    assert captured.structure_equal?(snapshot(@source))
  end

  def test_restore_retains_existing_indices_and_empty_keys_and_is_idempotent
    expected = seed
    open_mp4(@destination) do |f|
      f.tag.replace_mdta_items('extra', [{ data_type: 1, locale: 0, data: 'remove values' }])
      f.tag.replace_mdta_items('shared', [{ data_type: 1, locale: 0, data: 'replace' }])
      indices = f.tag._metadata_keys.each_with_index.to_h { |key, i| [key, i + 1] }
      map = f.tag.item_map
      media = f.send(:mdat_payload_signature, @destination)
      streams = packets(@destination)
      3.times do
        assert_same f.tag, f.tag.restore_metadata_snapshot(expected)
        assert_equal false, map.empty? if map
        map = nil # File#save retains its existing close/reopen lifetime contract.
        assert f.save
        actual = f.tag.metadata_snapshot
        assert expected.logical_equal?(actual)
        assert_equal indices['shared'], f.tag.mdta_item('shared').key_index
        assert_equal [], actual.mdta.find { |r| r[0] == 'extra' }[2]
        assert_equal [], actual.mdta.find { |r| r[0] == 'destination-only' }[2]
        assert_equal indices.keys, f.tag._metadata_keys.first(indices.length)
        assert_equal media, f.send(:mdat_payload_signature, @destination)
        assert_equal streams, packets(@destination)
        assert_equal expected.items, actual.items
        assert_not_equal expected.mdta, actual.mdta
      end
    end
  end

  def test_public_restore_after_subtitle_mux_and_audio_conversion
    expected = seed
    original = Digest::SHA256.file(@source).hexdigest
    baseline = subtitles(@source)
    %i[audio_conversion subtitle_mux].each do |operation|
      output = File.join(@dir, "#{operation}.mp4")
      maps = ['-map', '0:v:0', '-map', '0:a', '-map', '0:s']
      maps += ['-map', '0:s'] if operation == :subtitle_mux
      options = operation == :audio_conversion ? ['-c:a', 'aac'] : []
      run!(ffmpeg, '-v', 'error', '-i', @source, *maps, '-c', 'copy', *options,
           '-write_btrt', '0', '-movflags', 'use_metadata_tags', output)
      before = subtitles(output)
      if operation == :audio_conversion
        assert_equal baseline, before
      else
        assert_equal 2, before.length
        assert_equal [baseline.first.last] * 2, before.map(&:last)
      end
      open_mp4(output) do |f|
        f.tag.restore_metadata_snapshot(expected)
        assert f.save
        assert expected.logical_equal?(f.tag.metadata_snapshot)
      end
      assert_equal before, subtitles(output)
      assert_equal original, Digest::SHA256.file(@source).hexdigest
    end
  end

  def test_restore_failure_keeps_pending_values_and_borrowed_item
    expected = seed
    open_mp4(@destination) do |f|
      f.tag.set_property('comment', 'pending')
      before = f.tag.metadata_snapshot
      borrowed = f.tag.item_map['©cmt']
      original = Digest::SHA256.file(@destination).hexdigest
      bad = TagLib::MP4::MetadataSnapshot.new(items: expected.items + [['zzzz', :string_list, 255, ['unsupported']]], mdta: expected.mdta)
      error = assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.restore_metadata_snapshot(bad) }
      assert_equal :unsupported_item, error.code
      assert before.structure_equal?(f.tag.metadata_snapshot)
      assert_equal ['pending'], borrowed.to_string_list
      assert f.send(:metadata_dirty?)
      assert_equal original, Digest::SHA256.file(@destination).hexdigest
      assert f.save
    end
  end

  def test_invalid_snapshot_input_and_writer_width_are_rejected_before_commit
    expected = seed
    bad_groups = expected.mdta.map { |k, i, vals| [k, i, vals.map(&:dup)] }
    bad_groups.last.last.last[0] = -1
    assert_raise(TagLib::MP4::MetadataSnapshotError) { TagLib::MP4::MetadataSnapshot.new(items: expected.items, mdta: bad_groups) }
    assert_raise(TagLib::MP4::MetadataSnapshotError) { TagLib::MP4::MetadataSnapshot.new(items: [], mdta: [], format_version: 2) }
    open_mp4(@destination) do |f|
      before = f.tag.metadata_snapshot
      bad = TagLib::MP4::MetadataSnapshot.new(items: [['tmpo', :int, 255, 65536]], mdta: expected.mdta)
      assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.restore_metadata_snapshot(bad) }
      assert before.structure_equal?(f.tag.metadata_snapshot)
      assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.restore_metadata_snapshot({}) }
    end
  end

  def test_native_late_failure_does_not_change_any_item_or_mdta
    open_mp4(@destination) do |f|
      before = f.tag.metadata_snapshot
      items = TagLib::MP4::ItemMap.new
      items.insert('desc', TagLib::MP4::Item.from_string_list(['would change']))
      assert_equal false, f.tag._restore_metadata(items, [['valid', 1, [[1, 0, 'x']]], ['', 2, [[1, 0, 'bad']]]])
      assert before.structure_equal?(f.tag.metadata_snapshot)
      assert_equal false, f.send(:metadata_dirty?)
    end
  end

  def test_empty_values_are_preserved_and_single_key_api_still_rejects_empty_array
    empty = TagLib::MP4::MetadataSnapshot.new(items: [], mdta: [['key-only', 1, []]])
    open_mp4(@destination) do |f|
      f.tag.restore_metadata_snapshot(empty)
      assert f.save
      actual = f.tag.metadata_snapshot
      assert empty.logical_equal?(actual)
      assert_equal [], actual.mdta.find { |r| r[0] == 'key-only' }[2]
      assert_raise(TagLib::MP4::MdtaItemError) { f.tag.replace_mdta_items('key-only', []) }
      assert_nil f.tag.mdta_item('key-only')
    end
  end

  def test_pure_mdir_roundtrip_and_no_implicit_mdta_creation
    path = File.join(@dir, 'mdir.m4a')
    FileUtils.cp(File.join(__dir__, 'data/mp4.m4a'), path)
    expected = snapshot(path)
    assert_empty expected.mdta
    open_mp4(path) do |f|
      f.tag.set_property('comment', 'different')
      f.tag.restore_metadata_snapshot(expected)
      assert f.save
      assert expected.logical_equal?(f.tag.metadata_snapshot)
      mdta = TagLib::MP4::MetadataSnapshot.new(items: [], mdta: [['new', 1, [[1, 0, 'x']]]])
      before = f.tag.metadata_snapshot
      assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.restore_metadata_snapshot(mdta) }
      assert before.structure_equal?(f.tag.metadata_snapshot)
    end
  end

  def test_save_failure_keeps_original_and_pending_snapshot_for_retry
    expected = seed
    open_mp4(@destination) do |f|
      f.tag.restore_metadata_snapshot(expected)
      before = f.tag.metadata_snapshot
      disk = Digest::SHA256.file(@destination).hexdigest
      f.define_singleton_method(:save_temporary_copy) do |path, write_metadata:|
        super(path, write_metadata: write_metadata)
        raise IOError, 'injected failure after temporary save'
      end
      error = assert_raise(TagLib::MP4::MdtaSaveError) { f.save }
      assert_equal false, error.committed
      assert_equal disk, Digest::SHA256.file(@destination).hexdigest
      assert before.structure_equal?(f.tag.metadata_snapshot)
      f.singleton_class.remove_method(:save_temporary_copy)
      assert f.save
      assert expected.logical_equal?(f.tag.metadata_snapshot)
    end
  end

  def test_reopen_failure_reports_committed_and_snapshot_remains_usable
    expected = seed
    # 再オープン失敗後はnative Fileが閉じているため、block形式の自動closeを使わない。
    f = TagLib::MP4::File.new(@destination, false)
    f.tag.restore_metadata_snapshot(expected)
    f.define_singleton_method(:initialize) { |*_args| raise IOError, 'injected reopen failure' }
    error = assert_raise(TagLib::MP4::MdtaSaveError) { f.save }
    assert_equal true, error.committed
    assert_equal :reopen, error.phase
    assert expected.logical_equal?(snapshot(@destination))
    assert expected.frozen?
  end

  def test_logical_comparison_checks_order_locale_type_duplicates_and_binary
    expected = seed
    groups = expected.mdta.map { |k, i, v| [k, i + 10, v] }.reverse
    shifted = TagLib::MP4::MetadataSnapshot.new(items: expected.items, mdta: groups)
    assert expected.logical_equal?(shifted)
    assert_equal false, expected.structure_equal?(shifted)
    %i[order locale type duplicate binary].each do |change|
      rows = values.map(&:dup)
      case change
      when :order then rows.rotate!
      when :locale then rows[0][1] += 1
      when :type then rows[0][0] += 1
      when :duplicate then rows.delete_at(2)
      when :binary then rows[0][2] = 'different'.b
      end
      other = TagLib::MP4::MetadataSnapshot.new(items: expected.items, mdta: expected.mdta.map { |k, i, v| [k, i, k == 'shared' ? rows : v] })
      assert_equal false, expected.logical_equal?(other), change.to_s
    end
  end

  # Rewrite synthetic metadata only; terminal moov keeps every media sample offset valid.
  def rewrite_boxes(bytes, &edit)
    offset = 0
    result = ''.b
    while offset < bytes.bytesize
      size, type = bytes.byteslice(offset, 8).unpack('Na4')
      raise 'unsupported fixture box' unless size >= 8 && offset + size <= bytes.bytesize
      payload = bytes.byteslice(offset + 8, size - 8)
      payload = rewrite_boxes(payload, &edit) if %w[moov udta].include?(type)
      payload = edit.call(payload) if type == 'meta'
      result << [payload.bytesize + 8].pack('N') << type.b << payload
      offset += size
    end
    result
  end

  def test_diagnostics_identify_zero_index_and_handler_mismatch_without_writes
    original = File.binread(@source)
    mutations = {
      invalid_index: lambda { |meta|
        bytes = meta.dup
        ilst = bytes.index('ilst')
        bytes[ilst + 8, 4] = [0].pack('N')
        bytes
      },
      handler_keys_mismatch: ->(meta) { meta.sub('mdta', 'mdir') }
    }
    mutations.each do |code, mutation|
      File.binwrite(@source, rewrite_boxes(original, &mutation))
      before = Digest::SHA256.file(@source).hexdigest
      open_mp4(@source) do |f|
        report = f.tag.metadata_diagnostics
        assert_equal false, report.restorable?
        assert_includes report.issues.map { |i| i[:code] }, code
        assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.metadata_snapshot }
        empty = TagLib::MP4::MetadataSnapshot.new(items: [], mdta: [])
        assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.restore_metadata_snapshot(empty) }
      end
      assert_equal before, Digest::SHA256.file(@source).hexdigest
    end
  end

  def test_unrepresentable_ordinary_duplicates_and_locale_are_refused
    seed
    original = File.binread(@source)
    { duplicate_item: :duplicate, unsupported_item_locale: :locale,
      unsupported_item_structure: :scalar_values }.each do |code, change|
      mutated = rewrite_boxes(original) do |meta|
        offset = 4
        output = meta.byteslice(0, 4)
        while offset < meta.bytesize
          size, type = meta.byteslice(offset, 8).unpack('Na4')
          payload = meta.byteslice(offset + 8, size - 8)
          if type == 'ilst'
            cursor = 0
            items = ''.b
            while cursor < payload.bytesize
              length, name = payload.byteslice(cursor, 8).unpack('Na4')
              item = payload.byteslice(cursor, length)
              if name == 'cpil'
                case change
                when :duplicate then items << item
                when :locale then item[20, 4] = [1041].pack('N')
                when :scalar_values
                  body = item.byteslice(8..)
                  item = [8 + body.bytesize * 2].pack('N') + name + body * 2
                end
              end
              items << item
              cursor += length
            end
            payload = items
          end
          output << [payload.bytesize + 8].pack('N') << type << payload
          offset += size
        end
        output
      end
      File.binwrite(@source, mutated)
      open_mp4(@source) do |f|
        assert_includes f.tag.metadata_diagnostics.issues.map { |issue| issue[:code] }, code
        assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.metadata_snapshot }
      end
    end
  end

  def test_raw_ordinary_text_with_nul_is_explicitly_refused_not_truncated
    open_mp4(@source) do |f|
      f.tag.set_property('description', 'safe text')
      assert f.save
    end
    File.binwrite(@source, File.binread(@source).sub('safe text', "safe\0text".b))
    before = Digest::SHA256.file(@source).hexdigest
    open_mp4(@source) do |f|
      report = f.tag.metadata_diagnostics
      assert_includes report.issues.map { |i| i[:code] }, :unsupported_text
      assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.metadata_snapshot }
    end
    assert_equal before, Digest::SHA256.file(@source).hexdigest
  end

  def test_pending_nul_text_and_unsupported_item_are_rejected_before_restore
    open_mp4(@destination) do |f|
      before = f.tag.metadata_snapshot
      text = TagLib::MP4::MetadataSnapshot.new(items: [['desc', :string_list, 255, ["a\0b"]]], mdta: [])
      assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.restore_metadata_snapshot(text) }
      assert before.structure_equal?(f.tag.metadata_snapshot)
      f.tag.item_map.insert('invalid', TagLib::MP4::Item.new)
      report = f.tag.metadata_diagnostics
      assert_includes report.issues.map { |i| i[:code] }, :unsupported_item
      assert_raise(TagLib::MP4::MetadataSnapshotError) { f.tag.metadata_snapshot }
    end
  end

  def test_comparison_and_public_map_survive_a_successful_in_memory_commit
    expected = seed
    open_mp4(@destination) do |f|
      map = f.tag.item_map
      f.tag.set_property('comment', 'old')
      borrowed = map['©cmt']
      f.tag.restore_metadata_snapshot(expected)
      assert_equal expected.items.map(&:first).sort, map.to_a.map(&:first).sort
      begin
        borrowed.to_string_list
        flunk 'borrowed Item should be invalidated after replacement'
      rescue StandardError => error
        assert_equal 'ObjectPreviouslyDeleted', error.class.to_s
      end
      assert expected.logical_equal?(f.tag.metadata_snapshot)
    end
  end

  # Compare subtitle codec, attributes and ordered payload/timing, retaining duplicate streams.
  def subtitles(path)
    raw = JSON.parse(run!(ffmpeg.sub(/ffmpeg\z/, 'ffprobe'), '-v', 'error', '-select_streams', 's',
      '-show_streams', '-show_packets', '-show_data_hash', 'sha256', '-of', 'json', path))
    raw.fetch('streams').map do |stream|
      clock = Rational(stream.fetch('time_base'))
      rows = raw.fetch('packets').select { |packet| packet['stream_index'] == stream['index'] }.map do |packet|
        [Rational(packet.fetch('pts')) * clock, Rational(packet.fetch('duration', 0)) * clock, packet.fetch('data_hash')]
      end
      [stream['codec_name'], stream['extradata_hash'], stream.fetch('tags', {}).slice('language', 'title'), stream['disposition'], rows]
    end.sort_by(&:inspect)
  end

  # Observe every encoded packet plus subtitle attributes; offsets are not stream identity.
  def packets(path)
    result = JSON.parse(run!(ffmpeg.sub(/ffmpeg\z/, 'ffprobe'), '-v', 'error', '-show_packets', '-show_data_hash', 'sha256',
                    '-show_entries', 'packet=stream_index,pts,dts,duration,data_hash:stream=index,codec_name,codec_type,time_base,extradata_hash:stream_tags=language,title:stream_disposition', '-of', 'json', path))
    streams = result.fetch('streams').reject { |s| s.dig('disposition', 'attached_pic') == 1 }
    indices = streams.map { |s| s['index'] }
    { 'streams' => streams, 'packets' => result.fetch('packets').select { |p| indices.include?(p['stream_index']) } }
  end
end
