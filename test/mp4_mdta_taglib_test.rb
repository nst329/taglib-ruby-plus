# frozen-string-literal: true

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'test/unit'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
$LOAD_PATH.unshift(File.expand_path('../ext/taglib_base', __dir__))
$LOAD_PATH.unshift(File.expand_path('../ext/taglib_mp4', __dir__))
require 'taglib/base'
require 'taglib/mp4'

class MP4MdtaTagLibTest < Test::Unit::TestCase
  def setup
    @directory = Dir.mktmpdir('taglib-mdta-ruby')
    @fixture = File.join(@directory, 'fixture.mp4')
    ffmpeg = ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg')
    script = File.expand_path('generate_mp4_mdta_fixture.rb', __dir__)
    stdout, stderr, status = Open3.capture3({ 'FFMPEG' => ffmpeg }, RbConfig.ruby, script, @fixture)
    assert_predicate status, :success?, "fixture generation failed: #{stdout}\n#{stderr}"
  end

  def teardown
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def open_file
    file = TagLib::MP4::File.new(@fixture, false)
    yield file
  ensure
    file.close if file
  end

  def test_reads_ffmpeg_mdta_without_mixing_it_into_item_map
    open_file do |file|
      assert_equal 'MDTA Title', file.tag.title
      assert_equal 'MDTA Artist', file.tag.artist
      assert_equal 'MDTA Title', file.tag.property('title')
      assert_equal 'MDTA Show', file.tag.property('show')
      assert_equal 'MDTA Description', file.tag.property('description')
      assert_nil file.tag.item_map['title']

      values = file.tag.mdta_items.to_h { |item| [item.key, item] }
      assert_equal 'loudnorm', values.fetch('audio_normalization').text
      assert_equal '-16-LUFS', values.fetch('audio_normalization_target').text
      assert_equal 1, values.fetch('audio_normalization').data_type
      assert_equal 0, values.fetch('audio_normalization').locale
    end
  end

  def test_normal_title_save_preserves_all_mdta_values
    open_file do |file|
      file.tag.title = 'Changed from Ruby'
      assert file.save
    end

    open_file do |file|
      assert_equal 'Changed from Ruby', file.tag.title
      assert_equal 'MDTA Show', file.tag.property('show')
      assert_equal 'MDTA Artist', file.tag.artist
      assert_equal 'loudnorm', file.tag.mdta_item('audio_normalization').text
      assert_equal '-16-LUFS', file.tag.mdta_item('audio_normalization_target').text
    end
  end

  def test_mdta_update_preserves_normal_ilst_item
    open_file do |file|
      file.tag.item_map.insert('©nam', TagLib::MP4::Item.from_string_list(['Normal title']))
      file.tag.item_map.insert('zzzz', TagLib::MP4::Item.from_string_list(['Opaque normal value']))
      file.tag.set_mdta_item('audio_normalization', 'ebu-r128')
      file.tag.set_mdta_item('audio_normalization_target', '-14-LUFS')
      assert file.save
    end

    open_file do |file|
      assert_equal 'Normal title', file.tag.title
      assert_equal ['Opaque normal value'], file.tag.item_map['zzzz'].to_string_list
      assert_equal 'ebu-r128', file.tag.mdta_item('audio_normalization').text
      assert_equal '-14-LUFS', file.tag.mdta_item('audio_normalization_target').text
    end
  end

  def test_mdta_data_does_not_stringify_unknown_type
    open_file do |file|
      file.tag.set_mdta_item('audio_normalization', "\x00\xFF".b, data_type: 33, locale: 7)
      assert_nil file.tag.mdta_item('audio_normalization').text
      assert_equal Encoding::BINARY, file.tag.mdta_item('audio_normalization').data.encoding
      assert file.save
    end

    open_file do |file|
      item = file.tag.mdta_item('audio_normalization')
      assert_equal 33, item.data_type
      assert_equal 7, item.locale
      assert_equal "\x00\xFF".b, item.data
      assert_nil item.text
    end
  end

  def test_mdta_api_rejects_unknown_key_without_mutating
    open_file do |file|
      assert_raise(TagLib::MP4::MdtaItemError) do
        file.tag.set_mdta_item('new-key', 'value')
      end
      assert_equal 'loudnorm', file.tag.mdta_item('audio_normalization').text
    end
  end

  def test_save_chapters_rejects_unsaved_mdta_changes
    original = File.binread(@fixture)
    open_file do |file|
      file.tag.set_mdta_item('audio_normalization', 'changed')
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      assert_raise(TagLib::MP4::ChapterSaveError) { file.save_chapters }
    end
    assert_equal original, File.binread(@fixture)
  end

  def test_chapter_only_save_preserves_mdta
    open_file do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      assert file.save_chapters
    end

    open_file do |file|
      assert_equal :both, file.chapter_style
      assert_equal 'loudnorm', file.tag.mdta_item('audio_normalization').text
      assert_equal '-16-LUFS', file.tag.mdta_item('audio_normalization_target').text
    end
  end
end
