# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_investigation_fixture'

# 製品APIの原本不変・raw保持・時間profile・保存失敗を独立fixtureで検証する。
class MP4AtomRepairTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  MOVIE_DURATION = 1_605_653_349_300

  def setup
    @dir = Dir.mktmpdir('mp4-atom-repair-')
    @path = File.join(@dir, 'fixture.mp4')
    _out, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1', '-f', 'lavfi', '-i', 'sine=duration=1',
      '-c:v', 'mpeg4', '-c:a', 'aac', '-metadata', 'title=fixture', @path)
    assert status.success?, error
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def seed_timing
    TagLib::MP4::File.open(@path, false) do |file|
      file.set_chapters(Array.new(15) { |i| TagLib::MP4::Chapter.new((i + 1) * 50, '') }, style: :quicktime)
      assert file.save_chapters
    end
    inject_chapter_timing(@path, movie_scale: 441_000_000, movie_duration: MOVIE_DURATION,
      track_duration: 3_640_937, edit_rows: [[MOVIE_DURATION & 0xffffffff, 0, 65_536]])
  end

  def digest
    Digest::SHA256.file(@path).hexdigest
  end

  def test_explicit_timing_repair_preserves_samples_and_survives_regular_save
    seed_timing
    original = digest
    TagLib::MP4::File.open(@path, false) do |file|
      before = file.chapter_snapshot
      media = file.send(:mdat_payload_signature, @path)
      id = file.chapter_timing_diagnostics.first[:track_id]
      result = file.repair_native_chapter_timing(track_id: id, profile: :taglib_full_movie)
      assert_equal :planned, result[:status]
      assert_equal MOVIE_DURATION, result[:after][:tkhd_duration]
      assert_equal original, digest
      assert file.save_chapters
      assert_equal before, file.chapter_snapshot
      assert_equal media, file.send(:mdat_payload_signature, @path)
      assert_empty file.chapter_timing_diagnostics.first[:observations]
      file.tag.title = 'after timing repair'
      assert file.save
      assert_equal before, file.chapter_snapshot
    end
    assert_empty Dir.glob("#{@path}.taglib-mdta-*")
  end

  def test_profile_requires_explicit_intent_and_rejects_normal_short_edit
    seed_timing
    inject_chapter_timing(@path, movie_scale: 441_000_000, movie_duration: MOVIE_DURATION,
      track_duration: MOVIE_DURATION & 0xffffffff, edit_rows: [[MOVIE_DURATION & 0xffffffff, 0, 65_536]])
    original = digest
    TagLib::MP4::File.open(@path, false) do |file|
      id = file.chapter_timing_diagnostics.first[:track_id]
      assert_raise(ArgumentError) { file.repair_native_chapter_timing(track_id: id, profile: :guess) }
      assert_equal :not_applicable, file.repair_native_chapter_timing(track_id: id, profile: :taglib_full_movie)[:status]
      assert_nil file.instance_variable_get(:@chapter_timing_repair)
    end
    assert_equal original, digest
  end

  def test_time_repair_rejects_pending_tags_and_later_source_changes
    seed_timing
    TagLib::MP4::File.open(@path, false) do |file|
      id = file.chapter_timing_diagnostics.first[:track_id]
      file.tag.title = 'pending'
      assert_raise(TagLib::MP4::ChapterReferenceError) { file.repair_native_chapter_timing(track_id: id, profile: :taglib_full_movie) }
    end
    TagLib::MP4::File.open(@path, false) do |file|
      file.repair_native_chapter_timing(track_id: file.chapter_timing_diagnostics.first[:track_id], profile: :taglib_full_movie)
      File.open(@path, 'ab') { |output| output.write(atom_box('free', 'external')) }
      changed = digest
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
      assert_equal :prepare, error.phase
      assert_equal changed, digest
    end
  end

  def test_unindexed_save_preserves_raw_duplicates_and_normal_tag_changes
    seed_timing
    TagLib::MP4::File.open(@path, false) do |file|
      file.repair_native_chapter_timing(track_id: file.chapter_timing_diagnostics.first[:track_id], profile: :taglib_full_movie)
      assert file.save_chapters
    end
    inject_metadata(@path, keys: %w[first second], indices: [0, 0, 0])
    File.chmod(0o600, @path)
    TagLib::MP4::File.open(@path, false) do |file|
      chapters = file.chapter_snapshot
      media = file.send(:mdat_payload_signature, @path)
      original = digest
      file.tag.title = 'safe regular title'
      assert_equal original, digest
      assert file.save_preserving_unindexed_mdta
      assert_equal 'safe regular title', file.tag.title
      assert_equal 0o600, File.stat(@path).mode & 0o777
      assert_equal [0, 0, 0], file.tag.metadata_diagnostics.issues.select { |i| i[:code] == :invalid_index }.map { |i| i[:key_index] }
      assert_raise(TagLib::MP4::MetadataSnapshotError) { file.tag.metadata_snapshot }
      assert_equal chapters, file.chapter_snapshot
      assert_equal media, file.send(:mdat_payload_signature, @path)
      file.tag.title = 'second save'
      assert file.save_preserving_unindexed_mdta
      assert_equal chapters, file.chapter_snapshot
    end
  end

  def test_unindexed_save_rejects_out_of_range_mixed_and_interleaved_indices
    [[3], [0, 1], [0, 0, 2], [1, 0]].each do |indices|
      inject_metadata(@path, keys: %w[first second], indices: indices)
      original = digest
      TagLib::MP4::File.open(@path, false) do |file|
        file.tag.title = 'pending title'
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_preserving_unindexed_mdta }
        assert_equal :prepare, error.phase
        assert_equal 'pending title', file.tag.title
      end
      assert_equal original, digest
    end
  end

  def test_raw_drop_reorder_duplicate_and_payload_changes_fail_verification
    [:drop, :reverse, :duplicate, :payload].each do |fault|
      inject_metadata(@path, keys: %w[first second], indices: [0, 0])
      original = digest
      fixture = self
      TagLib::MP4::File.open(@path, false) do |file|
        original_reinsert = file.method(:reinsert_unindexed_copy)
        file.define_singleton_method(:reinsert_unindexed_copy) do |path, plan|
          original_reinsert.call(path, plan)
          fixture.edit_fixture(path) do |moov|
            list = fixture.fixture_child(fixture.fixture_child(fixture.fixture_child(moov, 'udta'), 'meta'), 'ilst')[:children]
            case fault
            when :drop then list.delete_at(1)
            when :reverse then list[0, 2] = list.first(2).reverse
            when :duplicate then list.insert(0, list.first.dup)
            when :payload then list.first[:data] = list.first[:data].dup.tap { |b| b.setbyte(b.bytesize - 1, 120) }
            end
          end
        end
        file.tag.title = 'pending'
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_preserving_unindexed_mdta }
        assert_equal :verify, error.phase
        assert_equal false, error.committed
        assert_equal 'pending', file.tag.title
      end
      assert_equal original, digest
      assert_empty Dir.glob("#{@path}.taglib-mdta-*")
    end
  end

  def test_unindexed_native_write_reinsert_verify_failures_keep_original_and_allow_retry
    [:write_unindexed_regular_copy, :reinsert_unindexed_copy, :verify_unindexed_copy].zip([:taglib_save, :reinsert, :verify]).each do |method, phase|
      inject_metadata(@path, keys: %w[first second], indices: [0, 0])
      original = digest
      TagLib::MP4::File.open(@path, false) do |file|
        file.tag.title = 'pending'
        file.define_singleton_method(method) { |*_args| raise IOError, 'injected failure' }
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_preserving_unindexed_mdta }
        assert_equal phase, error.phase
        assert_equal original, digest
        assert_equal 'pending', file.tag.title
        file.singleton_class.remove_method(method)
        assert file.save_preserving_unindexed_mdta
      end
      assert_empty Dir.glob("#{@path}.taglib-mdta-*")
    end
  end
  def test_timing_growth_and_free_consumption_preserve_stco_and_co64_with_both_moov_positions
    [false, true].product([:stco, :co64], [0, 128]).each do |faststart, width, free_size|
      File.unlink(@path)
      _out, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
        '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1', '-f', 'lavfi', '-i', 'sine=duration=1',
        '-c:v', 'mpeg4', '-c:a', 'aac', '-movflags', faststart ? '+faststart' : '+use_metadata_tags', @path)
      assert status.success?, error
      seed_timing
      edit_fixture(@path) do |moov|
        moov[:children].reject! { |node| node[:type] == 'free' }
        moov[:children] << { type: 'free', data: "\0".b * (free_size - 8) } if free_size.positive?
        chapter = fixture_tracks(moov).find { |t| fixture_child(fixture_child(t, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text' }
        chapter_offsets = fixture_child(fixture_child(fixture_child(fixture_child(chapter, 'mdia'), 'minf'), 'stbl'), 'stco')
        each_fixture_atom([moov]) do |node|
          next unless node[:type] == 'stco' && width == :co64 && !node.equal?(chapter_offsets)
          node[:type] = 'co64'
          node[:data] = node[:data].byteslice(0, 8) + node[:data].byteslice(8..).unpack('N*').pack('Q>*')
        end
      end
      size = File.size(@path)
      moov_before, start, boundary = read_fixture_moov(@path)
      TagLib::MP4::File.open(@path, false) do |file|
        signature = file.send(:mdat_payload_signature, @path)
        file.repair_native_chapter_timing(track_id: file.chapter_timing_diagnostics.first[:track_id], profile: :taglib_full_movie)
        assert file.save_chapters
        assert_equal signature, file.send(:mdat_payload_signature, @path)
        assert_equal 15, file.chapter_snapshot.quicktime.size
      end
      _moov_after, after_start, after_boundary = read_fixture_moov(@path)
      assert_equal start, after_start
      assert_equal free_size.zero? ? 20 : 0, after_boundary - boundary
      assert_equal size + (free_size.zero? ? 20 : 0), File.size(@path)
      assert_equal 'moov', moov_before[:type]
    end
  end

  def test_native_writer_movie_units_and_duration_width_boundaries
    [[48_000, 48_000, 0], [2000, 0xffffffff, 0], [2000, 0x100000000, 1]].each do |scale, duration, version|
      edit_fixture(@path) do |moov|
        movie = fixture_child(moov, 'mvhd')
        data = movie[:data]
        suffix = data.getbyte(0) == 1 ? 32 : 20
        movie[:data] = [0x01000000].pack('N') + [0, 0].pack('Q>2') + [scale].pack('N') + [duration].pack('Q>') + data.byteslice(suffix..)
      end
      TagLib::MP4::File.open(@path, false) do |file|
        file.set_chapters([TagLib::MP4::Chapter.new(0, 'chapter')], style: :quicktime)
        assert file.save_chapters
        row = file.chapter_timing_diagnostics.first
        assert_equal({ version: version, duration: duration }, row[:track_header])
        assert_equal duration, row[:edits].first[:segment_duration]
        assert_equal version, row[:edits].first[:version]
        assert_equal (duration * 1000 + scale / 2) / scale, row[:media][:duration]
        assert_empty row[:observations]
      end
    end
  end

  def test_native_writer_rejects_unknown_zero_scale_and_media_overflow_before_replacement
    [[0, MOVIE_DURATION], [1000, 0xffffffffffffffff], [1, MOVIE_DURATION]].each do |scale, duration|
      edit_fixture(@path) do |moov|
        movie = fixture_child(moov, 'mvhd')
        data = movie[:data]
        suffix = data.getbyte(0) == 1 ? 32 : 20
        movie[:data] = [0x01000000].pack('N') + [0, 0].pack('Q>2') + [scale].pack('N') + [duration].pack('Q>') + data.byteslice(suffix..)
      end
      original = digest
      TagLib::MP4::File.open(@path, false) do |file|
        file.set_chapters([TagLib::MP4::Chapter.new(0, 'chapter')], style: :quicktime)
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
        assert_equal :taglib_save, error.phase
        assert_equal false, error.committed
      end
      assert_equal original, digest
    end
  end

  def test_metadata_replace_cleanup_and_reopen_failures_report_commit_state
    [:replace, :cleanup, :reopen].each do |phase|
      inject_metadata(@path, keys: %w[first second], indices: [0, 0])
      original_digest = digest
      file = TagLib::MP4::File.new(@path, false)
      file.tag.title = 'pending'
      original_mv, original_rm = FileUtils.method(:mv), FileUtils.method(:rm_f)
      begin
        if phase == :replace
          FileUtils.define_singleton_method(:mv) do |from, to|
            raise IOError, 'replace fault' if to == file.name
            original_mv.call(from, to)
          end
        elsif phase == :cleanup
          file.define_singleton_method(:write_unindexed_regular_copy) { |*_args| raise IOError, 'write fault' }
          FileUtils.define_singleton_method(:rm_f) { |*_args| raise IOError, 'cleanup fault' }
        else
          file.define_singleton_method(:initialize) { |*_args| raise IOError, 'reopen fault' }
        end
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_preserving_unindexed_mdta }
        assert_equal phase, error.phase
        assert_equal phase == :reopen, error.committed
        if phase == :cleanup
          assert_equal :taglib_save, error.cause.phase
          assert_include error.message, '.taglib-mdta-'
        end
        assert_equal original_digest, digest unless phase == :reopen
      ensure
        FileUtils.define_singleton_method(:mv, original_mv)
        FileUtils.define_singleton_method(:rm_f, original_rm)
        file.close unless phase == :reopen
        Dir.glob("#{@path}.taglib-mdta-*").each { |path| FileUtils.rm_f(path) }
      end
      if phase == :reopen
        TagLib::MP4::File.open(@path, false) { |read| assert_equal 'pending', read.tag.title }
      end
    end
  end

  def test_real_file_full_copy_repair_then_preserving_metadata_save
    source = ENV['MP4_REPAIR_REAL_FILE']
    omit 'MP4_REPAIR_REAL_FILE is required' unless source
    source_digest = Digest::SHA256.file(source).hexdigest
    FileUtils.cp(source, @path)
    TagLib::MP4::File.open(@path, false) do |file|
      media = file.send(:mdat_payload_signature, @path)
      assert_equal 3, file.remove_dangling_chapter_references.size
      assert file.save_chapters
      assert_equal [[2, 0, 0, 4]], file.chapter_reference_diagnostics.map { |r| r.values_at(:source_track_id, :tref_index, :reference_index, :target_track_id) }
      before = file.chapter_snapshot
      assert_equal 15, before.quicktime.size
      assert_equal :planned, file.repair_native_chapter_timing(track_id: 4, profile: :taglib_full_movie)[:status]
      assert file.save_chapters
      assert_empty file.chapter_timing_diagnostics.first[:observations]
      assert_equal before, file.chapter_snapshot
      file.tag.title = 'copy-only regular tag verification'
      assert file.save_preserving_unindexed_mdta
      assert_equal before, file.chapter_snapshot
      assert_equal media, file.send(:mdat_payload_signature, @path)
      assert_equal 21, file.tag.metadata_diagnostics.issues.count { |i| i[:code] == :invalid_index }
      file.tag.title = 'second copy-only save'
      assert file.save_preserving_unindexed_mdta
      assert_equal before, file.chapter_snapshot
    end
    out, error, status = Open3.capture3(ENV.fetch('FFPROBE', 'ffprobe'), '-v', 'error', '-show_chapters', '-of', 'json', @path)
    assert status.success?, error
    require 'json'
    assert_equal 16, JSON.parse(out).fetch('chapters').size
    assert_equal source_digest, Digest::SHA256.file(source).hexdigest
    assert_empty Dir.glob("#{@path}.taglib-mdta-*")
  end

  def test_invalid_keys_unknown_item_and_edited_legacy_alias_are_rejected
    [:keys, :unknown, :alias].each do |kind|
      inject_metadata(@path, keys: %w[first second], indices: [0, 0])
      if kind != :alias
        edit_fixture(@path) do |moov|
          meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
          if kind == :keys
            fixture_child(meta, 'keys')[:data][4, 4] = [3].pack('N')
          else
            fixture_child(meta, 'ilst')[:children] << { type: 'zzzz', data: atom_box('data', [1, 0].pack('N2') + 'unknown') }
          end
        end
      end
      original = digest
      TagLib::MP4::File.open(@path, false) do |file|
        if kind == :alias
          next unless file.tag.item_map.to_a.any? { |key, _v| key.empty? }
          file.tag.remove_item('')
          file.tag.item_map.insert('', TagLib::MP4::Item.from_string_list(['edited alias']))
        end
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_preserving_unindexed_mdta }
        assert_equal :prepare, error.phase
      end
      assert_equal original, digest
    end
  end

  def test_offset_width_overflow_is_explicitly_rejected
    editor = TagLib::MP4.const_get(:MP4AtomEditor).allocate
    editor.instance_variable_set(:@moov, { end_offset: 100 })
    [[4, 0xffffffff], [8, 0xffffffffffffffff]].each do |width, maximum|
      error = assert_raise(TagLib::MP4::ChapterReferenceError) do
        editor.send(:render_offsets, [[0, 1].pack('N2'), [maximum], width], 20)
      end
      assert_equal :unsupported, error.code
      assert_equal [maximum].pack(width == 4 ? 'N*' : 'Q>*'), editor.send(:render_offsets, [[0, 1].pack('N2'), [maximum - 20], width], 20).byteslice(8..)
    end
  end

  def test_chapter_co64_remains_an_explicit_reader_limit
    seed_timing
    edit_fixture(@path) do |moov|
      chapter = fixture_tracks(moov).find { |t| fixture_child(fixture_child(t, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text' }
      offsets = fixture_child(fixture_child(fixture_child(fixture_child(chapter, 'mdia'), 'minf'), 'stbl'), 'stco')
      offsets[:type] = 'co64'
      offsets[:data] = offsets[:data].byteslice(0, 8) + offsets[:data].byteslice(8..).unpack('N*').pack('Q>*')
    end
    original = digest
    TagLib::MP4::File.open(@path, false) do |file|
      error = assert_raise(TagLib::MP4::ChapterSnapshotError) do
        file.repair_native_chapter_timing(track_id: file.chapter_timing_diagnostics.first[:track_id], profile: :taglib_full_movie)
      end
      assert_equal :unsupported, error.code
      assert_nil file.instance_variable_get(:@chapter_timing_repair)
    end
    assert_equal original, digest
  end

  def test_timing_edit_preserves_creation_flags_matrix_and_unrelated_time_headers
    seed_timing
    edit_fixture(@path) do |moov|
      chapter = fixture_tracks(moov).find { |t| fixture_child(fixture_child(t, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text' }
      data = fixture_child(chapter, 'tkhd')[:data]
      data[4, 8] = [12345, 67890].pack('N2')
      data[32, 4] = [7, 8].pack('n2')
    end
    before, = read_fixture_moov(@path)
    chapter_before = fixture_tracks(before).find { |t| fixture_child(fixture_child(t, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text' }
    old_header = fixture_child(chapter_before, 'tkhd')[:data]
    TagLib::MP4::File.open(@path, false) do |file|
      file.repair_native_chapter_timing(track_id: file.chapter_timing_diagnostics.first[:track_id], profile: :taglib_full_movie)
      assert file.save_chapters
    end
    after, = read_fixture_moov(@path)
    chapter_after = fixture_tracks(after).find { |t| fixture_child(fixture_child(t, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text' }
    header = fixture_child(chapter_after, 'tkhd')[:data]
    assert_equal old_header.unpack1('N') & 0xffffff, header.unpack1('N') & 0xffffff
    assert_equal [12345, 67890], header.byteslice(4, 16).unpack('Q>2')
    assert_equal old_header.byteslice(12, 8), header.byteslice(20, 8)
    assert_equal old_header.byteslice(24..), header.byteslice(36..)
    assert_equal fixture_child(before, 'mvhd')[:data], fixture_child(after, 'mvhd')[:data]
    assert_equal fixture_child(fixture_child(chapter_before, 'mdia'), 'mdhd')[:data], fixture_child(fixture_child(chapter_after, 'mdia'), 'mdhd')[:data]
  end

end
