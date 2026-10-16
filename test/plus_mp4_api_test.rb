# frozen_string_literal: true

require_relative 'helper'
require 'tmpdir'
require 'fileutils'

class PlusMP4APITest < Test::Unit::TestCase
  API = TagLib::Plus::MP4

  setup do
    @dir = Dir.mktmpdir('plus-mp4-api-')
    @source = File.join(@dir, 'source.m4a')
    FileUtils.cp('test/data/mp4.m4a', @source)
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  should 'edit immutable metadata values and save to a new output without retargeting the session' do
    output = File.join(@dir, 'output.m4a')
    original_digest = Digest::SHA256.file(@source).hexdigest
    API.open(@source) do |file|
      original = file.metadata
      edited = original.with(properties: { title: '新しい題名' })

      assert_equal ['Title'], original.properties[:title]
      assert_equal ['新しい題名'], edited.properties[:title]
      assert_not_same original, edited
      file.metadata = edited
      assert_equal true, file.changes[:changed]

      result = file.save!(to: output)
      assert_equal output, result[:output_path]
      assert_equal original_digest, result[:source_digest]
      assert_equal original_digest, Digest::SHA256.file(@source).hexdigest
      assert_equal ['新しい題名'], file.metadata.properties[:title]
      assert_equal ['新しい題名'], API.open(output) { |copy| copy.metadata.properties[:title] }
    end
  end

  should 'continue editing after replacing the source' do
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '一回目' })
      file.save!
      assert_equal ['一回目'], file.metadata.properties[:title]
      file.metadata = file.metadata.with(properties: { title: '二回目' })
      file.save!
    end
    assert_equal ['二回目'], API.open(@source) { |file| file.metadata.properties[:title] }
  end

  should 'copy unchanged bytes without replacing the source or creating pending edits' do
    output = File.join(@dir, 'unchanged.m4a')
    original_digest = Digest::SHA256.file(@source).hexdigest
    original_inode = File.stat(@source).ino
    API.open(@source) do |file|
      assert_equal false, file.save![:changed]
      result = file.save!(to: output)
      assert_equal false, result[:changed]
      assert_equal original_digest, result[:source_digest]
      assert_equal original_digest, result[:output_digest]
      assert_equal original_digest, Digest::SHA256.file(output).hexdigest
      assert_equal original_inode, File.stat(@source).ino
      assert_equal false, !!file.changes[:changed]
    end
  end

  should 'reject a stale source and keep the candidate for retry' do
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '保留候補' })
      File.open(@source, 'ab') { |io| io.write('external change') }
      error = assert_raise(API::Error) { file.save! }
      assert_equal :source_changed, error.code
      stale_read = assert_raise(API::Error) { file.metadata }
      assert_equal :source_changed, stale_read.code
    end
  end

  should 'reject editing after close and refuse an existing output' do
    file = API.open(@source)
    file.close
    assert_raise(API::Error) { file.metadata }

    output = File.join(@dir, 'existing.m4a')
    FileUtils.cp(@source, output)
    API.open(@source) do |active|
      active.metadata = active.metadata.with(properties: { title: '候補' })
      error = assert_raise(API::Error) { active.save!(to: output) }
      assert_equal :output_exists, error.code
    end
  end

  should 'expose typed mdta values without sharing mutable bytes' do
    value = API::MdtaValue.new(data_type: 1, locale: 0, data: 'value'.b)
    snapshot = API.open(@source) { |file| file.metadata.with(mdta: { 'custom' => [value] }) }
    assert_equal value, snapshot.mdta.fetch('custom').first
    assert snapshot.mdta.fetch('custom').first.data.frozen?
    assert snapshot.frozen?
  end

  should 'replace only the requested chapter format and preserve the other format' do
    TagLib::MP4::File.open(@source, false) do |native|
      native.set_chapters([TagLib::MP4::Chapter.new(0, '旧Nero')], style: :nero)
      native.set_chapters([TagLib::MP4::Chapter.new(0, '旧QuickTime')], style: :quicktime)
      assert native.save
    end

    API.open(@source) do |file|
      chapters = file.chapters
      updated = chapters.with(nero: [API::Chapter.new(start_ms: 0, title: '新Nero')])
      assert_equal ['新Nero'], updated.nero.map(&:title)
      assert_equal ['旧QuickTime'], updated.quicktime.map(&:title)
      file.chapters = updated
      file.save!
    end

    API.open(@source) do |file|
      assert_equal ['新Nero'], file.chapters.nero.map(&:title)
      assert_equal ['旧QuickTime'], file.chapters.quicktime.map(&:title)
    end
  end
end
