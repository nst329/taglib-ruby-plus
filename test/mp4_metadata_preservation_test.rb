# frozen-string-literal: true

require File.join(File.dirname(__FILE__), 'helper')
require 'fileutils'
require 'tmpdir'

class MP4MetadataPreservationTest < Test::Unit::TestCase
  SAMPLE_FILE = File.expand_path('data/mp4.m4a', __dir__)
  PICTURE_FILE = File.expand_path('data/globe_east_90.jpg', __dir__)
  CONTENT_RATING_KEY = '----:com.apple.iTunes:iTunEXTC'

  def with_copy
    Dir.mktmpdir('taglib-mp4-metadata') do |directory|
      path = File.join(directory, 'sample.m4a')
      FileUtils.cp(SAMPLE_FILE, path)
      yield path
    end
  end

  def string_item(value)
    TagLib::MP4::Item.from_string_list([value])
  end

  def test_itunes_style_properties_can_be_written_through_item_map
    with_copy do |path|
      file = TagLib::MP4::Internal::File.new(path, false)
      item_map = file.tag.item_map

      {
        'desc' => 'Description',
        'ldes' => 'Long description',
        "©grp" => 'Grouping',
        'tvsh' => 'Show',
        'tven' => 'Episode 1',
        'keyw' => 'Keyword',
        'purl' => 'https://example.test/feed',
        'purd' => '2026-08-28T00:00:00Z',
        CONTENT_RATING_KEY => 'mpaa|R|400|'
      }.each do |key, value|
        item_map.insert(key, string_item(value))
      end

      artwork = TagLib::MP4::CoverArt.new(
        TagLib::MP4::CoverArt::JPEG,
        File.binread(PICTURE_FILE)
      )
      item_map.insert('covr', TagLib::MP4::Item.from_cover_art_list([artwork, artwork]))

      assert file.save
      file.close

      file = TagLib::MP4::Internal::File.new(path, false)
      item_map = file.tag.item_map
      assert_equal 'Description', item_map['desc'].to_string_list.first
      assert_equal 'Long description', item_map['ldes'].to_string_list.first
      assert_equal 'Grouping', item_map["©grp"].to_string_list.first
      assert_equal 'Show', item_map['tvsh'].to_string_list.first
      assert_equal 'Episode 1', item_map['tven'].to_string_list.first
      assert_equal 'Keyword', item_map['keyw'].to_string_list.first
      assert_equal 'https://example.test/feed', item_map['purl'].to_string_list.first
      assert_equal '2026-08-28T00:00:00Z', item_map['purd'].to_string_list.first
      assert_equal ['mpaa|R|400|'], item_map[CONTENT_RATING_KEY].to_string_list
      assert_equal 2, item_map['covr'].to_cover_art_list.size
      file.close
    end
  end

  def test_normal_save_preserves_unknown_item_artwork_and_chapters
    with_copy do |path|
      file = TagLib::MP4::Internal::File.new(path, false)
      item_map = file.tag.item_map
      item_map.insert('zzzz', string_item('unknown-value'))

      chapters = [
        TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening'),
        TagLib::MP4::Chapter.new(start_time: 500, title: 'Main')
      ]
      file.set_chapters(chapters)
      file.tag.title = 'Changed'
      assert file.save
      file.close

      file = TagLib::MP4::Internal::File.new(path, false)
      assert_equal 'Changed', file.tag.title
      assert_equal ['unknown-value'], file.tag.item_map['zzzz'].to_string_list
      assert_equal :both, file.chapter_style
      assert_equal chapters, file.chapters
      assert_equal 1, file.tag.item_map['covr'].to_cover_art_list.size
      file.close
    end
  end

  def test_all_artwork_can_be_removed
    with_copy do |path|
      file = TagLib::MP4::Internal::File.new(path, false)
      file.tag.remove_item('covr')
      assert file.save
      file.close

      file = TagLib::MP4::Internal::File.new(path, false)
      assert_nil file.tag.item_map['covr']
      file.close
    end
  end
end
