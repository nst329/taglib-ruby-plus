# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_snapshot_extensions_probe'

# 合成MP4だけを使い、追加APIの契約を保存・独立再読込まで検証する。
class MP4SnapshotExtensionsTest < Test::Unit::TestCase
  P = MP4SnapshotExtensionsProbe
  S = TagLib::MP4::MetadataSnapshot

  def setup
    @dir = Dir.mktmpdir('snapshot-extensions-')
    @path = File.join(@dir, 'fixture.mp4')
    _, err, status = Open3.capture3(ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg'),
      '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=0.1', '-c:a', 'aac',
      '-movflags', 'use_metadata_tags', '-metadata', 'title=original', @path)
    assert status.success?, err
    TagLib::MP4::File.open(@path, false) do |f|
      assert f.tag.metadata_capabilities[:snapshot_v1], 'snapshot native support required; do not omit'
      f.tag.replace_mdta_items('gain', typed_values.map { |t, l, b| { data_type: t, locale: l, data: b } })
      f.tag.item_map.insert('cprt', TagLib::MP4::Item.from_string_list(['first', 'second', 'first']))
      image = File.binread(File.join(__dir__, 'data/globe_east_90.jpg'))
      f.tag.item_map.insert('covr', TagLib::MP4::Item.from_cover_art_list([TagLib::MP4::CoverArt.new(13, image)] * 2))
      assert f.save
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def typed_values
    [[1, 1041, 'a'.b], [33, 7, "\0\xff".b], [1, 1041, 'a'.b]]
  end

  def snapshot
    TagLib::MP4::File.open(@path, false) { |f| f.tag.metadata_snapshot }
  end

  def test_public_edit_preserves_typed_values_and_removes_excluded_values
    original = snapshot
    expected = original.without(items: ['cprt'], mdta: ['gain']).with(mdta: { 'new' => typed_values })
    TagLib::MP4::File.open(@path, false) { |f| f.tag.restore_metadata_snapshot(expected); assert f.save }
    actual = snapshot
    assert expected.logical_equal?(actual)
    assert_empty expected.diff(actual)
    assert_nil actual.items.find { |r| r[0] == 'cprt' }
    assert_equal [], actual.mdta.find { |r| r[0] == 'gain' }[2]
    assert_equal original.items.find { |r| r[0] == 'covr' }, actual.items.find { |r| r[0] == 'covr' }
    assert_equal typed_values, original.mdta.find { |r| r[0] == 'gain' }[2]
  end

  def test_all_property_effects_match_the_real_set_and_remove_operations
    TagLib::MP4::File.open(@path, false) do |f|
      TagLib::MP4::Tag::PROPERTY_ATOMS.each_key do |name|
        key = TagLib::MP4::Tag::MDTA_PROPERTY_KEYS[name]
        f.tag.replace_mdta_items(key, [{ data_type: 1, locale: 0, data: 'old' }]) if key
        before = f.tag.metadata_snapshot
        value = name == 'contentRating' ? TagLib::MP4::ContentRating.new(system: :mpaa, rating: 'R', id: 400) : 'new'
        effects = f.tag.property_update_effects(name)
        f.tag.set_property(name, value)
        changes = before.diff(f.tag.metadata_snapshot)
        assert_equal effects[:items][:set], changes.select { |r| r[:area] == :items }.map { |r| r[:key] }
        assert_equal effects[:mdta][:remove], changes.select { |r| r[:area] == :mdta }.map { |r| r[:key] }
        f.tag.replace_mdta_items(key, [{ data_type: 1, locale: 0, data: 'remove' }]) if key
        before = f.tag.metadata_snapshot
        effects = f.tag.property_update_effects(name, operation: :remove)
        f.tag.remove_property(name)
        changes = before.diff(f.tag.metadata_snapshot)
        assert_equal effects[:items][:remove], changes.select { |r| r[:area] == :items }.map { |r| r[:key] }
        assert_equal effects[:mdta][:remove], changes.select { |r| r[:area] == :mdta }.map { |r| r[:key] }
      end
      assert_equal f.tag.property_update_effects('TVShowName'), f.tag.property_update_effects('show')
      f.tag.replace_mdta_items('title', [{ data_type: 1, locale: 0, data: 'keep' }])
      f.tag.title = 'native'
      before = f.tag.metadata_snapshot
      f.tag.title = ''
      assert_equal ['©nam'], before.diff(f.tag.metadata_snapshot).map { |r| r[:key] }
      assert_equal 'keep', f.tag.title
      effects = f.tag.property_update_effects('title', via: :native_setter)
      assert_equal({ items: { set: ['©nam'], remove: ['©nam'] }, mdta: { remove: [] } }, effects)
      assert_raise(FrozenError) { effects[:items][:set] << 'x' }
      assert_raise(ArgumentError) { f.tag.property_update_effects('unknown') }
      assert_raise(ArgumentError) { f.tag.property_update_effects('artist', via: :native_setter) }
      assert_raise(ArgumentError) { f.tag.property_update_effects('title', via: :native_setter, operation: :remove) }
      assert_raise(ArgumentError) { f.tag.property_update_effects('title', operation: :unknown) }
      assert f.save
    end
  end

  def test_title_setter_keeps_native_conversion_and_empty_value_semantics
    TagLib::MP4::File.open(@path, false) do |f|
      initial = f.tag.metadata_snapshot
      base_setter = TagLib::Tag.instance_method(:title=)
      convertible = Object.new
      convertible.define_singleton_method(:to_str) { 'convertible' }
      [nil, '', 'native', '著作権'.encode(Encoding::Shift_JIS), "a\0b", convertible].each do |value|
        f.tag.restore_metadata_snapshot(initial)
        base_setter.bind_call(f.tag, value)
        expected = f.tag.metadata_snapshot
        f.tag.restore_metadata_snapshot(initial)
        f.tag.title = value
        assert expected.structure_equal?(f.tag.metadata_snapshot), value.inspect
      end
      before = f.tag.metadata_snapshot
      assert_raise(TypeError) { f.tag.title = 42 }
      assert before.structure_equal?(f.tag.metadata_snapshot)
    end
  end

  def test_unauthorized_change_is_rejected_before_original_replacement
    original = snapshot
    expected = original.with(items: [['©nam', :string_list, 255, ['allowed']]])
    disk = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |f|
      f.extend(P::ExpectedSave)
      f.probe_expected_snapshot = expected
      f.tag.restore_metadata_snapshot(expected)
      f.tag.set_property('comment', 'unauthorized')
      error = assert_raise(TagLib::MP4::MdtaSaveError) { f.save }
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_equal disk, Digest::SHA256.file(@path).hexdigest
      f.tag.restore_metadata_snapshot(expected)
      assert f.save
    end
    assert expected.logical_equal?(snapshot)
  end
end
