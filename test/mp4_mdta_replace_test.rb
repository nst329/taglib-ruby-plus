# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'digest'
require 'json'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__), File.expand_path('../ext/taglib_mp4', __dir__))
require 'taglib/base'
require 'taglib/mp4'

class MP4MdtaReplaceTest < Test::Unit::TestCase
  # Make a real video/audio/subtitle MP4 with moov last, allowing safe fixture atom edits.
  def setup
    @dir = Dir.mktmpdir('mdta-replace-')
    @path = File.join(@dir, 'fixture.mp4')
    source = File.join(@dir, 'source.mp4')
    run!(RbConfig.ruby, File.join(__dir__, 'generate_mp4_mdta_fixture.rb'), source)
    subtitle = File.join(@dir, 'subtitle.srt')
    File.write(subtitle, "1\n00:00:00,000 --> 00:00:00,900\nSubtitle\n")
    run!(ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg'), '-v', 'error', '-i', source,
         '-i', subtitle, '-map', '0', '-map', '1', '-c', 'copy', '-c:s', 'mov_text',
         '-movflags', 'use_metadata_tags', @path)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def run!(*args)
    out, err, status = Open3.capture3(*args)
    assert status.success?, "#{args.inspect}\n#{out}\n#{err}"
  end

  # Compare stream identities and every encoded packet, including subtitle payloads.
  def media_probe
    ffprobe = ENV.fetch('FFPROBE', ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg').sub(/ffmpeg\z/, 'ffprobe'))
    out, err, status = Open3.capture3(ffprobe, '-v', 'error', '-show_packets', '-show_data_hash', 'sha256',
                                    '-show_entries', 'packet=stream_index,pts,dts,duration,data_hash:stream=index,codec_name,codec_type',
                                    '-of', 'json', @path)
    assert status.success?, err
    JSON.parse(out)
  end

  def values
    [
      { data_type: 1, locale: 0, data: 'first'.b },
      { data_type: 1, locale: 1041, data: 'second'.b },
      { data_type: 1, locale: 0, data: 'first'.b },
      { data_type: 33, locale: 7, data: "\0\xff\0".b },
      { data_type: 0xffff_ffff, locale: 0xffff_ffff, data: ''.b }
    ]
  end

  def snapshot(tag)
    tag.mdta_items.map { |v| [v.key, v.key_index, v.data_type, v.locale, v.data] }
  end

  def assert_values(tag, key, index)
    actual = tag.mdta_items.select { |v| v.key == key }
    assert_equal values.map { |v| [key, index, v[:data_type], v[:locale], v[:data]] },
                 actual.map { |v| [v.key, v.key_index, v.data_type, v.locale, v.data] }
    assert actual.all? { |v| v.data.encoding == Encoding::BINARY }
  end

  def test_existing_and_new_keys_preserve_every_value_and_other_metadata
    art = TagLib::MP4::Artwork.new(format: :jpeg, data: File.binread(File.join(__dir__, 'data/globe_east_90.jpg')))
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.title = 'iTunes title'
      file.tag.set_artwork(art)
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      assert file.save
    end
    TagLib::MP4::File.open(@path, false) do |file|
      tag = file.tag
      key = 'audio_normalization'
      index = tag.mdta_item(key).key_index
      other = snapshot(tag).reject { |v| v[0] == key }
      new_index = tag.mdta_items.map(&:key_index).max + 1
      media = file.send(:mdat_payload_signature, @path)
      tracks = file.send(:chapter_media_signature, @path)
      streams = media_probe
      assert streams.fetch('streams').any? { |stream| stream['codec_type'] == 'subtitle' }
      3.times do
        assert_same tag, tag.replace_mdta_items(key, values)
        tag.replace_mdta_items('com.example.new', values)
        assert file.save
        tag = file.tag
        assert_values(tag, key, index)
        assert_values(tag, 'com.example.new', new_index)
        assert_equal other, snapshot(tag).reject { |v| [key, 'com.example.new'].include?(v[0]) }
        assert_equal 'iTunes title', tag.title
        assert_equal [art], tag.artwork
        assert_equal ['Opening'], file.chapters.map(&:title)
        assert_equal media, file.send(:mdat_payload_signature, @path)
        assert_equal tracks, file.send(:chapter_media_signature, @path)
        assert_equal streams, media_probe
      end
    end
  end

  def test_reads_and_replaces_multiple_data_children_and_repeated_key_atoms
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.replace_mdta_items('audio_normalization', values)
      assert file.save
    end
    index = nil
    TagLib::MP4::File.open(@path, false) { |f| index = f.tag.mdta_item('audio_normalization').key_index }
    name = [index].pack('N')
    data_children = values.map { |v| box('data', [v[:data_type], v[:locale]].pack('N2') + v[:data]) }.join.b
    # Rebuild the first numeric item and remove the remaining items for this key.
    rewrite_meta do |meta|
      children = ''.b
      offset = 4
      while offset < meta.bytesize
        size, type = meta.byteslice(offset, 8).unpack('Na4')
        payload = meta.byteslice(offset + 8, size - 8)
        if type == 'ilst'
          result = ''.b
          item_offset = 0
          inserted = false
          while item_offset < payload.bytesize
            item_size, item_name = payload.byteslice(item_offset, 8).unpack('Na4')
            if item_name == name
              result << box(name, data_children) unless inserted
              inserted = true
            else
              result << payload.byteslice(item_offset, item_size)
            end
            item_offset += item_size
          end
          payload = result
        end
        children << box(type, payload)
        offset += size
      end
      meta.byteslice(0, 4) + children
    end
    TagLib::MP4::File.open(@path, false) do |file|
      assert_values(file.tag, 'audio_normalization', index)
      file.tag.replace_mdta_items('audio_normalization', values)
      assert file.save
      assert_values(file.tag, 'audio_normalization', index)
    end
  end

  def test_invalid_input_is_atomic_even_if_later_value_is_invalid
    bad_values = [nil, [], {}, [nil], [values.first, { data_type: -1, locale: 0, data: 'x' }],
                  [values.first.merge(locale: 0x1_0000_0000)], [values.first.merge(data_type: 1.0)],
                  [values.first.merge(locale: nil)], [values.first.merge(data: nil)],
                  [values.first.merge(extra: true)], [{ 'data_type' => 1, 'locale' => 0, 'data' => 'x' }]]
    TagLib::MP4::File.open(@path, false) do |file|
      before = snapshot(file.tag)
      bad_values.each do |bad|
        assert_raise(TagLib::MP4::MdtaItemError) { file.tag.replace_mdta_items('new-key', bad) }
        assert_equal before, snapshot(file.tag)
      end
      [nil, '', "bad\0key", "\xff".dup.force_encoding('UTF-8'), 'binary'.b].each do |key|
        assert_raise(TagLib::MP4::MdtaItemError) { file.tag.replace_mdta_items(key, values) }
        assert_equal before, snapshot(file.tag)
      end
      assert file.save
      assert_equal before, snapshot(file.tag)
    end
  end

  def test_save_failure_keeps_disk_and_pending_values_then_allows_retry
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.replace_mdta_items('audio_normalization', values)
      expected = snapshot(file.tag)
      original = Digest::SHA256.file(@path).hexdigest
      file.define_singleton_method(:save_temporary_copy) do |path, write_metadata:|
        super(path, write_metadata: write_metadata)
        raise IOError, 'injected failure after temporary save'
      end
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
      assert_equal false, error.committed
      assert_equal original, Digest::SHA256.file(@path).hexdigest
      assert_equal expected, snapshot(file.tag)
      assert_empty Dir.glob("#{@path}.taglib-mdta-*")
      file.singleton_class.remove_method(:save_temporary_copy)
      assert file.save
      assert_equal expected, snapshot(file.tag)
    end
  end

  def test_single_value_setter_still_replaces_all_values
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.replace_mdta_items('audio_normalization', values)
      file.tag.set_mdta_item('audio_normalization', 'last')
      assert file.save
      assert_equal ['last'], file.tag.mdta_items.select { |v| v.key == 'audio_normalization' }.map(&:data)
    end
  end

  # Rewrite only terminal moov metadata; sample offsets and the media payload remain unchanged.
  def rewrite_meta(&block)
    File.binwrite(@path, rewrite_boxes(File.binread(@path), &block))
  end

  def rewrite_boxes(bytes, &block)
    result = ''.b
    offset = 0
    while offset < bytes.bytesize
      size, type = bytes.byteslice(offset, 8).unpack('Na4')
      raise 'invalid fixture atom' if size < 8
      payload = bytes.byteslice(offset + 8, size - 8)
      payload = rewrite_boxes(payload, &block) if %w[moov udta].include?(type)
      payload = block.call(payload) if type == 'meta'
      result << box(type, payload)
      offset += size
    end
    result
  end

  def box(type, payload)
    [payload.bytesize + 8].pack('N') + type.b + payload
  end

  def test_unsupported_structures_fail_without_state_or_disk_changes
    original = File.binread(@path)
    mutations = [
      ->(meta) { meta.sub('mdta', 'mdir') },
      ->(meta) { meta.sub('keys', 'free') },
      ->(meta) { meta.sub('ilst', 'free') },
      ->(meta) { meta.sub('mdtatitle', 'xxxxtitle').b },
      ->(meta) { meta + box('keys', [0, 0].pack('N2')) },
      ->(meta) { meta + box('ilst', ''.b) }
    ]
    mutations.each do |mutation|
      File.binwrite(@path, original)
      rewrite_meta(&mutation)
      before_disk = File.binread(@path)
      TagLib::MP4::File.open(@path, false) do |file|
        before = snapshot(file.tag)
        assert_raise(TagLib::MP4::MdtaItemError) { file.tag.replace_mdta_items('new-key', values) }
        assert_equal before, snapshot(file.tag)
      end
      assert_equal before_disk, File.binread(@path)
    end
  end

  def test_pure_mdir_does_not_create_an_unsupported_mdta_structure
    FileUtils.cp(File.join(__dir__, 'data/mp4.m4a'), @path)
    TagLib::MP4::File.open(@path, false) do |file|
      title = file.tag.title
      before = File.binread(@path)
      assert_raise(TagLib::MP4::MdtaItemError) { file.tag.replace_mdta_items('new-key', values) }
      assert_equal title, file.tag.title
      assert_equal before, File.binread(@path)
    end
  end

  def test_multiple_meta_boxes_are_rejected_in_either_order
    original = File.binread(@path)
    [true, false].each do |mdta_first|
      File.binwrite(@path, original)
      bytes = rewrite_boxes(original) { |meta| meta }
      # Append another meta within udta, rebuilding parent sizes with moov last.
      transform = lambda do |data|
        offset = 0
        result = ''.b
        while offset < data.bytesize
          size, type = data.byteslice(offset, 8).unpack('Na4')
          payload = data.byteslice(offset + 8, size - 8)
          if type == 'moov'
            payload = transform.call(payload)
          elsif type == 'udta'
            mdir = box('meta', "\0".b * 4 + box('hdlr', "\0".b * 8 + 'mdir' + "\0".b * 12) + box('ilst', ''.b))
            payload = mdta_first ? payload + mdir : mdir + payload
          end
          result << box(type, payload)
          offset += size
        end
        result
      end
      File.binwrite(@path, transform.call(bytes))
      TagLib::MP4::File.open(@path, false) do |file|
        before = snapshot(file.tag)
        assert_raise(TagLib::MP4::MdtaItemError) { file.tag.replace_mdta_items('new-key', values) }
        assert_equal before, snapshot(file.tag)
      end
    end
  end
end
