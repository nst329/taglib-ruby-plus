# frozen_string_literal: true

require_relative 'helper'
require 'tmpdir'
require 'fileutils'
require_relative 'support/mp4_investigation_fixture'

# SMBを模擬した成功とは扱わず、実ローカルI/Oと境界の失敗注入を分ける。
class PlusMP4UnicodePathTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4
  PATH_API = API.const_get(:Path, false)
  NAMES = ['ascii', "が", "か\u3099"].freeze

  setup do
    @dir = Dir.mktmpdir('plus-unicode-')
    @source = File.join(@dir, 'source.mp4')
    # 音声・映像codecに依存しない、Nero章・unknown item・媒体bytesを持つ合成MP4。
    chapter = [0x01000000, 0].pack('N2') + [1].pack('C') + [0].pack('Q>') + [3].pack('C') + 'one'
    data = atom_box('data', [1, 0].pack('N2') + 'preserved')
    handler = atom_box('hdlr', [0, 0].pack('N2') + 'mdir' + "\0" * 12)
    meta = atom_box('meta', "\0" * 4 + handler + atom_box('ilst', atom_box('zzzz', data)))
    File.binwrite(@source, atom_box('ftyp', 'isom' + [0].pack('N')) +
      atom_box('moov', atom_box('udta', meta + atom_box('chpl', chapter))) +
      atom_box('mdat', "media\0payload\xff".b))
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  def payload(path)
    parse_boxes(File.binread(path)).select { |row| row[:type] == 'mdat' }.map { |row| row[:data] }
  end

  def test_public_round_trip_for_all_parent_and_child_representations
    NAMES.each_with_index do |parent, i|
      NAMES.each_with_index do |child, j|
        directory = File.join(@dir, "#{i}-#{j}-#{parent}")
        Dir.mkdir(directory)
        source = File.join(directory, "#{child}.mp4")
        output = File.join(directory, "out-#{child}.mp4")
        FileUtils.cp(@source, source)
        media = payload(source)
        original_chapters = API.open(source) { |file| file.chapters.nero.map(&:title) }
        API.open(source) do |file|
          assert_equal source.b, file.path.b
          original = File.binread(source)
          unchanged = file.save!
          assert_equal false, unchanged[:changed]
          assert_equal source.b, unchanged[:output_path].b
          assert_equal original, File.binread(source)
          file.metadata = file.metadata.with(properties: { title: "title-#{i}-#{j}" })
          saved = file.save!
          assert_equal source.b, saved[:output_path].b
          API.open(saved[:output_path]) do |copy|
            assert_equal ["title-#{i}-#{j}"], copy.metadata.properties[:title]
            assert_equal original_chapters, copy.chapters.nero.map(&:title)
            assert_equal ['preserved'], copy.metadata.items.find { |item| item.key == 'zzzz' }.value
          end
          assert_equal media, payload(source)
          retained = File.binread(source)
          file.metadata = file.metadata.with(properties: { title: 'separate' })
          separate = file.save!(to: output)
          assert_equal output.b, separate[:output_path].b
          assert_equal ['separate'], API.open(separate[:output_path]) { |copy| copy.metadata.properties[:title] }
          assert_equal retained, File.binread(source)
          assert_equal media, payload(output)
        end
        # unchangedの別出力も一字も変えないコピーとなる。
        copy_path = File.join(directory, "copy-#{child}.mp4")
        API.open(source) do |file|
          result = file.save!(to: copy_path)
          assert_equal false, result[:changed]
          assert_equal File.binread(source), File.binread(result[:output_path])
        end
        assert_equal 3, Dir.children(directory).size, 'temporary candidates must be removed'
        [copy_path, output, source].each do |path|
          File.unlink(path)
          assert_raise(Errno::ENOENT) { File.lstat(path) }
        end
        Dir.rmdir(directory)
        assert_raise(Errno::ENOENT) { File.lstat(directory) }
      end
    end
  end

  def test_posix_realpath_and_symlink_keep_os_returned_bytes
    omit('macOS POSIX boundary') unless RUBY_PLATFORM.include?('darwin')
    directory = File.join(@dir, "parent-か\u3099")
    Dir.mkdir(directory)
    target = File.join(directory, "child-か\u3099.mp4")
    FileUtils.cp(@source, target)
    link = File.join(@dir, 'link.mp4')
    File.symlink(target, link)
    # Dir#readのBINARY結果を期待値とし、Ruby realpathの文字列を期待値にしない。
    actual_child = Dir.open(directory, encoding: Encoding::BINARY) { |dir| dir.each.find { |entry| entry.end_with?('.mp4') } }
    actual_parent = Dir.open(@dir, encoding: Encoding::BINARY) { |dir| dir.each.find { |entry| entry.start_with?('parent-') } }
    expected = File.join(PATH_API.realpath(@dir).b, actual_parent, actual_child)
    assert_equal expected, PATH_API.realpath(link).b
    ruby_realpath = File.method(:realpath)
    File.define_singleton_method(:realpath) { |_| raise 'Ruby realpath must not handle the macOS symlink' }
    API.open(link) do |file|
      assert_equal expected, file.path.b
      file.metadata = file.metadata.with(properties: { title: 'symlink' })
      saved = file.save!
      assert_equal expected, saved[:output_path].b
      assert_equal ['symlink'], API.open(saved[:output_path]) { |copy| copy.metadata.properties[:title] }
    end
    assert File.lstat(link).symlink?
  ensure
    File.define_singleton_method(:realpath, ruby_realpath) if ruby_realpath
  end

  def test_dangling_symlink_is_not_absent_output
    link = File.join(@dir, 'dangling.mp4')
    File.symlink(File.join(@dir, 'missing.mp4'), link)
    error = assert_raise(API::Error) { API.open(link) }
    assert_equal :open, error.code
    assert_kind_of Errno::ENOENT, error.cause
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.save!(to: link) }
      assert_equal :output_exists, error.code
    end
    assert File.lstat(link).symlink?
  end

  def test_relative_nfd_path_preserves_spelling_without_realpath
    directory = File.join(@dir, "parent-か\u3099")
    Dir.mkdir(directory)
    source = File.join(directory, "child-か\u3099.mp4")
    FileUtils.cp(@source, source)
    expected = File.join(PATH_API.realpath(@dir), "parent-か\u3099/child-か\u3099.mp4")
    realpath = File.method(:realpath)
    File.define_singleton_method(:realpath) { |_| raise 'regular input must retain its path' }
    Dir.chdir(@dir) do
      API.open("parent-か\u3099/child-か\u3099.mp4") do |file|
        assert_equal expected.b, file.path.b
        assert_equal expected.b, file.save![:output_path].b
      end
    end
    Dir.chdir(directory) do
      API.open("child-か\u3099.mp4") do |file|
        assert_equal expected.b, file.path.b
        file.metadata = file.metadata.with(properties: { title: 'relative cwd' })
        result = file.save!(to: "output-か\u3099.mp4")
        assert_equal File.join(File.dirname(expected), "output-か\u3099.mp4").b, result[:output_path].b
        assert_equal ['relative cwd'], API.open(result[:output_path]) { |copy| copy.metadata.properties[:title] }
      end
    end
  ensure
    File.define_singleton_method(:realpath, realpath) if realpath
  end

  def test_existing_alias_is_rejected_instead_of_becoming_source_replacement
    source = File.join(@dir, "か\u3099.mp4")
    alternate = File.join(@dir, "が.mp4")
    FileUtils.cp(@source, source)
    # 別実体を許すFSではhardlinkで同じ実体のaliasを確実に作る。
    begin
      File.link(source, alternate)
    rescue Errno::EEXIST
      assert File.identical?(source, alternate)
    end
    retained = File.binread(source)
    API.open(source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'not replaced' })
      error = assert_raise(API::Error) { file.save!(to: alternate) }
      assert_equal :output_exists, error.code
      assert_equal retained, File.binread(source)
    end
  end

  def test_canonical_equivalence_does_not_override_identity
    source = File.join(@dir, "が.mp4")
    FileUtils.cp(@source, source)
    link = File.join(@dir, 'link.mp4')
    File.symlink(source, link)
    other = File.join(@dir, "か\u3099.mp4")
    # ローカルFSで別実体を作れなくても、POSIX返却先が別実体という境界を注入する。
    resolve = PATH_API.method(:realpath)
    identical = File.method(:identical?)
    PATH_API.define_singleton_method(:realpath) { |_| other }
    File.define_singleton_method(:identical?) { |left, right| left == link && right == other ? false : identical.call(left, right) }
    error = assert_raise(API::Error) { API.open(link) }
    assert_equal :path_conflict, error.code
    assert_equal File.binread(@source), File.binread(source)
  ensure
    PATH_API.define_singleton_method(:realpath, resolve) if resolve
    File.define_singleton_method(:identical?, identical) if identical
  end

  def test_open_and_output_permission_errors_are_not_absence
    original = File.method(:lstat)
    failure = Errno::EACCES.new('injected path')
    denied = @source
    File.define_singleton_method(:lstat) { |path| path == denied ? (raise failure) : original.call(path) }
    error = assert_raise(API::Error) { API.open(@source) }
    assert_same failure, error.cause
    denied = File.join(@dir, 'output.mp4')
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.save!(to: denied) }
      assert_equal :io, error.code
      assert_same failure, error.cause
    end
  ensure
    File.define_singleton_method(:lstat, original) if original
  end

  def test_unlink_success_with_remaining_entry_is_cleanup_failure_without_retry
    original = File.method(:unlink)
    calls = []
    File.define_singleton_method(:unlink) do |path|
      if File.basename(path).start_with?('taglib-plus-') && !File.basename(path).start_with?('taglib-plus-metadata-')
        calls << path
        1
      else
        original.call(path)
      end
    end
    API.open(@source) do |file|
      output = File.join(@dir, 'output.mp4')
      error = assert_raise(API::Error) { file.save!(to: output) }
      assert_equal :cleanup, error.code
      assert_equal :committed, error.publication_status
      assert_equal [error.temporary_path], calls
      assert File.identical?(error.temporary_path, error.output_path)
      assert_equal File.binread(@source), File.binread(output)
    end
  ensure
    File.define_singleton_method(:unlink, original) if original
  end

  def test_unlink_permission_failure_preserves_candidate_and_cause
    original = File.method(:unlink)
    failure = Errno::EACCES.new('injected unlink')
    File.define_singleton_method(:unlink) { |path| File.basename(path).start_with?('taglib-plus-') ? (raise failure) : original.call(path) }
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.save!(to: File.join(@dir, 'output.mp4')) }
      assert_equal :cleanup, error.code
      assert_same failure, error.cause
      assert File.lstat(error.temporary_path)
    end
  ensure
    File.define_singleton_method(:unlink, original) if original
  end

  def test_publication_failure_keeps_original_and_requested_bytes
    original = File.binread(@source)
    output = File.join(@dir, "か\u3099.mp4")
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'unpublished' })
      failure = Errno::EACCES.new('injected link')
      file.define_singleton_method(:link_candidate) { |*_| raise failure }
      error = assert_raise(API::Error) { file.save!(to: output) }
      assert_equal :not_committed, error.publication_status
      assert_equal output.b, error.output_path.b
      assert_same failure, error.cause
      assert_equal original, File.binread(@source)
      assert_raise(Errno::ENOENT) { File.lstat(output) }
      assert_raise(Errno::ENOENT) { File.lstat(error.temporary_path) }
    end
  end

  def test_unlink_enoent_does_not_hide_a_remaining_entry
    original = File.method(:unlink)
    File.define_singleton_method(:unlink) do |path|
      raise Errno::ENOENT, 'injected unlink' if File.basename(path).start_with?('taglib-plus-')

      original.call(path)
    end
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.save!(to: File.join(@dir, 'output.mp4')) }
      assert_equal :cleanup, error.code
      assert File.lstat(error.temporary_path)
    end
  ensure
    File.define_singleton_method(:unlink, original) if original
  end

  def test_post_unlink_io_failure_is_not_absence
    lstat = File.method(:lstat)
    unlink = File.method(:unlink)
    removed = nil
    failure = Errno::EIO.new('injected post-unlink lstat')
    File.define_singleton_method(:unlink) do |path|
      result = unlink.call(path)
      removed = path
      result
    end
    File.define_singleton_method(:lstat) { |path| path == removed ? (raise failure) : lstat.call(path) }
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.save!(to: File.join(@dir, 'output.mp4')) }
      assert_equal :cleanup, error.code
      assert_same failure, error.cause
    end
  ensure
    File.define_singleton_method(:lstat, lstat) if lstat
    File.define_singleton_method(:unlink, unlink) if unlink
  end

  def test_metadata_workspace_cleanup_checks_identity_and_absence
    helper = TagLib::MP4.const_get(:PurlSnapshot, false)
    raw = atom_box('meta', "\0" * 4 + atom_box('hdlr', [0, 0].pack('N2') + 'mdir' + "\0" * 12) + atom_box('ilst', ''))
    original = File.method(:unlink)
    File.define_singleton_method(:unlink) do |path|
      File.basename(path).start_with?('taglib-plus-metadata-') ? 1 : original.call(path)
    end
    error = assert_raise(TagLib::MP4::MetadataSnapshotError) do
      helper.metadata_only(raw, directory: @dir) { |path| assert File.lstat(path) }
    end
    assert_equal :cleanup, error.code
    assert File.lstat(error.issues.first[:temporary_path])
    File.define_singleton_method(:unlink, original)

    foreign = File.join(@dir, 'foreign')
    File.write(foreign, 'foreign')
    replacement_error = assert_raise(TagLib::MP4::MetadataSnapshotError) do
      helper.metadata_only(raw, directory: @dir) { |path| File.rename(foreign, path) }
    end
    assert_equal 'foreign', File.binread(replacement_error.issues.first[:temporary_path])
  ensure
    File.define_singleton_method(:unlink, original) if original
  end

  def test_public_api_reports_metadata_workspace_cleanup_path_and_keeps_original
    original = File.method(:unlink)
    retained = File.binread(@source)
    failure = Errno::EACCES.new('injected metadata unlink')
    File.define_singleton_method(:unlink) do |path|
      raise failure if File.basename(path).start_with?('taglib-plus-metadata-')

      original.call(path)
    end
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'not published' })
      error = assert_raise(API::Error) { file.save! }
      assert_equal false, error.committed
      assert_equal retained, File.binread(@source)
      # 内側metadata workspaceは外側候補と区別してissuesで返す。
      inner = error.issues.find { |row| row[:temporary_path] }
      assert_not_nil inner
      assert File.lstat(inner[:temporary_path])
      assert_raise(Errno::ENOENT) { File.lstat(error.temporary_path) }
    end
  ensure
    File.define_singleton_method(:unlink, original) if original
  end

  def test_candidate_replacement_at_creation_is_not_adopted_or_deleted
    create = Tempfile.method(:create)
    retained = File.binread(@source)
    Tempfile.define_singleton_method(:create) do |prefix, directory, **options|
      temp = create.call(prefix, directory, **options)
      if prefix.first == 'taglib-plus-'
        replacement = File.join(directory, 'injected-foreign')
        File.binwrite(replacement, 'foreign')
        File.rename(replacement, temp.path)
      end
      temp
    end
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.save!(to: File.join(@dir, 'output.mp4')) }
      assert_equal :cleanup, error.code
      assert_equal 'foreign', File.binread(error.temporary_path)
      assert_equal retained, File.binread(@source)
    end
  ensure
    Tempfile.define_singleton_method(:create, create) if create
  end

  def test_creation_api_effective_unicode_path_reaches_edit_error_and_cleanup
    create = Tempfile.method(:create)
    actual = nil
    Tempfile.define_singleton_method(:create) do |prefix, directory, **options|
      if prefix.first == 'taglib-plus-'
        temp = create.call(["taglib-plus-か\u3099-", prefix.last], directory, **options)
        actual = temp.path
        temp
      else
        create.call(prefix, directory, **options)
      end
    end
    API.open(@source) do |file|
      file.metadata = file.metadata.with(properties: { title: 'effective path' })
      file.define_singleton_method(:link_candidate) do |path, _output|
        raise 'candidate path was rebuilt' unless path.b == actual.b
        raise 'native edit missing' unless API.open(path) { |copy| copy.metadata.properties[:title] } == ['effective path']

        raise Errno::EACCES, 'injected publish'
      end
      error = assert_raise(API::Error) { file.save!(to: File.join(@dir, 'output.mp4')) }
      assert_kind_of Errno::EACCES, error.cause
      assert_equal actual.b, error.temporary_path.b
      assert_raise(Errno::ENOENT) { File.lstat(error.temporary_path) }
    end
  ensure
    Tempfile.define_singleton_method(:create, create) if create
  end
end
