# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'

# ©cpy高水準APIを、mdir/mdtaの実ファイル保存・復元で検証する。
class MP4CopyrightTest < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('copyright-probe-')
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  # handlerごとに独立した合成fixtureを作り、既存copyrightと保持対象を併存させる。
  def fixture(layout)
    path = File.join(@dir, "#{layout}.mp4")
    args = [ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg'), '-v', 'error', '-f', 'lavfi',
            '-i', 'sine=duration=0.1', '-c:a', 'aac', '-metadata', 'title=original']
    args += ['-movflags', 'use_metadata_tags'] if layout == :mdta
    _, err, status = Open3.capture3(*args, path)
    assert status.success?, err
    TagLib::MP4::File.open(path, false) do |f|
      assert f.tag.metadata_capabilities[:snapshot_v1], 'native snapshot support required'
      f.tag.item_map.insert('©cpy', TagLib::MP4::Item.from_string_list(['旧著作権', '', '旧著作権']))
      f.tag.item_map.insert('cprt', TagLib::MP4::Item.from_string_list(['independent']))
      art = File.binread(File.join(__dir__, 'data/globe_east_90.jpg'))
      f.tag.item_map.insert('covr', TagLib::MP4::Item.from_cover_art_list([TagLib::MP4::CoverArt.new(13, art)] * 2))
      if layout == :mdta
        values = [[1, 1041, 'other'.b], [33, 7, "\0\xff".b], [1, 1041, 'other'.b]]
        %w[copyright gain].each do |key|
          f.tag.replace_mdta_items(key, values.map { |t, l, b| { data_type: t, locale: l, data: b } })
        end
      end
      assert f.save
    end
    path
  end

  def snapshot(path)
    TagLib::MP4::File.open(path, false) { |f| f.tag.metadata_snapshot }
  end

  def test_copyright_update_and_removal_in_both_layouts
    [:mdir, :mdta].each do |layout|
      path = fixture(layout)
      original = snapshot(path)
      assert_equal ['旧著作権', '', '旧著作権'], original.items.find { |r| r[0] == '©cpy' }[3]
      TagLib::MP4::File.open(path, false) do |f|
        assert_equal '旧著作権', f.tag.property('copyright')
        assert_equal ['旧著作権', '', '旧著作権'], f.tag.property_values('copyright')
        assert_equal ['旧著作権', '', '旧著作権'], f.tag.properties['copyright']
        f.tag.set_property('copyright', '新しい著作権')
        changes = original.diff(f.tag.metadata_snapshot)
        assert_equal [{ area: :items, key: '©cpy' }], changes.map { |v| v.slice(:area, :key) }
        assert_equal({ items: { set: ['©cpy'], remove: [] }, mdta: { remove: [] } }, f.tag.property_update_effects(:copyright))
        assert f.save
      end
      actual = snapshot(path)
      assert_equal ['新しい著作権'], actual.items.find { |r| r[0] == '©cpy' }[3]
      assert_equal original.mdta, actual.mdta
      assert_equal original.items.reject { |r| r[0] == '©cpy' }, actual.items.reject { |r| r[0] == '©cpy' }
      assert_equal original.items.find { |r| r[0] == '©cpy' }[2], actual.items.find { |r| r[0] == '©cpy' }[2]
      TagLib::MP4::File.open(path, false) do |f|
        f.tag.remove_property('copyright')
        assert_nil f.tag.property('copyright'), 'cprt does not serve as fallback'
        assert f.save
      end
      removed = snapshot(path)
      assert_nil removed.items.find { |r| r[0] == '©cpy' }
      assert_equal original.mdta, removed.mdta
      assert_equal original.items.reject { |r| r[0] == '©cpy' }, removed.items
    end
  end

  def test_invalid_copyright_does_not_change_memory_or_disk
    path = fixture(:mdta)
    original = snapshot(path)
    disk = Digest::SHA256.file(path).hexdigest
    TagLib::MP4::File.open(path, false) do |f|
      [['a', 'b'], nil, "a\0b", "\xff".b].each do |value|
        assert_raise(ArgumentError, Encoding::UndefinedConversionError) { f.tag.set_property('copyright', value) }
        assert original.structure_equal?(f.tag.metadata_snapshot)
      end
    end
    assert_equal disk, Digest::SHA256.file(path).hexdigest
  end

  def test_full_snapshot_restore_preserves_copyright_duplicates_and_types
    source = fixture(:mdta)
    original = snapshot(source)
    destination = File.join(@dir, 'destination.mp4')
    FileUtils.cp(source, destination)
    TagLib::MP4::File.open(destination, false) do |f|
      f.tag.remove_item('©cpy')
      f.tag.restore_metadata_snapshot(original)
      assert f.save
    end
    assert original.logical_equal?(snapshot(destination))
  end
end
