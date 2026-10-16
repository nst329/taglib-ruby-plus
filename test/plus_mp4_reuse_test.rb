# frozen_string_literal: true

require_relative 'helper'
require_relative 'support/mp4_investigation_fixture'
require 'tmpdir'

# 追加の利用側コピー・再読込・artwork複製を不要にする公開契約を検証する。
class PlusMP4ReuseTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  setup do
    @dir = Dir.mktmpdir('plus-reuse-')
    @source = File.join(@dir, 'source.mp4')
    FileUtils.cp('test/data/mp4.m4a', @source)
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  should 'fully replace destination values without reading the old native snapshot or artworks' do
    expected = API::MetadataSnapshot.new(items: [API::MetadataItem.new(key: '©nam', kind: :string_list,
      atom_data_type: 255, value: ['完全置換'])])
    API.open(@source) do |file|
      file.define_singleton_method(:read_native) { |*_| raise 'old native values must not be loaded' }
      file.metadata = expected
      assert_same expected, file.metadata
      assert_equal true, file.changes[:changed]
      result = file.save!
      actual = result.fetch(:snapshots).fetch(:metadata)
      assert_equal expected, actual
      assert_not_same expected, actual
      assert_same actual, file.metadata
    end
  end

  should 'skip replaced artwork payload during structure validation and atom planning' do
    edit_fixture(@source) do |moov|
      ilst = fixture_child(fixture_child(fixture_child(moov, 'udta'), 'meta'), 'ilst')
      fixture_child(ilst, 'covr')[:data] = atom_box('data', [13, 0].pack('N2') +
        "\xFF\xD8\xFF".b + 'x'.b * (8 * 1024 * 1024))
    end
    API.open(@source) do |file|
      reader = file.send(:header_reader)
      read = reader.method(:read_mp4_bytes)
      reader.define_singleton_method(:read_mp4_bytes) do |io, offset, length|
        raise 'old artwork payload must not be read for structure checking' if length > 65536
        read.call(io, offset, length)
      end
      file.define_singleton_method(:read_native) { raise 'old native metadata must not be loaded' }
      file.metadata = API::MetadataSnapshot.new
      result = file.save!
      assert_empty result[:snapshots][:metadata].items
    end
  end

  should 'write edited output directly to a new stage and return actual verified snapshots' do
    stage = File.join(@dir, 'stage.mp4')
    original = File.binread(@source)
    API.open(@source) do |file|
      candidate = file.metadata.with(properties: { title: 'stage直接出力' })
      file.metadata = candidate
      file.define_singleton_method(:load_chapters) { raise 'unrelated chapters must not load' }
      result = file.save!(to: stage)
      actual = result[:snapshots][:metadata]
      assert_equal candidate, actual
      assert_not_same candidate, actual
      assert_not_include result[:snapshots], :chapters
      assert_equal original, File.binread(@source)
      assert_same candidate, file.metadata
      assert actual.frozen?
      assert result[:snapshots].frozen?
    end
    assert_equal ['stage直接出力'], API.open(stage) { |file| file.metadata.properties[:title] }
    assert_equal original, File.binread(@source)
  end

  should 'optionally capture actual chapters once and allow no IO snapshot reuse after close' do
    saved = nil
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '選択再読込' })
      result = file.save!(snapshots: [:chapters])
      saved = result.fetch(:snapshots)
      assert_equal %i[chapters metadata], saved.keys.sort
      file.define_singleton_method(:read_native) { raise 'unexpected reread' }
      assert_same saved[:metadata], file.metadata
      assert_same saved[:chapters], file.chapters
      assert_equal :complete, file.diagnose(:chapters)[:status]
    end
    assert_empty saved[:chapters].quicktime
    assert_equal ['選択再読込'], saved[:metadata].properties[:title]
  end

  should 'keep lightweight changes free from chapter and metadata loading' do
    API.open(@source) do |file|
      file.define_singleton_method(:read_native) { raise 'unexpected read' }
      file.define_singleton_method(:load_chapters) { raise 'unexpected chapters' }
      assert_equal false, file.changes[:changed]
      assert_equal false, file.save![:changed]
      file.metadata = API::MetadataSnapshot.new
      assert_equal [{ area: :metadata }], file.changes[:metadata]
      assert_empty file.changes[:chapters]
    end
  end

  should 'avoid output chapter analysis for metadata only saves even after earlier chapter reads' do
    reader = TagLib::MP4.const_get(:ChapterReader, false)
    original = reader.method(:new)
    API.open(@source) do |file|
      file.chapters
      file.metadata = file.metadata.with(properties: { title: 'metadataだけ' })
      reader.define_singleton_method(:new) { |*_, **_| raise 'unrelated output chapter analysis' }
      result = file.save!
      assert_not_include result[:snapshots], :chapters
    end
  ensure
    reader.define_singleton_method(:new, original) if original
  end

  should 'share frozen artwork bytes and unchanged items across with and without' do
    mutable = "\xFF\xD8\xFF".b + 'x'.b * (8 * 1024 * 1024)
    image = API::Artwork.new(format: :jpeg, data: mutable)
    snapshot = API::MetadataSnapshot.new(artworks: [image, image])
    bytes = snapshot.item('covr').value.first.last
    assert_same image.data, bytes
    assert_not_same mutable, bytes
    updated = snapshot.with(properties: { title: 'new' })
    removed = updated.without(properties: [:title])
    assert_same snapshot.item('covr'), updated.item('covr')
    assert_same snapshot.item('covr'), removed.item('covr')
    assert_same bytes, removed.artworks.first.data
    assert_same bytes, removed.artworks.last.data
    mutable.setbyte(3, 0)
    assert_equal 'x'.ord, bytes.getbyte(3)
    assert bytes.frozen?
  end

  should 'retain structure rejection even when old destination values are not converted' do
    edit_fixture(@source) do |moov|
      each_fixture_atom([moov]) do |atom|
        next unless atom[:type] == 'stco'
        atom[:data][8, 4] = [File.size(@source) + 1000].pack('N')
      end
    end
    original = File.binread(@source)
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.metadata = API::MetadataSnapshot.new }
      assert_equal false, error.committed
      assert_not_empty error.issues
      assert_equal original, File.binread(@source)
    end
  end

  should 'share the atom index and full chapter observation without retaining native owners' do
    API.open(@source) do |file|
      info = file.info
      generation = file.instance_variable_get(:@generation)
      index = generation.instance_variable_get(:@atom_index)
      assert_not_nil index
      file.chapters
      reader = generation.cached_chapter_reader(false)
      assert reader.frozen?
      assert_nil reader.instance_variable_get(:@file)
      assert_nil reader.instance_variable_get(:@io)
      assert_same index, reader.instance_variable_get(:@atoms)
      file.define_singleton_method(:read_native) { raise 'duplicate native analysis' }
      assert_equal :complete, file.diagnose(:chapters)[:status]
      assert_same info, file.info
    end
  end

  should 'invalidate header snapshots only when the original is successfully replaced' do
    API.open(@source) do |file|
      original_info = file.info
      file.metadata = file.metadata.with(properties: { title: 'header世代' })
      file.save!(to: File.join(@dir, 'stage.mp4'))
      assert_same original_info, file.info
      file.save!
      assert_not_same original_info, file.info
      assert_equal original_info[:movie], file.info[:movie]
    end
  end

  should 'return selected no change snapshots and share them with getters without rescanning' do
    API.open(@source) do |file|
      assert_raise(ArgumentError) { file.save!(snapshots: [:unknown]) }
      result = file.save!(snapshots: [:metadata, :chapters])
      assert_equal false, result[:changed]
      assert_nil result[:output_digest]
      file.define_singleton_method(:read_native) { raise 'unexpected no-change reread' }
      assert_same result[:snapshots][:metadata], file.metadata
      assert_same result[:snapshots][:chapters], file.chapters
    end
  end
end
