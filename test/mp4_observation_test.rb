# frozen_string_literal: true

require_relative 'helper'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative 'support/mp4_investigation_fixture'

# 同一世代の観測APIが、破損を例外ではなく領域別statusで返すことを実MP4で確認する。
class MP4ObservationTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  setup do
    @dir = Dir.mktmpdir('mp4-observation-')
    @path = File.join(@dir, 'input.mp4')
    build_mp4(@path)
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  should 'return chapters, metadata and tracks from one observation' do
    original_digest = Digest::SHA256.file(@path).hexdigest
    API.open(@path) do |file|
      observed = file.observation(%i[chapters metadata tracks])
      assert_predicate observed, :frozen?
      assert_equal %i[chapters metadata tracks], observed.keys

      assert_equal :complete, observed[:chapters][:status]
      assert_equal %w[開始 後半], observed[:chapters][:value][:nero].map(&:title)
      assert_equal %w[開始 後半], observed[:chapters][:value][:quicktime].map(&:title)

      assert_equal :complete, observed[:metadata][:status]
      assert_instance_of API::MetadataSnapshot, observed[:metadata][:value]
      # 同じhandleで読んだmetadataを編集候補にも使い、再openしない。
      assert_same observed[:metadata][:value], file.metadata

      assert_equal :complete, observed[:tracks][:status]
      # 映像・音声・chapter用textの3track。
      assert_equal 3, observed[:tracks][:value][:tracks].length

      all = file.observation
      assert_equal %i[metadata chapters chapter_references chapter_timing chapter_samples tracks], all.keys
      assert_includes %i[complete absent unsupported malformed], all[:chapter_samples][:status]
      assert_nil all[:chapter_samples][:value] unless all[:chapter_samples][:status] == :complete
      assert_equal all[:chapter_references][:data], all[:chapter_references][:value]
      assert_equal all[:chapter_timing][:data], all[:chapter_timing][:value]
    end
    assert_equal original_digest, Digest::SHA256.file(@path).hexdigest
  end

  should 'report a malformed chapter format without raising and keep the other format' do
    move_reference_to_video
    API.open(@path) do |file|
      observed = file.observation(:chapters).fetch(:chapters)
      assert_equal file.diagnose(:chapters)[:status], observed[:status]
      assert_includes %i[malformed unsupported], observed[:status]
      assert_equal %w[開始 後半], observed[:value][:nero].map(&:title)
      assert_nil observed[:value][:quicktime]
    end
  end

  should 'report malformed metadata without raising and keep metadata unreadable' do
    inject_metadata(@path, keys: ['comment'], indices: [0, 1])
    API.open(@path) do |file|
      observed = file.observation(:metadata).fetch(:metadata)
      assert_equal :malformed, observed[:status]
      assert_nil observed[:value]
      assert_equal :malformed, file.diagnose(:metadata)[:status]
      assert_raise(API::Error) { file.metadata }
    end
  end

  should 'reject unknown or duplicate areas and observe the saved generation while chapters are edited' do
    API.open(@path) do |file|
      assert_raise(ArgumentError) { file.observation(:unknown) }
      assert_raise(ArgumentError) { file.observation(%i[chapters chapters]) }

      file.chapters = file.chapters.with(nero: [])
      observed = file.observation(:chapters).fetch(:chapters)
      assert_equal %w[開始 後半], observed[:value][:nero].map(&:title)
    end
  end

  should 'read the chapter snapshot through the Ruby reader without opening native' do
    API.open(@path) do |file|
      file.define_singleton_method(:read_native) { |&_| raise 'native must not be opened' }

      snapshot = file.chapters
      assert_equal %w[開始 後半], snapshot.nero.map(&:title)
      assert_equal %w[開始 後半], snapshot.quicktime.map(&:title)
      assert_same snapshot, file.chapters
    end
  end

  should 'reuse the original metadata observation while a different candidate is pending' do
    API.open(@path) do |file|
      original = file.observation(:metadata)[:metadata][:value]
      file.metadata = original.with(properties: { title: '候補' })
      file.define_singleton_method(:read_native) { |*| raise 'observation must reuse the baseline' }
      assert_same original, file.observation(:metadata)[:metadata][:value]
    end
  end

  private

  def build_mp4(path)
    _, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error', '-y',
      '-f', 'lavfi', '-i', 'color=size=64x64:rate=10:duration=1',
      '-f', 'lavfi', '-i', 'sine=duration=1',
      '-c:v', 'libx264', '-c:a', 'aac', path)
    raise error unless status.success?

    chapters = [API::Chapter.new(start_ms: 0, title: '開始'), API::Chapter.new(start_ms: 500, title: '後半')]
    API.open(path) do |file|
      file.chapters = file.chapters.with(nero: chapters, quicktime: chapters)
      file.save!
    end
  end

  # chapter参照を音声から映像へ移し、複数候補としてQuickTime判定を破損させる。
  def move_reference_to_video
    edit_fixture(@path) do |moov|
      tracks = fixture_tracks(moov).to_h do |track|
        [fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4), track]
      end
      reference = fixture_child(tracks.fetch('soun'), 'tref')
      tracks.fetch('soun')[:children].delete(reference)
      tracks.fetch('vide')[:children] << reference
    end
  end
end
