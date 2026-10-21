# frozen_string_literal: true

require_relative 'helper'
require 'tmpdir'
require 'fileutils'
require_relative 'support/mp4_investigation_fixture'

# 公開入口の走査予算と、stat世代確認・保存の独立検証を回帰検証する。
class PlusMP4IOTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  setup do
    @dir = Dir.mktmpdir('plus-io-test-')
    @source = File.join(@dir, 'source.mp4')
    FileUtils.cp('test/data/mp4.m4a', @source)
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  # stat属性に依存する検出を、同サイズ・mtime復元でも検証する。
  def change_source(path = @source)
    timestamp = File.stat(path).mtime
    File.open(path, 'r+b') do |io|
      io.seek(-1, IO::SEEK_END)
      byte = io.read(1).getbyte(0)
      io.seek(-1, IO::SEEK_END)
      io.write((byte ^ 1).chr)
    end
    File.utime(timestamp, timestamp, path)
  end

  should 'perform normal reads diagnostics and unchanged saves without a whole content hash' do
    original = Digest::SHA256.method(:file)
    Digest::SHA256.define_singleton_method(:file) { |*_| raise 'unexpected whole hash' }
    API.open(@source) do |file|
      2.times do
        file.metadata.properties[:title]
        file.chapters
        %i[metadata chapters chapter_references chapter_timing color structure].each { |area| file.diagnose(area) }
      end
      assert_empty file.detach_chapter_references(references: [])
      result = file.save!
      assert_nil result[:source_digest]
      assert_nil result[:output_digest]
      assert_equal :stat, result[:verification]
    end
  ensure
    Digest::SHA256.define_singleton_method(:file, original) if original
  end

  should 'share immutable snapshots and diagnostics and invalidate diagnostics after publication' do
    API.open(@source) do |file|
      assert_same file.metadata, file.metadata
      assert_same file.chapters, file.chapters
      report = file.diagnose(:metadata)
      assert_same report, file.diagnose(:metadata)
      file.metadata = file.metadata.with(properties: { title: 'cache更新' })
      file.save!
      assert_not_same report, file.diagnose(:metadata)
      assert_same file.diagnose(:metadata), file.diagnose(:metadata)
    end
  end

  should 'reject same size changes even when mtime is restored for cached reads' do
    %i[stat sha256].each do |verification|
      API.open(@source, verification: verification) do |file|
        file.metadata
        file.chapters
        file.diagnose(:metadata)
        change_source
        %i[metadata chapters changes].each do |operation|
          error = assert_raise(API::Error) { file.public_send(operation) }
          assert_equal :source_changed, error.code
          assert_equal false, error.committed
        end
        assert_equal :source_changed, assert_raise(API::Error) { file.diagnose(:metadata) }.code
      end
    end
  end

  should 'reject path replacement while retaining the original handle' do
    API.open(@source) do |file|
      replacement = File.join(@dir, 'replacement.mp4')
      FileUtils.cp(@source, replacement)
      File.rename(replacement, @source)
      assert_equal :source_changed, assert_raise(API::Error) { file.metadata }.code
    end
  end

  should 'adopt a published generation when only ctime differs and both contents match' do
    generation = API.const_get(:Generation, false).new(@source, :stat)
    original = generation.instance_variable_get(:@identity)
    calls = 0
    generation.define_singleton_method(:identity) do |_stat|
      calls += 1
      original[0, 4] + [original[4] + [calls, 2].min]
    end

    generation.__send__(:expect_publication_digest, Digest::SHA256.file(@source).hexdigest)
    generation.publish_to(@source)

    assert_equal original[0, 4] + [original[4] + 2], generation.__send__(:token)
  ensure
    generation&.close
  end

  should 'reject a published generation when ctime differs but content SHA256 differs' do
    generation = API.const_get(:Generation, false).new(@source, :stat)
    original = generation.instance_variable_get(:@identity)
    calls = 0
    generation.define_singleton_method(:identity) do |_stat|
      calls += 1
      original[0, 4] + [original[4] + calls]
    end

    error = assert_raise(API::Error) do
      generation.__send__(:expect_publication_digest, '0' * 64)
      generation.publish_to(@source)
    end
    assert_equal :source_changed, error.code
  ensure
    generation&.close
  end

  should 'reject a published generation when dev, inode, size, or mtime differs' do
    generation_class = API.const_get(:Generation, false)
    %i[dev ino size mtime].each do |field|
      generation = generation_class.new(@source, :stat)
      baseline = generation.instance_variable_get(:@identity)
      index = %i[dev ino size mtime ctime].index(field)
      generation.define_singleton_method(:identity) do |_stat|
        value = baseline.dup
        value[index] += 1
        value
      end
      generation.__send__(:expect_publication_digest, Digest::SHA256.file(@source).hexdigest)
      error = assert_raise(API::Error) { generation.publish_to(@source) }
      assert_equal :source_changed, error.code, "#{field}差分をsource_changedにできません"
    ensure
      generation&.close
    end
  end

  should 'complete in-place save when publication ctime differs but candidate content matches' do
    generation_class = API.const_get(:Generation, false)
    generation_class.prepend(Module.new do
      # 公開候補だけfd/pathのctimeをずらし、SMB属性反映遅延を合成する。
      def publish_to(path)
        return super unless Thread.current[:smb_ctime_probe]

        @smb_ctime_probe_active = true
        super
      ensure
        @smb_ctime_probe_active = false
      end

      def identity(stat)
        value = super
        return value unless @smb_ctime_probe_active

        @smb_ctime_probe_calls = (@smb_ctime_probe_calls || 0) + 1
        return value unless @smb_ctime_probe_calls == 1

        value.dup.tap { |identity| identity[4] += 1 }
      end
    end)

    Thread.current[:smb_ctime_probe] = true
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'ctime遅延を許容' })
      result = file.save!
      assert_equal true, result[:changed]
      assert_equal result[:output_digest], Digest::SHA256.file(@source).hexdigest
      assert_equal ['ctime遅延を許容'], file.metadata.properties[:title]
      assert_equal false, file.changes[:changed]
    end
    assert_equal ['ctime遅延を許容'], API.open(@source) { |file| file.metadata.properties[:title] }
  ensure
    Thread.current[:smb_ctime_probe] = nil
  end

  should 'use content verification in strict mode even if stat observations are unchanged' do
    API.open(@source, verification: :sha256) do |file|
      generation = file.instance_variable_get(:@generation)
      observed = generation.instance_variable_get(:@identity)
      generation.define_singleton_method(:identity) { |_| observed }
      change_source
      assert_equal :source_changed, assert_raise(API::Error) { file.metadata }.code
    end
  end

  should 'detect changes made during a native read before returning or caching values' do
    API.open(@source) do |file|
      read = file.method(:read_native)
      mutate = method(:change_source)
      file.define_singleton_method(:read_native) do |&operation|
        read.call do |native|
          value = operation.call(native)
          mutate.call
          value
        end
      end
      assert_equal :source_changed, assert_raise(API::Error) { file.metadata }.code
    end
  end

  should 'retain original and candidates on changes immediately before publication' do
    API.open(@source) do |file|
      candidate = file.metadata.with(properties: { title: '候補' })
      file.metadata = candidate
      verify = file.method(:verify_candidate)
      mutate = method(:change_source)
      file.define_singleton_method(:verify_candidate) do |path|
        result = verify.call(path)
        mutate.call
        result
      end
      error = assert_raise(API::Error) { file.save! }
      assert_equal :source_changed, error.code
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_equal ['Title'], API.open(@source) { |copy| copy.metadata.properties[:title] }
    end
  end

  should 'create exactly one full candidate and independently scan the saved output' do
    stream = API.const_get(:Stream, false)
    original = stream.method(:scan)
    calls = []
    stream.define_singleton_method(:scan) do |path, **options|
      calls << [path, options]
      original.call(path, **options)
    end
    API.open(@source) do |file|
      file.metadata = file.metadata.with(mdta: { 'custom' => [API::MdtaValue.new(data_type: 1, locale: 7, data: 'value')] })
      result = file.save!
      assert_equal 2, calls.length
      assert_equal File.realpath(@source), calls.first.first
      assert calls.first.last[:destination]
      assert_empty calls.last.last
      assert_equal result[:output_digest], Digest::SHA256.file(@source).hexdigest
    end
  ensure
    stream.define_singleton_method(:scan, original) if original
  end

  should 'reject media corruption independently of the copy time hash' do
    original = File.binread(@source)
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '破損を拒否' })
      prepare = file.method(:prepare_candidate)
      file.define_singleton_method(:prepare_candidate) do |path, **options|
        prepare.call(path, **options)
        File.open(path, 'r+b') do |io|
          until io.eof?
            start = io.pos
            size, type = io.read(8).unpack('Na4')
            if type == 'mdat'
              byte = io.read(1).getbyte(0)
              io.seek(-1, IO::SEEK_CUR)
              io.write((byte ^ 1).chr)
              break
            end
            io.seek(start + size)
          end
        end
      end
      error = assert_raise(API::Error) { file.save! }
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_match(/media verification/, error.message)
      assert_equal original, File.binread(@source)
    end
  end

  should 'preserve originals and Error causes when copying or native candidate saving fails' do
    original = File.binread(@source)
    %i[prepare_candidate build_mdir_metadata].each do |operation|
      API.open(@source) do |file|
        file.metadata = file.metadata.with(properties: { title: '失敗候補' })
        failure = IOError.new("injected #{operation}")
        file.define_singleton_method(operation) { |*_, **_| raise failure }
        error = assert_raise(API::Error) { file.save! }
        assert_equal :write, error.phase
        assert_equal false, error.committed
        assert_same failure, error.cause
        assert_equal original, File.binread(@source)
        assert_equal false, File.exist?(error.temporary_path)
        assert_equal ['失敗候補'], file.metadata.properties[:title]
      end
    end
  end

  should 'clean partial copy output and retain the actual copying failure' do
    original_bytes = File.binread(@source)
    stream = API.const_get(:Stream, false)
    original = stream.method(:scan)
    failure = IOError.new('partial copy fault')
    stream.define_singleton_method(:scan) do |path, **options|
      if options[:destination]
        File.binwrite(options.fetch(:destination), 'partial')
        raise failure
      end
      original.call(path, **options)
    end
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'コピー失敗候補' })
      error = assert_raise(API::Error) { file.save! }
      assert_same failure, error.cause
      assert_equal :write, error.phase
      assert_equal false, error.committed
      assert_equal false, File.exist?(error.temporary_path)
      assert_equal original_bytes, File.binread(@source)
    end
  ensure
    stream.define_singleton_method(:scan, original) if original
  end

  should 'reject a candidate modified after independent media scanning' do
    original = File.binread(@source)
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: '検証中の競合' })
      verify = file.method(:verify_candidate)
      mutate = method(:change_source)
      file.define_singleton_method(:verify_candidate) do |path|
        result = verify.call(path)
        mutate.call(path)
        result
      end
      error = assert_raise(API::Error) { file.save! }
      assert_equal :source_changed, error.code
      assert_equal :verify, error.phase
      assert_equal false, error.committed
      assert_equal original, File.binread(@source)
    end
  end

  should 'independently verify ordinary purl locale bytes invisible to item value equality' do
    edit_fixture(@source) do |moov|
      ilst = fixture_child(fixture_child(fixture_child(moov, 'udta'), 'meta'), 'ilst')
      ilst[:children] << parse_boxes(atom_box('purl', atom_box('data', [1, 7].pack('N2') + 'https://example.test/feed'))).first
    end
    original = File.binread(@source)
    edit = method(:edit_fixture)
    child = method(:fixture_child)
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'raw検証' })
      prepare = file.method(:prepare_candidate)
      file.define_singleton_method(:prepare_candidate) do |path, **options|
        prepare.call(path, **options)
        edit.call(path) do |moov|
          ilst = child.call(child.call(child.call(moov, 'udta'), 'meta'), 'ilst')
          purl = child.call(ilst, 'purl')
          purl[:data][12, 4] = [9].pack('N')
        end
      end
      error = assert_raise(API::Error) { file.save! }
      assert_equal :verify, error.phase
      assert_match(/purl raw verification/, error.message)
      assert_equal original, File.binread(@source)
    end
  end

  should 'save generic metadata and both chapter formats together and continue editing paired contexts' do
    API.open(@source) do |file|
      file.chapters = file.chapters.with(nero: [API::Chapter.new(start_ms: 0, title: '元Nero')],
        quicktime: [API::Chapter.new(start_ms: 0, title: '元QT')])
      file.save!
      media = parse_boxes(File.binread(@source)).select { |atom| atom[:type] == 'mdat' }.map { |atom| atom[:data] }
      file.metadata = file.metadata.with(mdta: { 'custom' => [API::MdtaValue.new(data_type: 1, locale: 7, data: 'value')] })
      file.chapters = file.chapters.with(nero: [API::Chapter.new(start_ms: 0, title: '新Nero')])
      file.save!
      assert_equal media, parse_boxes(File.binread(@source)).select { |atom| atom[:type] == 'mdat' }.map { |atom| atom[:data] }
      assert_equal ['元QT'], file.chapters.quicktime.map(&:title)
      assert_equal ['新Nero'], file.chapters.nero.map(&:title)
      file.metadata = file.metadata.with(properties: { title: '併存を編集' })
      file.chapters = file.chapters.with(quicktime: [API::Chapter.new(start_ms: 0, title: '新QT')])
      file.save!
    end
    API.open(@source) do |file|
      assert_equal ['併存を編集'], file.metadata.properties[:title]
      assert_equal 'value', file.metadata.mdta.fetch('custom').first.data
      assert_equal ['新QT'], file.chapters.quicktime.map(&:title)
      assert_equal ['新Nero'], file.chapters.nero.map(&:title)
      assert_equal :complete, file.diagnose(:metadata)[:status]
    end
  end

  should 'combine complete metadata removal with Nero removal while preserving QuickTime' do
    API.open(@source) do |file|
      file.chapters = file.chapters.with(nero: [API::Chapter.new(start_ms: 0, title: '削除')],
        quicktime: [API::Chapter.new(start_ms: 0, title: '保持')])
      file.save!
      file.metadata = API::MetadataSnapshot.new
      file.chapters = file.chapters.with(nero: [])
      file.save!
    end
    API.open(@source) do |file|
      assert_empty file.metadata.items
      assert_empty file.metadata.mdta
      assert_empty file.chapters.nero
      assert_equal ['保持'], file.chapters.quicktime.map(&:title)
    end
  end

  should 'return real strict digests and retain strict checking after saving' do
    assert_raise(ArgumentError) { API.open(@source, verification: :unknown) }
    API.open(@source, verification: :sha256) do |file|
      assert_equal Digest::SHA256.file(@source).hexdigest, file.save![:output_digest]
      file.metadata = file.metadata.with(properties: { title: '厳密保存' })
      result = file.save!
      assert_equal Digest::SHA256.file(@source).hexdigest, result[:output_digest]
      assert_equal result[:output_digest], file.save![:source_digest]
      change_source
      assert_equal :source_changed, assert_raise(API::Error) { file.metadata }.code
    end
  end
end
