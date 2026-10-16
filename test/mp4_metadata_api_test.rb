# frozen-string-literal: true

require File.join(File.dirname(__FILE__), 'helper')
require 'fileutils'
require 'tmpdir'

class MP4MetadataAPITest < Test::Unit::TestCase
  SAMPLE_FILE = File.expand_path('data/mp4.m4a', __dir__)
  JPEG_FILE = File.expand_path('data/globe_east_90.jpg', __dir__)
  LARGE_JPEG_FILE = File.expand_path('data/globe_east_540.jpg', __dir__)
  PNG_DATA = "\x89PNG\r\n\x1A\napi-test".b
  BMP_DATA = 'BMapi-test'.b

  def with_copy
    Dir.mktmpdir('taglib-mp4-api') do |directory|
      path = File.join(directory, 'sample.m4a')
      FileUtils.cp(SAMPLE_FILE, path)
      yield path
    end
  end

  def open_file(path)
    file = TagLib::MP4::Internal::File.new(path, false)
    yield file
  ensure
    file.close if file
  end

  def test_itunes_properties_can_be_read_written_and_removed
    with_copy do |path|
      rating = TagLib::MP4::ContentRating.new(system: :mpaa, rating: 'R', id: 400)
      expected = {
        'title' => 'New title',
        'artist' => 'New artist',
        'album' => 'New album',
        'genre' => 'New genre',
        'comment' => 'New comment',
        'description' => 'Description',
        'longdesc' => 'Long description',
        'grouping' => 'Grouping',
        'TVShowName' => 'Show',
        'TVEpisode' => '01',
        'keyword' => 'Keyword',
        'podcastURL' => 'https://example.test/feed',
        'year' => '2026',
        'purchaseDate' => '2026-08-28T00:00:00Z',
        'contentRating' => rating
      }
      open_file(path) do |file|
        tag = file.tag
        assert_equal 'Title', tag.property('title')

        tag.set_properties(expected)
        tag.remove_property('description')
        assert file.save
      end

      open_file(path) do |file|
        tag = file.tag
        assert_equal 'New title', tag.property('title')
        assert_nil tag.property('description')
        expected.each do |name, value|
          next if name == 'description'

          assert_equal value, tag.property(name)
        end
      end
    end
  end

  def test_set_properties_validates_before_mutating
    with_copy do |path|
      open_file(path) do |file|
        tag = file.tag
        assert_raise(ArgumentError) do
          tag.set_properties('title' => 'Would not be written', 'unknown' => 'value')
        end
        assert_equal 'Title', tag.property('title')
      end
    end
  end

  def test_property_values_exposes_multiple_values
    with_copy do |path|
      open_file(path) do |file|
        file.tag.item_map.insert('desc', TagLib::MP4::Item.from_string_list(%w[first second]))
        assert_equal 'first', file.tag.property('description')
        assert_equal %w[first second], file.tag.property_values('description')
      end
    end
  end

  def test_string_properties_transcode_to_utf8_and_round_trip
    inputs = {
      'title' => 'ASCII title'.encode(Encoding::US_ASCII).freeze,
      'grouping' => 'シリーズ'.encode(Encoding::Shift_JIS).freeze,
      'description' => '説明'.encode(Encoding::UTF_16LE).freeze,
      'comment' => 'Binary ASCII'.b.freeze
    }
    originals = inputs.transform_values { |value| [value.bytes, value.encoding] }
    with_copy do |path|
      open_file(path) do |file|
        file.tag.set_properties(inputs)
        file.tag.set_property('artist', '歌手'.encode(Encoding::EUC_JP))
        assert_equal originals, inputs.transform_values { |value| [value.bytes, value.encoding] }
        assert file.save
      end
      open_file(path) do |file|
        inputs.each do |name, value|
          actual = file.tag.property(name)
          assert_equal value.encode(Encoding::UTF_8), actual
          assert_equal Encoding::UTF_8, actual.encoding
        end
        assert_equal '歌手', file.tag.property('artist')
      end
    end
  end

  def test_invalid_string_properties_do_not_mutate_items
    cases = [
      ["\xFF".b, Encoding::UndefinedConversionError],
      ["\x82".dup.force_encoding(Encoding::Shift_JIS), Encoding::InvalidByteSequenceError],
      ["\xFF".dup.force_encoding(Encoding::UTF_8), ArgumentError],
      ["a\0b".encode(Encoding::UTF_16LE), ArgumentError],
      [%w[series], ArgumentError]
    ]
    with_copy do |path|
      open_file(path) do |file|
        original = file.tag.properties
        cases.each do |value, error|
          assert_raise(error) do
            file.tag.set_properties('title' => 'Changed', 'grouping' => value)
          end
          assert_equal original, file.tag.properties
        end
      end
    end
  end

  def test_artwork_is_ruby_owned_and_round_trips_in_order
    first_data = File.binread(JPEG_FILE)
    second_data = File.binread(LARGE_JPEG_FILE)

    with_copy do |path|
      open_file(path) do |file|
        images = [
          TagLib::MP4::Artwork.new(format: :jpeg, data: first_data),
          TagLib::MP4::Artwork.new(format: :jpeg, data: second_data)
        ]
        assert images.first.data.frozen?
        file.tag.set_artwork(images)
        first_data << 'changed outside the Artwork object'
        assert file.save
      end

      open_file(path) do |file|
        images = file.tag.artwork
        assert_equal 2, images.length
        assert_equal :jpeg, images[0].format
        assert_equal 'image/jpeg', images[0].mime_type
        assert_equal File.binread(JPEG_FILE), images[0].data
        assert_equal second_data, images[1].data
      end
    end
  end

  def test_artwork_can_be_removed_and_unsupported_formats_are_rejected
    with_copy do |path|
      open_file(path) do |file|
        assert_raise(TagLib::MP4::UnsupportedArtworkError) do
          TagLib::MP4::Artwork.new(format: :gif, data: "GIF89a".b)
        end
        file.tag.remove_artwork
        assert file.save
      end

      open_file(path) do |file|
        assert_empty file.tag.artwork
      end
    end
  end

  def test_png_and_bmp_artwork_round_trip
    with_copy do |path|
      open_file(path) do |file|
        file.tag.set_artwork([
          TagLib::MP4::Artwork.new(format: :png, data: PNG_DATA),
          TagLib::MP4::Artwork.new(format: :bmp, data: BMP_DATA)
        ])
        assert file.save
      end

      open_file(path) do |file|
        images = file.tag.artwork
        assert_equal [[:png, PNG_DATA], [:bmp, BMP_DATA]], images.map { |image| [image.format, image.data] }
      end
    end
  end

  def test_artwork_copy_survives_file_close_and_gc
    with_copy do |path|
      images = open_file(path) { |file| file.tag.artwork }
      GC.start
      assert_equal :jpeg, images.first.format
      assert_equal File.binread(JPEG_FILE), images.first.data
    end
  end

  def test_content_rating_rejects_wire_delimiters
    assert_raise(ArgumentError) do
      TagLib::MP4::ContentRating.new(system: 'mpaa|invalid', rating: 'R', id: 400)
    end
    assert_raise(ArgumentError) do
      TagLib::MP4::ContentRating.new(system: :mpaa, rating: 'R|invalid', id: 400)
    end
  end
end
