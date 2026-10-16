# frozen_string_literal: true

require_relative 'helper'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative 'support/mp4_investigation_fixture'

# 公開境界と保存の状態遷移を、一時コピーと独立したfixture編集で検証する。
class PlusMP4APITest < Test::Unit::TestCase
  include MP4InvestigationFixture
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

  should 'diagnose the mdir and mdta contexts produced by public snapshot saving' do
    output = File.join(@dir, 'mdir-mdta.m4a')
    values = {
      'audio_normalization' => [API::MdtaValue.new(data_type: 1, locale: 0, data: 'loudnorm'.b)],
      'audio_normalization_target' => [API::MdtaValue.new(data_type: 1, locale: 0, data: '-16-LUFS'.b)]
    }
    API.open(@source) do |file|
      file.metadata = file.metadata.with(mdta: values)
      file.save!(to: output)
    end

    API.open(output) do |file|
      report = file.diagnose(:metadata)
      assert_equal :complete, report[:status]
      assert_empty report[:issues]
      snapshot = file.metadata
      assert_equal ['Title'], snapshot.properties[:title]
      assert_equal values['audio_normalization'], snapshot.mdta.fetch('audio_normalization')
      assert_equal values['audio_normalization_target'], snapshot.mdta.fetch('audio_normalization_target')
    end
  end

  should 'expose cover art through public symbols and preserve duplicate order' do
    data = File.binread('test/data/globe_east_90.jpg')
    image = API::Artwork.new(format: :jpeg, data: data)
    snapshot = API::MetadataSnapshot.new(artworks: [image, image])
    assert_equal [:jpeg, :jpeg], snapshot.artworks.map(&:format)
    assert_equal [data, data], snapshot.artworks.map(&:data)
    assert_raise(ArgumentError) { API::MetadataSnapshot.new(artworks: [image], items: [API::MetadataItem.new(key: 'covr', kind: :cover_art_list, atom_data_type: 0, value: [])]) }
  end

  should 'replace only the requested chapter format and preserve the other format' do
    TagLib::MP4::Internal::File.open(@source, false) do |native|
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

  should 'expose Plus operations only through the editing API and keep native converters private' do
    TagLib::MP4::File.open(@source, false) do |native|
      TagLib::MP4::Internal::FILE_OPERATIONS.each do |operation|
        assert_not_respond_to native, operation
      end
      TagLib::MP4::Internal::TAG_OPERATIONS.each do |operation|
        assert_not_respond_to native.tag, operation
      end
      assert_respond_to native, :save
      assert_respond_to native.tag, :title
    end
    snapshot = API::MetadataSnapshot.new(items: [API::MetadataItem.new(
      key: '©nam', kind: :string_list, atom_data_type: 1, value: ['手動構築'])])
    assert_equal ['手動構築'], snapshot.properties[:title]
    assert_not_respond_to snapshot, :to_legacy
    assert_not_respond_to API::MetadataSnapshot, :from_legacy
    mdta = API::MetadataSnapshot.new(mdta: { 'empty' => [] })
    assert_equal [], mdta.mdta['empty']
    updated = snapshot.with(properties: { tv_show: '番組名', long_description: '詳細' })
    assert_equal ['番組名'], updated.properties[:tv_show]
    assert_equal ['詳細'], updated.properties[:long_description]
    assert updated.properties.frozen?
    assert updated.properties[:tv_show].first.frozen?
  end

  should 'retain source and candidate and allow retry after each failure before publication' do
    { prepare_candidate: :write, verify_candidate: :verify, publish_candidate: :publish }.each do |operation, phase|
      [false, true].each do |save_as|
        output = File.join(@dir, "#{operation}-#{save_as}.m4a")
        original = File.binread(@source)
        API.open(@source) do |file|
          candidate = file.metadata.with(properties: { title: "候補#{operation}-#{save_as}" })
          file.metadata = candidate
          failure = IOError.new("injected #{operation}")
          file.define_singleton_method(operation) { |*_, **_| raise failure }
          error = assert_raise(API::Error) { save_as ? file.save!(to: output) : file.save! }
          assert_equal phase, error.phase
          assert_equal false, error.committed
          assert_same failure, error.cause
          assert_equal original, File.binread(@source)
          assert_equal false, File.exist?(output)
          assert_equal false, File.exist?(error.temporary_path)
          assert_same candidate, file.metadata
          assert_equal true, file.changes[:changed]
          file.singleton_class.remove_method(operation)
          save_as ? file.save!(to: output) : file.save!
          assert_equal save_as, file.changes[:changed]
        end
      end
    end
  end

  should 'reject all session operations after an Error raised following publication' do
    [false, true].each do |save_as|
      original = File.binread(@source)
      output = save_as ? File.join(@dir, 'published.m4a') : @source
      file = API.open(@source)
      file.metadata = file.metadata.with(properties: { title: '公開済み' })
      failure = API::Error.new('result failed', code: :injected)
      file.define_singleton_method(:result) { |*_, **_| raise failure }
      error = assert_raise(API::Error) { save_as ? file.save!(to: output) : file.save! }
      assert_equal true, error.committed
      assert_equal :result, error.phase
      assert_equal :injected, error.code
      assert_same failure, error.cause
      assert_equal ['公開済み'], API.open(output) { |copy| copy.metadata.properties[:title] }
      assert_equal original, File.binread(@source) if save_as
      [-> { file.metadata }, -> { file.chapters }, -> { file.changes }, -> { file.info },
       -> { file.diagnose(:metadata) }, -> { file.chapter_samples },
       -> { file.metadata = API::MetadataSnapshot.new }, -> { file.chapters = API::ChapterSnapshot.new },
       -> { file.detach_chapter_references(references: []) },
       -> { file.repair_chapter_timing(track_id: 1, profile: :taglib_full_movie) },
       -> { file.save! }].each do |operation|
        refused = assert_raise(API::Error, &operation)
        assert_equal :committed_failure, refused.code
        assert_equal true, refused.committed
      end
      assert_nil file.close
      assert_nil file.close
    end
  end

  should 'adopt verified values without reopening the published source' do
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '検証済み値' })
      publish = file.method(:publish_candidate)
      file.define_singleton_method(:publish_candidate) do |*args, **keywords|
        publish.call(*args, **keywords)
        define_singleton_method(:read_native) { |&_| raise 'unexpected post-publication reopen' }
      end
      file.save!
      assert_equal ['検証済み値'], file.metadata.properties[:title]
      assert_equal false, file.changes[:changed]
    end
  end

  should 'preserve the original failure when cleanup also fails before publication' do
    original = File.binread(@source)
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '再試行候補' })
      file.define_singleton_method(:verify_candidate) { |*_| raise IOError, 'verify fault' }
      file.define_singleton_method(:cleanup_candidate) { |_| raise IOError, 'cleanup fault' }
      error = assert_raise(API::Error) { file.save! }
      assert_equal :cleanup, error.code
      assert_equal false, error.committed
      assert_match(/cleanup fault/, error.message)
      assert_equal :verify, error.cause.phase
      assert_equal 'verify fault', error.cause.cause.message
      assert_equal original, File.binread(@source)
      assert_equal ['再試行候補'], file.metadata.properties[:title]
      file.singleton_class.remove_method(:verify_candidate)
      file.singleton_class.remove_method(:cleanup_candidate)
      file.save!
    end
  end

  should 'mark a published output committed when cleanup fails and keep the source unchanged' do
    original = File.binread(@source)
    output = File.join(@dir, 'cleanup-published.m4a')
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'cleanup公開済み' })
      file.define_singleton_method(:cleanup_candidate) { |_| raise IOError, 'cleanup fault' }
      error = assert_raise(API::Error) { file.save!(to: output) }
      assert_equal :cleanup, error.code
      assert_equal true, error.committed
      assert_equal 'cleanup fault', error.cause.message
      assert_equal original, File.binread(@source)
      assert_equal ['cleanup公開済み'], API.open(output) { |copy| copy.metadata.properties[:title] }
      assert_equal :committed_failure, assert_raise(API::Error) { file.changes }.code
    end
  end

  should 'refuse an output created during publication without overwriting it' do
    output = File.join(@dir, 'racing.m4a')
    original = File.binread(@source)
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '競合候補' })
      publish = file.method(:publish_candidate)
      file.define_singleton_method(:publish_candidate) do |*args, **keywords|
        File.binwrite(output, 'other writer')
        publish.call(*args, **keywords)
      end
      error = assert_raise(API::Error) { file.save!(to: output) }
      assert_equal false, error.committed
      assert_kind_of Errno::EEXIST, error.cause
      assert_equal 'other writer', File.binread(output)
      assert_equal original, File.binread(@source)
      assert_equal true, file.changes[:changed]
    end
  end

  should 'return fixed immutable diagnostic schemas for every area' do
    API.open(@source) do |file|
      { metadata: %i[structure capabilities], chapters: [:formats], chapter_references: [:references],
        chapter_timing: [:tracks], color: [:entries], structure: %i[coverage file_size mdat_ranges tracks] }.each do |area, keys|
        report = file.diagnose(area)
        assert_equal %i[data issues status], report.keys.sort
        assert_include %i[complete unsupported malformed limit], report[:status]
        assert_equal keys.sort, report[:data].keys.sort
        assert report.frozen?
        assert report[:data].frozen?
        assert report[:issues].frozen?
      end
      assert_nil file.chapter_samples
      assert_raise(ArgumentError) { file.diagnose(:unknown) }
    end
  end

  should 'propagate IO failures from structure readers with their original cause' do
    [:chapters, :chapter_references, :color].each do |area|
      API.open(@source) do |file|
        read = file.method(:read_native)
        failure = IOError.new('structure read fault')
        file.define_singleton_method(:read_native) do |&operation|
          read.call do |native|
            native.define_singleton_method(:parse_mp4_atoms) { |*_| raise failure }
            operation.call(native)
          end
        end
        error = assert_raise(API::Error) { file.diagnose(area) }
        assert_equal :io, error.code
        assert_same failure, error.cause
      end
    end
    reader = TagLib::MP4::MetadataStructureReader.new
    reader.define_singleton_method(:walk) { |*_| raise NoMethodError, 'reader bug' }
    assert_raise(NoMethodError) { reader.read(@source) }
  end

  should 'classify structural refusals without hiding programming or IO errors' do
    [:unsupported, :malformed, :limit].each do |code|
      API.open(@source) do |file|
        file.define_singleton_method(:read_native) do |&block|
          native = Object.new
          native.define_singleton_method(:color_metadata_diagnostics) do
            raise TagLib::MP4::ColorMetadataError.new('bad colr', code: code)
          end
          block.call(native)
        end
        report = file.diagnose(:color)
        assert_equal code, report[:status]
        assert_nil report[:data]
        assert_equal({ code: code, message: 'bad colr', location: 'color', details: {} }, report[:issues].first)
      end
    end
    API.open(@source) do |file|
      file.define_singleton_method(:read_native) { |&_| raise NoMethodError, 'programming fault' }
      assert_raise(NoMethodError) { file.diagnose(:metadata) }
      file.define_singleton_method(:read_native) { |&_| raise IOError, 'read fault' }
      assert_raise(IOError) { file.diagnose(:metadata) }
    end
  end

  should 'diagnose unsupported chapter structures without requiring a complete snapshot at open' do
    File.open(@source, 'ab') { |io| io.write([8, 'moof'].pack('Na4')) }
    original = File.binread(@source)
    API.open(@source) do |file|
      [:chapters, :chapter_references].each do |area|
        report = file.diagnose(area)
        assert_equal :unsupported, report[:status]
        assert_equal %i[code details location message], report[:issues].first.keys.sort
      end
      error = assert_raise(API::Error) { file.chapters }
      assert_equal :unsupported, error.code
    end
    assert_equal original, File.binread(@source)
  end

  should 'return chapter samples as owned immutable values and refuse them during chapter edits' do
    TagLib::MP4::Internal::File.open(@source, false) do |native|
      native.set_chapters([TagLib::MP4::Chapter.new(0, 'sample')], style: :quicktime)
      assert native.save
    end
    samples = API.open(@source) do |file|
      observed = file.chapter_samples
      assert observed.frozen?
      assert observed[:samples].frozen?
      assert_equal 1, observed[:samples].size
      assert observed[:samples].first[:payload_sha256].frozen?
      file.chapters = file.chapters.with(quicktime: [])
      assert_equal :pending_changes, assert_raise(API::Error) { file.chapter_samples }.code
      observed
    end
    assert_equal 0, samples[:samples].first[:start_ticks]
  end

  should 'detach only selected references and isolate raw repair from snapshot edits' do
    seed_missing_references
    original = File.binread(@source)
    output = File.join(@dir, 'reference-output.m4a')
    API.open(@source) do |file|
      metadata = file.metadata
      selected = file.diagnose(:chapter_references)[:data][:references].first(1)
      assert_equal selected, file.detach_chapter_references(references: selected)
      [-> { file.metadata }, -> { file.chapters }, -> { file.chapter_samples },
       -> { file.metadata = metadata }].each do |operation|
        assert_equal :pending_changes, assert_raise(API::Error, &operation).code
      end
      file.save!(to: output)
      assert_equal original, File.binread(@source)
      assert_equal :chapter_references, file.changes[:repair]
      assert_equal [88_888], API.open(output) { |copy| copy.diagnose(:chapter_references)[:data][:references].map { |row| row[:target_track_id] } }
      file.save!
      assert_equal metadata, file.metadata
      assert_equal false, file.changes[:changed]
      assert_equal [88_888], file.diagnose(:chapter_references)[:data][:references].map { |row| row[:target_track_id] }
      file.metadata = metadata.with(properties: { title: '通常編集' })
      assert_equal :pending_changes, assert_raise(API::Error) { file.detach_chapter_references(references: selected) }.code
      assert_equal ['通常編集'], file.metadata.properties[:title]
    end
  end

  should 'reject altered non-target track bytes during repair verification' do
    seed_missing_references
    original = File.binread(@source)
    test_case = self
    API.open(@source) do |file|
      file.detach_chapter_references(references: file.diagnose(:chapter_references)[:data][:references])
      prepare = file.method(:prepare_candidate)
      file.define_singleton_method(:prepare_candidate) do |path, **keywords|
        prepare.call(path, **keywords)
        test_case.edit_fixture(path) do |moov|
          header = test_case.fixture_child(test_case.fixture_tracks(moov).first, 'tkhd')
          header[:data].setbyte(-1, header[:data].getbyte(-1) ^ 1)
        end
      end
      error = assert_raise(API::Error) { file.save! }
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_match(/structure preservation/, error.message)
      assert_equal original, File.binread(@source)
      file.singleton_class.remove_method(:prepare_candidate)
      file.save!
      assert_empty file.diagnose(:chapter_references)[:data][:references]
    end
  end

  should 'keep a published source usable only after verified baseline adoption succeeds' do
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'baseline公開済み' })
      file.define_singleton_method(:adopt_baseline!) { |*_| raise IOError, 'adoption fault' }
      error = assert_raise(API::Error) { file.save! }
      assert_equal :adopt, error.phase
      assert_equal true, error.committed
      assert_equal 'adoption fault', error.cause.message
      assert_equal :committed_failure, assert_raise(API::Error) { file.metadata }.code
      assert_equal ['baseline公開済み'], API.open(@source) { |copy| copy.metadata.properties[:title] }
    end
  end

  should 'repair a matching timing profile through the same verified save boundary' do
    TagLib::MP4::Internal::File.open(@source, false) do |native|
      native.set_chapters(Array.new(15) { |i| TagLib::MP4::Chapter.new((i + 1) * 50, '') }, style: :quicktime)
      assert native.save_chapters
    end
    duration = 1_605_653_349_300
    inject_chapter_timing(@source, movie_scale: 441_000_000, movie_duration: duration,
                          track_duration: 3_640_937, edit_rows: [[duration & 0xffffffff, 0, 65_536]])
    API.open(@source) do |file|
      before = file.chapter_samples
      id = file.diagnose(:chapter_timing)[:data][:tracks].first[:track_id]
      assert_equal :planned, file.repair_chapter_timing(track_id: id, profile: :taglib_full_movie)[:status]
      file.save!
      assert_equal before[:samples], file.chapter_samples[:samples]
      assert_equal before[:preservation_signature], file.chapter_samples[:preservation_signature]
      assert_empty file.diagnose(:chapter_timing)[:data][:tracks].first[:observations]
      assert_equal false, file.changes[:changed]
    end
  end

  should 'restore ordinary values and mdta values without semantic conversion after muxing' do
    base = File.join(@dir, 'base.m4a')
    target = File.join(@dir, 'muxed.m4a')
    FileUtils.cp('test/data/mp4.m4a', base)
    output, error, status = Open3.capture3(ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg'), '-v', 'error',
      '-i', base, '-map', '0', '-c', 'copy', '-movflags', 'use_metadata_tags',
      '-metadata', 'title=destination title', '-write_btrt', '0', target)
    assert status.success?, "ffmpeg failed: #{output}\n#{error}"

    FileUtils.cp(base, @source)
    TagLib::MP4::Internal::File.open(@source, false) do |native|
      native.tag.set_property('artist', 'source artist')
      native.tag.set_property('podcastURL', 'https://example.test/feed')
      assert native.save
    end
    source = API.open(@source) { |file| file.metadata }
    assert_equal ['source artist'], source.properties[:artist]

    API.open(target) do |file|
      file.metadata = source
      file.save!
    end

    API.open(target) do |file|
      actual = file.metadata
      assert_equal ['Title'], actual.properties[:title]
      assert_equal ['source artist'], actual.properties[:artist]
      assert_empty actual.mdta.fetch('artist', [])
      assert_equal ['https://example.test/feed'.b], actual.mdta.fetch('purl').map(&:data)
    end
  end

  private

  # 参照解除だけで章やmediaを変えないことを確認するため、欠落IDを二つ注入する。
  def seed_missing_references
    edit_fixture(@source) do |moov|
      fixture_tracks(moov).first[:children] << {
        type: 'tref', children: [{ type: 'chap', data: [99_999, 88_888].pack('N2') }]
      }
    end
  end
end
