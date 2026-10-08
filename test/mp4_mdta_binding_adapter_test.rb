# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib/base'
require 'taglib/mp4'

class MP4MdtaBindingAdapterTest < Test::Unit::TestCase
  # Every binding mode uses a generated MP4; no original video is opened for writing.
  def setup
    @dir = Dir.mktmpdir('mdta-binding-adapter-')
    @path = File.join(@dir, 'generated.mp4')
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, 'generate_mp4_mdta_fixture.rb'), @path)
    assert status.success?, "#{out}\n#{err}"
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def values
    [{ data_type: 1, locale: 0, data: 'first'.b },
     { data_type: 1, locale: 1041, data: 'second'.b },
     { data_type: 1, locale: 0, data: 'first'.b },
     { data_type: 33, locale: 7, data: "\0\xff\0".b },
     { data_type: 0xffff_ffff, locale: 0xffff_ffff, data: ''.b }]
  end

  def snapshot(tag)
    tag.mdta_items.map { |v| [v.key, v.key_index, v.data_type, v.locale, v.data] }
  end

  def test_layout_selection_and_flat_snapshot_ownership
    TagLib::MP4::File.open(@path, false) do |file|
      actual = file.tag.mdta_status
      assert_include [:editable, :unknown], actual
      expected = ENV['MDTA_BINDING_LAYOUT']
      assert_equal(expected == 'grouped' ? :editable : :unknown, actual) if expected
      file.tag.replace_mdta_items('new.binding', values)
      before = snapshot(file.tag)
      returned = file.tag.mdta_items
      assert_raise(FrozenError) { returned.last.data.clear }
      returned.clear
      assert_equal before, snapshot(file.tag)
      assert file.save
      assert_equal before, snapshot(file.tag)
      assert_equal values.map { |v| [v[:data_type], v[:locale], v[:data]] },
                   file.tag.mdta_items.select { |v| v.key == 'new.binding' }.map { |v| [v.data_type, v.locale, v.data] }
    end
  end

  def test_single_setter_removal_and_explicit_empty_itunes_title_keep_legacy_contract
    TagLib::MP4::File.open(@path, false) do |file|
      assert_equal 'MDTA Title', file.tag.title
      file.tag.title = ''
      assert_equal 'MDTA Title', file.tag.title
      file.tag.item_map.insert('©nam', TagLib::MP4::Item.from_string_list(['']))
      assert_equal '', file.tag.title
      file.tag.replace_mdta_items('audio_normalization', values)
      file.tag.set_mdta_item('audio_normalization', 'last')
      assert_equal ['last'], file.tag.mdta_items.select { |v| v.key == 'audio_normalization' }.map(&:data)
      assert_same file.tag, file.tag.remove_mdta_item('not-present')
      assert_same file.tag, file.tag.remove_mdta_item('artist')
      expected = snapshot(file.tag)
      assert file.save
      assert_equal '', file.tag.title
      assert_equal expected, snapshot(file.tag)
    end
  end

  def test_ambiguous_new_item_is_rejected_in_grouped_mode_before_original_changes
    original = File.binread(@path)
    TagLib::MP4::File.open(@path, false) do |file|
      grouped = file.tag.mdta_status == :editable
      file.tag.item_map.insert('zzzz', TagLib::MP4::Item.from_string_list(['ambiguous']))
      if grouped
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal false, error.committed
        assert_equal original, File.binread(@path)
        assert_equal ['ambiguous'], file.tag.item_map['zzzz'].to_string_list
        file.tag.item_map.erase('zzzz')
      end
      assert file.save
    end
  end

  def test_unsupported_source_refuses_save_without_losing_original
    bytes = File.binread(@path).sub('mdtatitle', 'xxxxtitle')
    File.binwrite(@path, bytes)
    TagLib::MP4::File.open(@path, false) do |file|
      if ENV['MDTA_BINDING_LAYOUT'] == 'grouped'
        assert_equal :unsupported, file.tag.mdta_status
        assert_empty file.tag.mdta_items
      end
      file.tag.title = 'must not overwrite unsupported metadata'
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
      assert_equal false, error.committed
      assert_equal bytes, File.binread(@path)
      assert_empty Dir.glob("#{@path}.taglib-mdta-*")
    end
  end
end
