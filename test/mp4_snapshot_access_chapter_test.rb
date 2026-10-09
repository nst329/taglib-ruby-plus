# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'

# 公開APIの取得・期待値生成・chapter復元を保存と異常構造まで検証する。
class MP4SnapshotAccessChapterTest < Test::Unit::TestCase
  C = TagLib::MP4::ChapterSnapshot
  S = TagLib::MP4::MetadataSnapshot

  def with_copy
    Dir.mktmpdir('snapshot-access-chapter-') do |dir|
      path = File.join(dir, 'copy.m4a')
      FileUtils.cp(File.join(__dir__, 'data/mp4.m4a'), path)
      yield path
    end
  end

  def chapter(time, title)
    TagLib::MP4::Chapter.new(start_time: time, title: title)
  end

  # mdta新設を拒否するmdir fixtureと分け、既存mdta領域の空値を検証する。
  def with_mdta
    Dir.mktmpdir('snapshot-access-mdta-') do |dir|
      path = File.join(dir, 'copy.mp4')
      _, error, status = Open3.capture3(ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg'),
        '-v', 'error', '-f', 'lavfi', '-i', 'sine=duration=1', '-c:a', 'aac',
        '-movflags', 'use_metadata_tags', '-metadata', 'title=original', path)
      assert status.success?, error
      yield path
    end
  end

  def test_access_distinguishes_absent_key_empty_key_and_empty_payload
    values = [[1, 1041, ''.b], [33, 7, "\0\xff".b], [1, 1041, ''.b]]
    snapshot = S.new(items: [['desc', :string_list, 255, ['', '日本語', '']],
                            ['covr', :cover_art_list, 255, [[13, ''.b], [99, "\0\xff".b], [13, ''.b]]]],
                     mdta: [['empty-key', 1, []], ['values', 2, values]])
    access = snapshot
    assert_nil access.mdta_values('absent')
    assert_equal [], access.mdta_values('empty-key')
    assert_equal values, access.mdta_values('values').map { |v| [v[:data_type], v[:locale], v[:data]] }
    assert_equal ['', '日本語', ''], access.item('desc')[:value]
    assert_equal 255, access.item('desc')[:atom_data_type]
    assert_nil access.item('absent')
    assert_equal [13, 99, 13], access.artworks.map { |v| v[:format] }
    assert_raise(FrozenError) { access.mdta_values('values')[1][:data] << 'x' }
    assert_raise(FrozenError) { access.item('desc')[:value][1] << 'x' }
    assert_raise(FrozenError) { access.artworks.first[:data] << 'x' }
    assert_empty snapshot.diff(snapshot.without(mdta: ['empty-key']))
    assert_not_equal access.mdta_values('empty-key'), snapshot.without(mdta: ['empty-key']).mdta_values('empty-key')
  end

  def test_detached_access_survives_save_close_and_gc
    with_mdta do |path|
      values = [[1, 1041, '日本語'.b], [33, 7, "\0\xff".b], [1, 1041, '日本語'.b]]
      snapshot = TagLib::MP4::File.open(path, false) do |file|
        file.tag.restore_metadata_snapshot(file.tag.metadata_snapshot.with(mdta: { 'typed' => values, 'empty-key' => [] }))
        assert file.save
        file.tag.metadata_snapshot
      end
      GC.start
      access = snapshot
      assert_equal values, access.mdta_values('typed').map { |v| [v[:data_type], v[:locale], v[:data]] }
      assert_equal [], access.mdta_values('empty-key')
      assert access.artworks.all? { |v| v[:data].frozen? }
    end
  end

  def test_property_expectation_matches_all_setters_and_reloaded_values
    with_mdta do |path|
      TagLib::MP4::File.open(path, false) do |file|
        initial = file.tag.metadata_snapshot.with(mdta: { 'title' => [[1, 1041, 'old'.b]] })
        TagLib::MP4::Tag::PROPERTY_ATOMS.each_key do |name|
          file.tag.restore_metadata_snapshot(initial)
          value = name == 'contentRating' ? TagLib::MP4::ContentRating.new(system: :mpaa, rating: 'R', id: 400) : '日本語'
          expected = initial.with_properties(name => value)
          file.tag.set_property(name, value)
          assert_empty expected.diff(file.tag.metadata_snapshot), name
        end
        file.tag.restore_metadata_snapshot(initial)
        updates = { title: '', copyright: '著作権'.encode(Encoding::Shift_JIS), show: '番組' }
        expected = initial.with_properties(updates)
        assert_equal [''], expected.item('©nam')[:value]
        assert_equal ['著作権'], expected.item('©cpy')[:value]
        file.tag.set_properties(updates)
        assert file.save
        TagLib::MP4::File.open(path, false) { |read| assert_empty expected.diff(read.tag.metadata_snapshot) }
      end
    end
  end

  def test_invalid_property_plan_does_not_change_snapshot_or_disk
    with_copy do |path|
      TagLib::MP4::File.open(path, false) do |file|
        initial = file.tag.metadata_snapshot
        disk = Digest::SHA256.file(path).hexdigest
        [{ title: 'valid', comment: "bad\0" }, { show: 'a', 'TVShowName' => 'b' }, { unknown: 'x' }, { title: nil }].each do |updates|
          assert_raise(ArgumentError) { initial.with_properties(updates) }
          assert initial.structure_equal?(file.tag.metadata_snapshot)
          assert_equal disk, Digest::SHA256.file(path).hexdigest
        end
      end
    end
  end

  def test_chapter_snapshot_keeps_conflicting_styles_and_copies_mutable_titles
    title = '開始'.dup
    input = chapter(0, title)
    snapshot = C.new(nero: [input], quicktime: [chapter(0, '別の開始'), chapter(500, '続き')])
    title << ' caller mutation'
    assert_equal '開始', input.title
    assert input.title.frozen?
    assert_equal [[0, '開始']], snapshot.nero.map { |c| [c.start_time, c.title] }
    assert_raise(FrozenError) { snapshot.nero.first.title << 'x' }
    with_copy do |path|
      TagLib::MP4::File.open(path, false) do |file|
        before_tag = file.tag.metadata_snapshot
        file.restore_chapter_snapshot(snapshot)
        assert_raise(TagLib::MP4::ChapterConflictError) { file.chapters }
        assert file.save
        assert before_tag.logical_equal?(file.tag.metadata_snapshot)
      end
      actual = TagLib::MP4::File.open(path, false) { |file| file.chapter_snapshot }
      GC.start
      assert snapshot.logical_equal?(actual)
      assert_empty snapshot.diff(actual)
      assert_equal %i[nero quicktime], snapshot.diff(C.new(nero: [], quicktime: [])).map { |d| d[:style] }
    end
  end

  def test_partial_chapter_restore_leaves_other_style_and_deletes_selected_empty_style
    with_copy do |path|
      TagLib::MP4::File.open(path, false) do |file|
        file.set_chapters([chapter(0, 'Nero')], style: :nero)
        file.set_chapters([chapter(0, 'QuickTime')], style: :quicktime)
        assert file.save
        file.restore_chapter_snapshot(C.new, styles: [:nero])
        assert_equal ['QuickTime'], file.quicktime_chapters.map(&:title)
        assert_empty file.nero_chapters
        assert file.save
      end
      TagLib::MP4::File.open(path, false) do |file|
        assert_equal :quicktime, file.chapter_style
        assert_equal ['QuickTime'], file.quicktime_chapters.map(&:title)
      end
    end
  end

  def test_invalid_second_chapter_style_does_not_replace_pending_first_style
    with_copy do |path|
      TagLib::MP4::File.open(path, true) do |file|
        file.set_chapters([chapter(0, 'pending')], style: :nero)
        before = file.chapter_snapshot
        disk = Digest::SHA256.file(path).hexdigest
        assert_raise(TagLib::MP4::ChapterSnapshotError) do
          C.new(nero: [chapter(0, 'new')], quicktime: [chapter(0, 'a'), chapter(0, 'b')])
        end
        assert before.logical_equal?(file.chapter_snapshot)
        assert_equal disk, Digest::SHA256.file(path).hexdigest
        invalid_destination_time = C.new(nero: [chapter(0, 'new')], quicktime: [chapter(1_000_000, 'too late')])
        error = assert_raise(TagLib::MP4::ChapterSnapshotError) { file.restore_chapter_snapshot(invalid_destination_time) }
        assert_equal :restore, error.phase
        assert before.logical_equal?(file.chapter_snapshot), '2形式目の検証失敗でも1形式目を変更しない'
        assert_equal disk, Digest::SHA256.file(path).hexdigest
        beyond_duration = C.new(nero: [chapter(10**12, 'too late')], quicktime: [])
        assert_raise(TagLib::MP4::ChapterSnapshotError) { file.restore_chapter_snapshot(beyond_duration) }
        assert before.logical_equal?(file.chapter_snapshot)
      end
    end
  end

  def test_mdta_creation_on_mdir_is_explicitly_rejected_without_changes
    with_copy do |path|
      TagLib::MP4::File.open(path, false) do |file|
        initial = file.tag.metadata_snapshot
        disk = Digest::SHA256.file(path).hexdigest
        error = assert_raise(TagLib::MP4::MetadataSnapshotError) do
          file.tag.restore_metadata_snapshot(initial.with(mdta: { 'new' => [[1, 0, ''.b]] }))
        end
        assert_not_nil error.code
        assert initial.structure_equal?(file.tag.metadata_snapshot)
        assert_equal disk, Digest::SHA256.file(path).hexdigest
      end
    end
  end

  def test_duration_validation_depends_on_audio_property_loading
    with_copy do |path|
      beyond = C.new(nero: [chapter(10**12, 'too late')], quicktime: [])
      TagLib::MP4::File.open(path, false) do |file|
        file.restore_chapter_snapshot(beyond)
        assert_equal 10**12, file.nero_chapters.first.start_time
      end
      TagLib::MP4::File.open(path, true) do |file|
        assert_raise(TagLib::MP4::ChapterSnapshotError) { file.restore_chapter_snapshot(beyond) }
      end
    end
  end

  def test_partial_nero_read_is_rejected_with_reason_before_save
    with_copy do |path|
      TagLib::MP4::File.open(path, false) do |file|
        file.set_chapters([chapter(0, 'one')], style: :nero)
        assert file.save
      end
      bytes = File.binread(path)
      name_offset = bytes.index('chpl')
      assert_not_nil name_offset
      assert_equal 1, bytes.getbyte(name_offset + 4), 'Nero version 1 fixture'
      assert_equal 1, bytes.getbyte(name_offset + 12), '宣言chapter数'
      bytes.setbyte(name_offset + 12, 2) # payloadは1件のまま、宣言数だけ2へ変更する。
      File.binwrite(path, bytes)
      TagLib::MP4::File.open(path, false) do |file|
        assert_equal :nero, file.chapter_style
        disk = Digest::SHA256.file(path).hexdigest
        assert_equal :malformed, file.chapter_diagnostics[:nero][:status]
        error = assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_snapshot }
        assert_equal :nero, error.style
        assert_match(/truncated/, error.message)
        assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal disk, Digest::SHA256.file(path).hexdigest
      end
    end
  end

  def test_nero_title_truncation_is_rejected_before_original_replacement
    with_copy do |path|
      disk = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        assert_raise(TagLib::MP4::ChapterSnapshotError) do
          C.new(nero: [chapter(0, 'a' * 256)], quicktime: [])
        end
        assert_equal disk, Digest::SHA256.file(path).hexdigest
        assert_empty file.chapter_snapshot.nero
      end
    end
  end

  def test_tag_and_chapter_verification_failure_keeps_original_and_pending_state
    with_copy do |path|
      disk = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        file.tag.set_property(:copyright, '著作権')
        expected_tag = file.tag.metadata_snapshot
        expected_chapters = C.new(nero: [chapter(0, '')], quicktime: [chapter(0, '別タイトル')])
        file.restore_chapter_snapshot(expected_chapters)
        # 正常検証後に故障を注入し、rename前の失敗契約を検証する。
        file.define_singleton_method(:verify_saved_copy) do |*args, **keywords|
          super(*args, **keywords)
          raise TagLib::MP4::MdtaSaveError.new('injected verification refusal', phase: :verify)
        end
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal :verify, error.phase
        assert_equal false, error.committed
        assert_equal disk, Digest::SHA256.file(path).hexdigest
        assert expected_tag.logical_equal?(file.tag.metadata_snapshot)
        assert expected_chapters.logical_equal?(file.chapter_snapshot)
      end
    end
  end

  def test_partial_quicktime_stts_is_rejected_with_reason
    with_copy do |path|
      TagLib::MP4::File.open(path, false) do |file|
        file.set_chapters([chapter(0, 'first'), chapter(500, 'second')], style: :quicktime)
        assert file.save
      end
      bytes = File.binread(path)
      offset = bytes.rindex('stts')
      assert_equal 2, bytes.byteslice(offset + 8, 4).unpack1('N')
      bytes[offset + 8, 4] = [3].pack('N')
      File.binwrite(path, bytes)
      TagLib::MP4::File.open(path, false) do |file|
        assert_equal %w[first second], file.quicktime_chapters.map(&:title), 'nativeの部分取得を公開snapshotでは拒否する'
        assert_equal :malformed, file.chapter_diagnostics[:quicktime][:status]
        error = assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_snapshot }
        assert_equal :quicktime, error.style
        assert_match(/stts count mismatch/, error.message)
      end
    end
  end

  def test_quicktime_corruption_is_classified_and_never_replaces_original
    mutations = {
      stsz_count: [:malformed, ->(b) { p = b.rindex('stsz'); b[p + 12, 4] = [3].pack('N') }],
      stsc_count: [:malformed, ->(b) { p = b.rindex('stsc'); b[p + 16, 4] = [3].pack('N') }],
      outside_mdat: [:malformed, ->(b) { p = b.rindex('stco'); b[p + 12, 4] = [0].pack('N') }],
      timescale: [:malformed, ->(b) { p = b.rindex('mdhd'); b[p + 16, 4] = [0].pack('N') }],
      missing_track: [:malformed, ->(b) { p = b.index('chap'); b[p + 4, 4] = [999].pack('N') }],
      text_length: [:malformed, ->(b) { p = b.rindex('stco'); offset = b[p + 12, 4].unpack1('N'); b[offset, 2] = [65_535].pack('n') }],
      sample_format: [:unsupported, ->(b) { p = b.rindex('stsd'); b[p + 16, 4] = 'tx3g' }],
      external_data: [:unsupported, ->(b) { p = b.rindex('url '); b[p + 4, 4] = [0].pack('N') }]
    }
    mutations.each do |label, (expected_status, mutate)|
      with_copy do |path|
        TagLib::MP4::File.open(path, false) do |file|
          file.restore_chapter_snapshot(C.new(quicktime: [chapter(0, 'first'), chapter(500, 'second')]))
          assert file.save
        end
        bytes = File.binread(path)
        mutate.call(bytes)
        File.binwrite(path, bytes)
        disk = Digest::SHA256.file(path).hexdigest
        TagLib::MP4::File.open(path, false) do |file|
          report = file.chapter_diagnostics
          assert_equal expected_status, report[:quicktime][:status], label
          assert_not_nil report[:quicktime][:reason], label
          assert_raise(FrozenError) { report[:quicktime][:reason] << 'x' }
          assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_snapshot }
          file.tag.set_property(:copyright, 'pending')
          error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
          assert_equal false, error.committed
          assert_equal ['pending'], file.tag.property_values(:copyright)
          assert_equal disk, Digest::SHA256.file(path).hexdigest
        end
      end
    end
  end

  def test_nonzero_quicktime_start_and_detached_diff_fields
    expected = C.new(nero: [chapter(500, '開始')], quicktime: [chapter(500, '別の開始'), chapter(800, '続き')])
    with_copy do |path|
      TagLib::MP4::File.open(path, false) { |file| file.restore_chapter_snapshot(expected); assert file.save }
      actual = TagLib::MP4::File.open(path, false, &:chapter_snapshot)
      GC.start
      assert actual.quicktime.first.title.frozen?
      assert_empty expected.diff(actual)
      assert expected.logical_equal?(actual)
      title_change = C.new(nero: [chapter(500, 'new')], quicktime: expected.quicktime)
      assert_equal [:title], expected.diff(title_change).first[:changes]
      time_change = C.new(nero: [chapter(600, '開始')], quicktime: expected.quicktime)
      assert_equal [:start_time], expected.diff(time_change).first[:changes]
      assert_equal false, expected.logical_equal?(time_change)
      assert_raise(FrozenError) { expected.diff(time_change).first[:before].first << 'x' }
      reordered = C.new(nero: expected.nero, quicktime: [chapter(500, '続き'), chapter(800, '別の開始')])
      assert_equal [:title, :order], expected.diff(reordered).first[:changes]
    end
  end

  def test_public_snapshot_input_limits_and_lookup_validation
    snapshot = S.new(items: [], mdta: [])
    [nil, :key, '', "bad\0", 'key'.b].each do |key|
      assert_raise(TagLib::MP4::MetadataSnapshotError) { snapshot.mdta_values(key) }
      assert_raise(TagLib::MP4::MetadataSnapshotError) { snapshot.item(key) }
    end
    [nil, [], { title: 'good', comment: nil }].each do |updates|
      assert_raise(ArgumentError) { snapshot.with_properties(updates) }
    end
    assert_raise(TagLib::MP4::ChapterSnapshotError) { C.new(nero: Array.new(256) { |i| chapter(i, '') }) }
    assert_raise(TagLib::MP4::ChapterSnapshotError) { C.new(quicktime: [chapter(0, 'a' * 65_536)]) }
    assert_raise(TagLib::MP4::ChapterSnapshotError) { C.new(nero: [chapter(0x7fff_ffff_ffff_ffff, '')]) }
    assert_raise(TagLib::MP4::ChapterSnapshotError) { C.new(quicktime: [chapter(0, ''), chapter(500, 'title')]) }
    with_copy do |path|
      TagLib::MP4::File.open(path, false) do |file|
        before = file.chapter_snapshot
        [nil, [:both], [:nero, :nero]].each do |styles|
          assert_raise(TagLib::MP4::ChapterSnapshotError) { file.restore_chapter_snapshot(C.new, styles: styles) }
          assert before.logical_equal?(file.chapter_snapshot)
        end
      end
    end
  end

  def test_nero_unknown_header_precision_and_invalid_utf8_are_rejected
    mutations = {
      version: [:unsupported, ->(bytes, p) { bytes.setbyte(p + 4, 2) }],
      flags: [:unsupported, ->(bytes, p) { bytes.setbyte(p + 5, 1) }],
      reserved: [:unsupported, ->(bytes, p) { bytes.setbyte(p + 8, 1) }],
      precision: [:unsupported, ->(bytes, p) { bytes[p + 13, 8] = [1].pack('q>') }],
      title: [:malformed, ->(bytes, p) { bytes.setbyte(p + 22, 0xff) }]
    }
    mutations.each do |label, (status, mutate)|
      with_copy do |path|
        TagLib::MP4::File.open(path, false) do |file|
          file.restore_chapter_snapshot(C.new(nero: [chapter(0, 'one')]))
          assert file.save
        end
        bytes = File.binread(path)
        mutate.call(bytes, bytes.index('chpl'))
        File.binwrite(path, bytes)
        disk = Digest::SHA256.file(path).hexdigest
        TagLib::MP4::File.open(path, false) do |file|
          assert_equal status, file.chapter_diagnostics[:nero][:status], label
          error = assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_snapshot }
          assert_equal status, error.code
          assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
          assert_equal disk, Digest::SHA256.file(path).hexdigest
        end
      end
    end
  end

  def test_incomplete_temporary_chapters_fail_in_verify_phase_and_keep_pending_state
    with_copy do |path|
      disk = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        expected = C.new(nero: [chapter(0, 'pending')])
        file.restore_chapter_snapshot(expected)
        # 実際の一時出力を不完全にし、再読込拒否が原本置換より前に働くことを確認する。
        file.define_singleton_method(:save_temporary_copy) do |temporary_path, **keywords|
          super(temporary_path, **keywords)
          bytes = ::File.binread(temporary_path)
          bytes.setbyte(bytes.index('chpl') + 12, 2)
          ::File.binwrite(temporary_path, bytes)
        end
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal :verify, error.phase
        assert_equal false, error.committed
        assert_equal disk, Digest::SHA256.file(path).hexdigest
        assert expected.logical_equal?(file.chapter_snapshot)
        assert_empty Dir.glob("#{path}.taglib-mdta-*")
      end
    end
  end
end
