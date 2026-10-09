# frozen-string-literal: true

require File.join(File.dirname(__FILE__), 'helper')
require 'open3'
require 'rbconfig'
require 'set'

class MP4ItemsTest < Test::Unit::TestCase
  ITUNES_LEADER = "\xC2\xA9"

  context "The mp4.m4a file's items" do
    setup do
      @file = TagLib::MP4::File.new('test/data/mp4.m4a')
      @tag = @file.tag
      @item_map = @file.tag.item_map
      @item_keys = [
        'covr', "#{ITUNES_LEADER}nam", "#{ITUNES_LEADER}ART", "#{ITUNES_LEADER}alb",
        "#{ITUNES_LEADER}cmt", "#{ITUNES_LEADER}gen", "#{ITUNES_LEADER}day",
        'trkn', "#{ITUNES_LEADER}too", "#{ITUNES_LEADER}cpy"
      ]
    end

    context 'item_map' do
      should 'exist' do
        assert_not_nil @item_map
      end

      should 'not be empty' do
        assert_equal false, @item_map.empty?
      end

      should 'contain 10 items' do
        assert_equal @item_keys.count, @item_map.size
      end

      should 'have keys' do
        assert_equal true, @item_map.contains('trkn')
        assert_equal true, @item_map.has_key?("#{ITUNES_LEADER}too")
        assert_equal true, @item_map.include?("#{ITUNES_LEADER}cpy")
        assert_equal false, @item_map.include?('none such key')
      end

      should 'look up keys' do
        assert_nil @item_map['none such key']
        assert_equal ['Title'], @item_map["#{ITUNES_LEADER}nam"].to_string_list
      end

      should 'be clearable' do
        assert_equal 10, @item_map.size
        comment = @item_map["#{ITUNES_LEADER}cmt"]
        @item_map.clear
        assert_equal true, @item_map.empty?
        begin
          comment.to_string_list
          flunk('Should have raised ObjectPreviouslyDeleted.')
        rescue StandardError => e
          assert_equal 'ObjectPreviouslyDeleted', e.class.to_s
        end
      end

      should 'be convertible to an array' do
        array = @item_map.to_a
        assert_equal 10, array.count
        array.each do |object|
          assert_equal Array, object.class
          assert_equal 2, object.count
          assert_equal String, object.first.class
          assert_equal TagLib::MP4::Item, object.last.class
          assert_includes @item_keys, object.first
        end
      end

      should 'be convertible to a hash' do
        hsh = @item_map.to_h
        assert_equal Set.new(hsh.keys), Set.new(@item_keys)
      end
    end

    should 'be removable' do
      assert_equal 10, @item_map.size
      title = @item_map["#{ITUNES_LEADER}nam"]
      @item_map.erase("#{ITUNES_LEADER}nam")
      assert_equal 9, @item_map.size
      begin
        title.to_string_list
        flunk('Should have raised ObjectPreviouslyDeleted.')
      rescue StandardError => e
        assert_equal 'ObjectPreviouslyDeleted', e.class.to_s
      end
    end

    should 'reflect edition of items from the tag' do
      assert @tag.contains 'trkn'
      track = @item_map['trkn']

      @tag['trkn'] = TagLib::MP4::Item.from_int(1)

      begin
        track.to_int_pair[0]
        flunk('Should have raised ObjectPreviouslyDeleted.')
      rescue StandardError => e
        assert_equal 'ObjectPreviouslyDeleted', e.class.to_s
      end
    end

    should 'reflect removal of items from the tag' do
      assert @tag.contains 'trkn'
      track = @item_map['trkn']

      @tag.remove_item('trkn')
      refute @item_map.contains 'trkn'

      begin
        track.to_int_pair[0]
        flunk('Should have raised ObjectPreviouslyDeleted.')
      rescue StandardError => e
        assert_equal 'ObjectPreviouslyDeleted', e.class.to_s
      end
    end

    context 'inserting items' do
      should 'insert a new item' do
        new_title = TagLib::MP4::Item.from_string_list(['new title'])
        @item_map.insert("#{ITUNES_LEADER}nam", new_title)
        GC.start
        assert_equal ['new title'], @item_map["#{ITUNES_LEADER}nam"].to_string_list
      end

      should 'unlink items that get replaced' do
        title = @item_map["#{ITUNES_LEADER}nam"]
        @item_map.insert("#{ITUNES_LEADER}nam", TagLib::MP4::Item.from_int(1))
        begin
          title.to_string_list
          flunk('Should have raised ObjectPreviouslyDeleted.')
        rescue StandardError => e
          assert_equal 'ObjectPreviouslyDeleted', e.class.to_s
        end
      end

      should 'survive GC compaction while inserting a temporary item' do
        script = <<~'RUBY'
          require 'taglib_plus'

          100.times do
            file = TagLib::MP4::File.new(ARGV.fetch(0))
            tag = file.tag
            tag.item_map
            GC.start
            GC.compact
            tag.item_map.insert('©cpy', TagLib::MP4::Item.from_string_list(['genre']))
            raise 'unexpected item value' unless tag.item_map['©cpy'].to_string_list == ['genre']
            file.close
          end
        RUBY
        fixture = File.expand_path('data/mp4.m4a', __dir__)
        lib = File.expand_path('../lib', __dir__)
        stdout, stderr, status = Open3.capture3(
          RbConfig.ruby, '--yjit', "-I#{lib}", '-e', script, fixture
        )

        assert_predicate status, :success?, "child process failed: #{stdout}\n#{stderr}"
      end

      should 'unlink borrowed cover art when the file closes' do
        file = TagLib::MP4::File.new('test/data/mp4.m4a')
        art = file.tag.item_map['covr'].to_cover_art_list.first
        assert_not_nil art.data

        file.close
        error = assert_raise_kind_of(StandardError) { art.data }
        assert_equal 'ObjectPreviouslyDeleted', error.class.name
      end

      should 'unlink borrowed cover art when its item is removed' do
        art = @tag.item_map['covr'].to_cover_art_list.first
        assert_not_nil art.data

        @tag.remove_item('covr')
        error = assert_raise_kind_of(StandardError) { art.data }
        assert_equal 'ObjectPreviouslyDeleted', error.class.name
      end

      should 'release borrowed wrappers when the file closes' do
        baseline = eval('$SWIG_TRACKINGS_COUNT')
        file = TagLib::MP4::File.new('test/data/mp4.m4a')
        file.tag.item_map
        assert_operator eval('$SWIG_TRACKINGS_COUNT'), :>, baseline

        file.close
        assert_equal baseline, eval('$SWIG_TRACKINGS_COUNT')
      end

      should 'not track owned Item factory results' do
        baseline = eval('$SWIG_TRACKINGS_COUNT')
        item = TagLib::MP4::Item.from_string_list(['owned'])

        assert_equal baseline, eval('$SWIG_TRACKINGS_COUNT')
        assert_equal ['owned'], item.to_string_list
      end
    end

    context 'TagLib::MP4::Item' do
      should 'be creatable from a boolean' do
        item = TagLib::MP4::Item.from_bool(false)
        assert_equal TagLib::MP4::Item, item.class
        assert_equal false, item.to_bool
      end

      should 'be creatable from a byte' do
        item = TagLib::MP4::Item.from_byte(123)
        assert_equal TagLib::MP4::Item, item.class
        assert_equal 123, item.to_byte
      end

      should 'be creatable from an unsigned int' do
        item = TagLib::MP4::Item.from_int(12_346)
        assert_equal TagLib::MP4::Item, item.class
        assert_equal 12_346, item.to_uint
      end

      should 'be creatable from an int' do
        item = TagLib::MP4::Item.from_int(-42)
        assert_equal TagLib::MP4::Item, item.class
        assert_equal(-42, item.to_int)
      end

      should 'be creatable from a long long' do
        item = TagLib::MP4::Item.from_long_long(1_234_567_890)
        assert_equal TagLib::MP4::Item, item.class
        assert_equal 1_234_567_890, item.to_long_long
      end

      context '.from_int_pair' do
        should 'be creatable from a pair of ints' do
          item = TagLib::MP4::Item.from_int_pair([123, 456])
          assert_equal TagLib::MP4::Item, item.class
          assert_equal [123, 456], item.to_int_pair
        end

        should 'raise an error when passed something other than an Array' do
          begin
            TagLib::MP4::Item.from_int_pair(1)
            flunk('Should have raised ArgumentError.')
          rescue StandardError => e
            assert_equal 'ArgumentError', e.class.to_s
          end
        end

        should 'raise an error when passed an Array with more than two elements' do
          begin
            TagLib::MP4::Item.from_int_pair([1, 2, 3])
            flunk('Should have raised ArgumentError.')
          rescue StandardError => e
            assert_equal 'ArgumentError', e.class.to_s
          end
        end

        should 'raise an error when passed an Array with less than two elements' do
          begin
            TagLib::MP4::Item.from_int_pair([1])
            flunk('Should have raised ArgumentError.')
          rescue StandardError => e
            assert_equal 'ArgumentError', e.class.to_s
          end
        end
      end

      context 'created from an array of strings' do
        should 'interpreted as strings with an encoding' do
          item = TagLib::MP4::Item.from_string_list(['héllo'])
          assert_equal TagLib::MP4::Item, item.class
          assert_equal ['héllo'], item.to_string_list
        end
      end

      should 'be creatable from a CoverArt list' do
        cover_art = TagLib::MP4::CoverArt.new(TagLib::MP4::CoverArt::JPEG, 'foo')
        item = TagLib::MP4::Item.from_cover_art_list([cover_art])
        assert_equal TagLib::MP4::Item, item.class
        new_cover_art = item.to_cover_art_list.first
        assert_equal 'foo', new_cover_art.data
        assert_equal TagLib::MP4::CoverArt::JPEG, new_cover_art.format
      end
    end

    context 'TagLib::MP4::CoverArt' do
      should 'be creatable from a string' do
        cover_art = TagLib::MP4::CoverArt.new(TagLib::MP4::CoverArt::JPEG, 'foo')
        assert_equal TagLib::MP4::CoverArt::JPEG, cover_art.format
        assert_equal 'foo', cover_art.data
      end
    end

    teardown do
      @file.close
      @file = nil
    end
  end
end
