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

  def test_set_properties_normalizes_selected_mdta_keys_and_preserves_typed_unknown_data
    open_file do |file|
      file.tag.set_mdta_item('com.example.taglib.typed', "\x00\xFF".b, data_type: 33, locale: 7)
      file.tag.set_properties(
        'title' => 'Normalized title',
        'show' => 'Normalized show',
        'artist' => 'Normalized artist',
        'description' => 'Normalized description'
      )

      assert_equal 'Normalized title', file.tag.item_map['©nam'].to_string_list.first
      assert_equal 'Normalized show', file.tag.item_map['tvsh'].to_string_list.first
      assert_nil file.tag.mdta_item('title')
      assert_nil file.tag.mdta_item('show')
      assert_nil file.tag.mdta_item('artist')
      assert_nil file.tag.mdta_item('description')
      assert_equal 'loudnorm', file.tag.mdta_item('audio_normalization').text
      assert_equal '-16-LUFS', file.tag.mdta_item('audio_normalization_target').text
      assert file.save
    end

    open_file do |file|
      assert_equal 'Normalized title', file.tag.title
      assert_equal 'Normalized show', file.tag.property('show')
      assert_equal 'Normalized artist', file.tag.artist
      assert_equal 'Normalized description', file.tag.property('description')
      assert_nil file.tag.mdta_item('title')
      assert_nil file.tag.mdta_item('show')
      assert_nil file.tag.mdta_item('artist')
      assert_nil file.tag.mdta_item('description')
      assert_equal 'loudnorm', file.tag.mdta_item('audio_normalization').text
      assert_equal '-16-LUFS', file.tag.mdta_item('audio_normalization_target').text
      unknown = file.tag.mdta_item('com.example.taglib.typed')
      assert_equal 33, unknown.data_type
      assert_equal 7, unknown.locale
      assert_equal "\x00\xFF".b, unknown.data
      assert_nil unknown.text
    end
  end

  def test_set_properties_only_normalizes_the_properties_it_updates
    open_file do |file|
      file.tag.set_properties('artist' => 'Normalized artist')
      assert_nil file.tag.mdta_item('artist')
      assert_equal 'MDTA Title', file.tag.mdta_item('title').text
      assert_equal 'MDTA Show', file.tag.mdta_item('show').text
      assert_equal 'MDTA Description', file.tag.mdta_item('description').text
      assert file.save
    end

    open_file do |file|
      assert_equal 'Normalized artist', file.tag.artist
      assert_nil file.tag.mdta_item('artist')
      assert_equal 'MDTA Title', file.tag.mdta_item('title').text
      assert_equal 'MDTA Show', file.tag.mdta_item('show').text
      assert_equal 'MDTA Description', file.tag.mdta_item('description').text
    end
  end

  def test_remove_property_removes_ilst_and_its_mdta_fallback
    open_file do |file|
      file.tag.remove_property('title')
      assert_nil file.tag.property('title')
      assert_nil file.tag.mdta_item('title')
      assert_equal 'MDTA Artist', file.tag.artist
      assert file.save
    end

    open_file do |file|
      assert_nil file.tag.property('title')
      assert_nil file.tag.mdta_item('title')
      assert_equal 'MDTA Artist', file.tag.artist
    end
  end

  def test_show_alias_collision_is_rejected_before_mutation
    open_file do |file|
      assert_raise(ArgumentError) do
        file.tag.set_properties('show' => 'First', 'TVShowName' => 'Second')
      end
      assert_equal 'MDTA Show', file.tag.property('show')
      assert_nil file.tag.item_map['tvsh']
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

  def test_mdta_update_preserves_artwork_and_chapters
    artwork = TagLib::MP4::Artwork.new(
      format: :jpeg,
      data: File.binread(File.expand_path('data/globe_east_90.jpg', __dir__))
    )

    open_file do |file|
      file.tag.set_artwork(artwork)
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      file.tag.set_mdta_item('audio_normalization', 'ebu-r128')
      assert file.save
    end

    open_file do |file|
      assert_equal [artwork], file.tag.artwork
      assert_equal ['Opening'], file.chapters.map(&:title)
      assert_equal 'ebu-r128', file.tag.mdta_item('audio_normalization').text
      assert_equal '-16-LUFS', file.tag.mdta_item('audio_normalization_target').text
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

  def test_mdta_api_adds_and_removes_new_key
    open_file do |file|
      file.tag.set_mdta_item('com.example.taglib.new-key', 'value')
      assert_equal 'value', file.tag.mdta_item('com.example.taglib.new-key').text
      assert file.save
    end

    open_file do |file|
      item = file.tag.mdta_item('com.example.taglib.new-key')
      assert_not_nil item
      assert_equal 'value', item.text
      file.tag.remove_mdta_item('com.example.taglib.new-key')
      assert_nil file.tag.mdta_item('com.example.taglib.new-key')
      assert file.save
    end

    open_file do |file|
      assert_nil file.tag.mdta_item('com.example.taglib.new-key')
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

  def test_chapter_changes_are_not_written_to_the_open_file_before_save
    original = File.binread(@fixture)
    open_file do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      assert_equal ['Opening'], file.chapters.map(&:title)
      assert_equal original, File.binread(@fixture)
    end
    assert_equal original, File.binread(@fixture)
  end

  def test_invalid_chapter_change_does_not_replace_pending_change
    open_file do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      invalid = [
        TagLib::MP4::Chapter.new(start_time: 0, title: 'First'),
        TagLib::MP4::Chapter.new(start_time: 0, title: 'Duplicate')
      ]
      assert_raise(ArgumentError) { file.set_chapters(invalid) }
      assert_equal ['Opening'], file.chapters.map(&:title)
    end
  end

  def test_normal_save_commits_metadata_and_chapters_together
    open_file do |file|
      file.tag.set_properties('title' => 'Combined save')
      file.tag.set_mdta_item('audio_normalization', 'ebu-r128')
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      assert file.save
    end

    open_file do |file|
      assert_equal 'Combined save', file.tag.title
      assert_equal 'ebu-r128', file.tag.mdta_item('audio_normalization').text
      assert_equal ['Opening'], file.chapters.map(&:title)
      assert_equal :both, file.chapter_style
    end
  end

  def test_mdta_save_preserves_existing_chapters
    open_file do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      assert file.save_chapters
      file.tag.set_mdta_item('audio_normalization', 'ebu-r128')
      assert file.save
    end

    open_file do |file|
      assert_equal ['Opening'], file.chapters.map(&:title)
      assert_equal 'ebu-r128', file.tag.mdta_item('audio_normalization').text
    end
  end

  def test_repeated_saves_refresh_the_metadata_baseline_for_chapter_save
    open_file do |file|
      file.tag.title = 'First save'
      assert file.save
      file.tag.set_mdta_item('audio_normalization', 'ebu-r128')
      assert file.save
      file.set_chapters([TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening')])
      assert file.save_chapters
    end

    open_file do |file|
      assert_equal 'First save', file.tag.title
      assert_equal 'ebu-r128', file.tag.mdta_item('audio_normalization').text
      assert_equal ['Opening'], file.chapters.map(&:title)
    end
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
