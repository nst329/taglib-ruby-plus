# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'
require 'json'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_investigation_fixture'

# 公開APIを独立fixture・実際のタグ保存・ffprobe出力に対して検証する。
class MP4ChapterSampleSnapshotTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  MOVIE_DURATION = 1_605_653_349_300

  def setup
    @dir = Dir.mktmpdir('chapter-samples-')
    @path = File.join(@dir, 'fixture.mp4')
    _out, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1',
      '-f', 'lavfi', '-i', 'sine=duration=1', '-c:v', 'mpeg4', '-c:a', 'aac', @path)
    assert status.success?, error
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def seed(rows = [[100, 'first'], [300, ''], [600, 'last'], [800, '']])
    TagLib::MP4::File.open(@path, false) do |file|
      file.set_chapters(rows.map { |time, title| TagLib::MP4::Chapter.new(time, title) }, style: :quicktime)
      assert file.save_chapters
    end
  end

  def snapshot
    TagLib::MP4::File.open(@path, false, &:chapter_sample_snapshot)
  end

  def chapter_track(moov)
    fixture_tracks(moov).find do |track|
      fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'text'
    end
  end

  def sample_table(track)
    fixture_child(fixture_child(fixture_child(track, 'mdia'), 'minf'), 'stbl')
  end

  def digest
    Digest::SHA256.file(@path).hexdigest
  end

  def test_absent_and_padding_rules_with_exact_ticks_and_immutable_values
    assert_nil snapshot
    seed
    value = snapshot
    assert_equal [0, 100, 300, 600, 800], value.samples.map { |row| row[:start_ticks] }
    assert_equal [100, 200, 300, 200, 200], value.samples.map { |row| row[:duration_ticks] }
    assert_equal ['', 'first', '', 'last', ''], value.samples.map { |row| row[:title] }
    assert_equal [true, false, false, false, false], value.samples.map { |row| row[:padding] }
    assert_equal (0..4).to_a, value.samples.map { |row| row[:sample_index] }
    assert_equal 1000, value.media_timescale
    assert_equal 1000, value.media_duration
    assert_not_equal value.track_id, value.source_track_id
    assert value.frozen?
    assert_raise(FrozenError) { value.samples.first[:title] << 'changed' }
    assert_raise(FrozenError) { value.samples << {} }
    assert_raise(FrozenError) { value.movie[:duration] = 3 }
    assert_equal 64, value.preservation_signature.size
    assert_equal 64, value.samples.first[:payload_sha256].size
    assert_equal value, value.require_ffprobe_comparable!
    seed([[0, 'first'], [500, '']])
    assert_equal [false, false], snapshot.samples.map { |row| row[:padding] }
    seed([[0, '']])
    assert_equal [false], snapshot.samples.map { |row| row[:padding] }
  end

  def test_submillisecond_media_ticks_are_not_rounded
    seed([[0, 'first'], [500, 'last']])
    edit_fixture(@path) do |moov|
      track = chapter_track(moov)
      fixture_child(fixture_child(track, 'mdia'), 'mdhd')[:data][12, 8] = [3000, 3000].pack('N2')
      fixture_child(sample_table(track), 'stts')[:data] = [0, 2, 1, 1001, 1, 1999].pack('N6')
    end
    assert_equal 3000, snapshot.media_timescale
    assert_equal [0, 1001], snapshot.samples.map { |row| row[:start_ticks] }
    assert_equal [1001, 1999], snapshot.samples.map { |row| row[:duration_ticks] }
  end

  def test_identity_without_edit_and_co64
    seed
    before = snapshot
    edit_fixture(@path) do |moov|
      track = chapter_track(moov)
      track[:children].reject! { |node| node[:type] == 'edts' }
      offsets = fixture_child(sample_table(track), 'stco')
      offsets[:type] = 'co64'
      offsets[:data] = offsets[:data].byteslice(0, 8) + offsets[:data].byteslice(8..).unpack('N*').pack('Q>*')
    end
    after = snapshot
    assert_nil after.edit
    assert before.preserved_equal?(after)
    assert_equal :complete, after.ffprobe_comparison[:status]
  end

  def test_timing_repair_pending_and_tag_save_preserve_all_samples
    seed(Array.new(15) { |i| [(i + 1) * 50, "chapter-#{i}"] })
    inject_chapter_timing(@path, movie_scale: 441_000_000, movie_duration: MOVIE_DURATION,
      track_duration: 3_640_937, edit_rows: [[MOVIE_DURATION & 0xffffffff, 0, 65_536]])
    before = snapshot
    assert_equal :clipped, before.ffprobe_comparison[:status]
    assert_raise(TagLib::MP4::ChapterSnapshotError) { before.require_ffprobe_comparable! }
    TagLib::MP4::File.open(@path, false) do |file|
      result = file.repair_native_chapter_timing(track_id: before.track_id, profile: :taglib_full_movie)
      assert_equal :planned, result[:status]
      pending = file.instance_variable_get(:@chapter_timing_repair)
      assert before.preserved_equal?(file.chapter_sample_snapshot)
      assert_same pending, file.instance_variable_get(:@chapter_timing_repair)
      assert file.save_chapters
      after = file.chapter_sample_snapshot
      assert before.preserved_equal?(after)
      assert_equal :complete, after.ffprobe_comparison[:status]
      assert_equal 1, after.edit[:version]
      file.tag.title = 'large-' + 'title' * 10_000
      assert before.preserved_equal?(file.chapter_sample_snapshot)
      assert file.save
      assert before.preserved_equal?(file.chapter_sample_snapshot)
    end
    verify_ffprobe(snapshot)
  end

  # ffprobeの整数時刻とtime_baseを有理数で比較し、表示用小数を期待値に使わない。
  def verify_ffprobe(value)
    value.require_ffprobe_comparable!
    output, error, status = Open3.capture3(ENV.fetch('FFPROBE', 'ffprobe'), '-v', 'error',
      '-show_chapters', '-of', 'json', @path)
    assert status.success?, error
    chapters = JSON.parse(output).fetch('chapters')
    assert_equal value.samples.size, chapters.size
    value.samples.zip(chapters).each do |sample, chapter|
      numerator, denominator = chapter.fetch('time_base').split('/').map(&:to_i)
      assert_equal Rational(sample[:start_ticks], value.media_timescale), Rational(chapter.fetch('start') * numerator, denominator)
      assert_equal Rational(sample[:start_ticks] + sample[:duration_ticks], value.media_timescale), Rational(chapter.fetch('end') * numerator, denominator)
      assert_equal sample[:title], chapter.fetch('tags', {}).fetch('title', '')
    end
  end

  def test_pending_chapter_edits_do_not_change_saved_sample_snapshot
    seed
    before = snapshot
    original = digest
    TagLib::MP4::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'pending')], style: :quicktime)
      pending = file.instance_variable_get(:@chapter_changes)
      assert before.preserved_equal?(file.chapter_sample_snapshot)
      assert_same pending, file.instance_variable_get(:@chapter_changes)
      assert_equal 'pending', file.chapter_snapshot.quicktime.first.title
    end
    assert_equal original, digest
  end

  def test_payload_change_and_order_change_are_detected_without_offsets
    seed([[0, 'aaa'], [300, 'bbb'], [600, 'ccc']])
    before = snapshot
    moov, = read_fixture_moov(@path)
    stco = fixture_child(sample_table(chapter_track(moov)), 'stco')
    first = stco[:data].byteslice(8, 4).unpack1('N')
    File.open(@path, 'r+b') { |io| io.seek(first + 2); io.write('bbb'); io.seek(first + 19); io.write('aaa') }
    after = snapshot
    assert_equal ['bbb', 'aaa', 'ccc'], after.samples.map { |row| row[:title] }
    assert_false before.preserved_equal?(after)
    assert_not_equal before.samples.first[:payload_sha256], after.samples.first[:payload_sha256]
    File.open(@path, 'r+b') { |io| io.seek(first + 2); io.write('xyz') }
    assert_false after.preserved_equal?(snapshot)
  end

  def test_signature_includes_payload_modifier_not_only_title
    seed([[0, 'same']])
    before = snapshot
    moov, = read_fixture_moov(@path)
    offset = fixture_child(sample_table(chapter_track(moov)), 'stco')[:data].byteslice(8, 4).unpack1('N')
    bytes = File.open(@path, 'rb') { |io| io.seek(offset); io.read(before.samples.first[:payload_size]) }
    assert_equal Digest::SHA256.hexdigest(bytes), before.samples.first[:payload_sha256]
    assert_equal 18, bytes.bytesize
    edit_fixture(@path) do |movie|
      fixture_child(sample_table(chapter_track(movie)), 'stsz')[:data] = [0, 6, 1].pack('N3')
    end
    after = snapshot
    assert_equal before.samples.first[:title], after.samples.first[:title]
    assert_equal before.samples.first[:duration_ticks], after.samples.first[:duration_ticks]
    assert_equal Digest::SHA256.hexdigest([4].pack('n') + 'same'), after.samples.first[:payload_sha256]
    assert_false before.preserved_equal?(after)
  end

  def test_invalid_tables_and_edits_fail_without_modifying_file_or_pending
    seed
    FileUtils.copy_file(@path, File.join(@dir, 'baseline.mp4'))
    mutations = {
      stts: ->(track, table) { fixture_child(table, 'stts')[:data] = [0, 1, 99, 1].pack('N4') },
      zero_delta: ->(track, table) { fixture_child(table, 'stts')[:data] = [0, 1, 5, 0].pack('N4') },
      mdhd: ->(track, table) { fixture_child(fixture_child(track, 'mdia'), 'mdhd')[:data][16, 4] = [7].pack('N') },
      stsz: ->(track, table) { fixture_child(table, 'stsz')[:data] = [0, 0, 99].pack('N3') },
      stsc: ->(track, table) { fixture_child(table, 'stsc')[:data] = [0, 1, 2, 5, 1].pack('N5') },
      stco: ->(track, table) { fixture_child(table, 'stco')[:data] = [0, 1, 1].pack('N3') },
      co64: ->(track, table) { fixture_child(table, 'stco').merge!(type: 'co64', data: [0, 1].pack('N2') + 'short') },
      both_offsets: ->(track, table) { table[:children] << { type: 'co64', data: [0, 0].pack('N2') } },
      trim: ->(track, table) { fixture_child(fixture_child(track, 'edts'), 'elst')[:data][12, 4] = [1].pack('N') },
      rate: ->(track, table) { fixture_child(fixture_child(track, 'edts'), 'elst')[:data][16, 4] = [0].pack('N') },
      multiple_edits: ->(track, table) { fixture_child(fixture_child(track, 'edts'), 'elst')[:data] = [0, 2, 500, 0, 65_536, 500, 0, 65_536].pack('N8') },
      duplicate_chap: ->(track, table) { },
      duplicate_track: ->(track, table) { }
    }
    mutations.each do |name, mutation|
      FileUtils.copy_file(File.join(@dir, 'baseline.mp4'), @path)
      edit_fixture(@path) do |moov|
        track = chapter_track(moov)
        mutation.call(track, sample_table(track))
        source = fixture_tracks(moov).find { |t| fixture_child(t, 'tref') }
        if name == :duplicate_chap
          tref = fixture_child(source, 'tref')
          tref[:children] << fixture_child(tref, 'chap').dup
        elsif name == :duplicate_track
          moov[:children] << track.dup
        end
      end
      original = digest
      TagLib::MP4::File.open(@path, false) do |file|
        file.tag.title = 'pending'
        pending = file.instance_variable_get(:@chapter_changes)
        assert_raise(TagLib::MP4::ChapterSnapshotError, name.to_s) { file.chapter_sample_snapshot }
        assert_same pending, file.instance_variable_get(:@chapter_changes)
        assert_equal 'pending', file.tag.title
      end
      assert_equal original, digest
    end
  end

  def test_missing_sample_changes_signature_and_truncated_text_fails
    seed([[0, 'aaa'], [300, 'bbb'], [600, 'ccc']])
    before = snapshot
    edit_fixture(@path) do |moov|
      track = chapter_track(moov)
      table = sample_table(track)
      sizes = fixture_child(table, 'stsz')
      sizes[:data] = [0, 17, 2].pack('N3')
      fixture_child(table, 'stts')[:data] = [0, 2, 1, 300, 1, 700].pack('N6')
      fixture_child(table, 'stsc')[:data] = [0, 1, 1, 2, 1].pack('N5')
    end
    assert_false before.preserved_equal?(snapshot)
    moov, = read_fixture_moov(@path)
    first = fixture_child(sample_table(chapter_track(moov)), 'stco')[:data].byteslice(8, 4).unpack1('N')
    File.open(@path, 'r+b') { |io| io.seek(first); io.write([0xffff].pack('n')) }
    assert_raise(TagLib::MP4::ChapterSnapshotError) { snapshot }
  end

  def test_multiple_references_and_dual_formats_are_ambiguous
    seed
    edit_fixture(@path) do |moov|
      source = fixture_tracks(moov).find { |track| fixture_child(track, 'tref') }
      source[:children] << fixture_child(source, 'tref').dup
    end
    error = assert_raise(TagLib::MP4::ChapterSnapshotError) { snapshot }
    assert_equal :unsupported, error.code
    # 参照を戻してからNeroを併存させる。
    edit_fixture(@path) do |moov|
      source = fixture_tracks(moov).find { |track| fixture_child(track, 'tref') }
      source[:children].delete_at(source[:children].rindex { |node| node[:type] == 'tref' })
    end
    TagLib::MP4::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'Nero')], style: :nero)
      assert file.save_chapters
    end
    error = assert_raise(TagLib::MP4::ChapterSnapshotError) { snapshot }
    assert_equal :unsupported, error.code
  end

  def test_moov_before_media_offset_movement_and_regular_save
    seed
    before = snapshot
    # 小さいfixtureだけを使い、末尾moovを先頭へ移してchunk offsetを独立に補正する。
    atoms = parse_boxes(File.binread(@path))
    moov = atoms.find { |atom| atom[:type] == 'moov' }
    boundary = render_boxes(atoms.take(atoms.index(moov))).bytesize
    growth = render_boxes([moov]).bytesize
    each_fixture_atom([moov]) do |atom|
      next unless atom[:type] == 'stco'
      atom[:data] = atom[:data].byteslice(0, 8) + atom[:data].byteslice(8..).unpack('N*').map { |v| v < boundary ? v + growth : v }.pack('N*')
    end
    atoms.delete(moov)
    atoms.insert(1, moov)
    File.binwrite(@path, render_boxes(atoms))
    assert before.preserved_equal?(snapshot)
    old_moov, = read_fixture_moov(@path)
    old_offset = fixture_child(sample_table(chapter_track(old_moov)), 'stco')[:data].byteslice(8, 4).unpack1('N')
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.title = 'offset-movement-' + 'x' * 100_000
      assert file.save
      assert before.preserved_equal?(file.chapter_sample_snapshot)
    end
    new_moov, = read_fixture_moov(@path)
    new_offset = fixture_child(sample_table(chapter_track(new_moov)), 'stco')[:data].byteslice(8, 4).unpack1('N')
    assert_operator new_offset, :>, old_offset
    verify_ffprobe(snapshot)
    edit_fixture(@path) do |movie|
      offsets = fixture_child(sample_table(chapter_track(movie)), 'stco')
      offsets[:type] = 'co64'
      offsets[:data] = offsets[:data].byteslice(0, 8) + offsets[:data].byteslice(8..).unpack('N*').pack('Q>*')
      movie[:children] << { type: 'free', data: 'grow' * 100 }
    end
    assert before.preserved_equal?(snapshot)
  end

  def test_truncated_atom_and_outside_mdat_payload_fail
    seed
    baseline = File.binread(@path)
    File.binwrite(@path, baseline.byteslice(0...-1))
    assert_raise(TagLib::MP4::ChapterSnapshotError) { snapshot }
    File.binwrite(@path, baseline)
    edit_fixture(@path) do |moov|
      table = sample_table(chapter_track(moov))
      fixture_child(table, 'stsz')[:data] = [0, 0, 5, 100_000, 17, 14, 18, 14].pack('N8')
    end
    assert_raise(TagLib::MP4::ChapterSnapshotError) { snapshot }
  end

  def test_capture_failure_keeps_pending_timing_plan_and_chapter_edit
    seed(Array.new(15) { |i| [(i + 1) * 50, ''] })
    inject_chapter_timing(@path, movie_scale: 441_000_000, movie_duration: MOVIE_DURATION,
      track_duration: 3_640_937, edit_rows: [[MOVIE_DURATION & 0xffffffff, 0, 65_536]])
    TagLib::MP4::File.open(@path, false) do |file|
      file.repair_native_chapter_timing(track_id: file.chapter_sample_snapshot.track_id, profile: :taglib_full_movie)
      plan = file.instance_variable_get(:@chapter_timing_repair)
      edit_fixture(@path) do |moov|
        fixture_child(sample_table(chapter_track(moov)), 'stts')[:data] = [0, 1, 99, 10].pack('N4')
      end
      changed = digest
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_sample_snapshot }
      assert_same plan, file.instance_variable_get(:@chapter_timing_repair)
      assert_equal changed, digest
    end
    # chapter pendingについても取得失敗の前後で同一オブジェクトを保持する。
    FileUtils.rm_f(@path)
    setup_path = File.join(@dir, 'fresh.mp4')
    _out, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'sine=duration=1', '-c:a', 'aac', setup_path)
    assert status.success?, error
    FileUtils.mv(setup_path, @path)
    seed
    TagLib::MP4::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'pending')], style: :quicktime)
      pending = file.instance_variable_get(:@chapter_changes)
      edit_fixture(@path) do |moov|
        fixture_child(sample_table(chapter_track(moov)), 'stsz')[:data] = [0, 0, 99].pack('N3')
      end
      changed = digest
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_sample_snapshot }
      assert_same pending, file.instance_variable_get(:@chapter_changes)
      assert_equal changed, digest
    end
  end

  def test_real_file_copy_reference_and_timing_repair
    original = ENV['TAGLIB_CHAPTER_SAMPLE_REAL_PATH']
    omit('real file path is not configured') unless original
    original_digest = Digest::SHA256.file(original).hexdigest
    FileUtils.copy_file(original, @path)
    TagLib::MP4::File.open(@path, false) do |file|
      assert_raise(TagLib::MP4::ChapterSnapshotError) { file.chapter_sample_snapshot }
      assert_not_empty file.remove_dangling_chapter_references
      assert file.save_chapters
      before = file.chapter_sample_snapshot
      assert_equal 4, before.track_id
      assert_equal 2, before.source_track_id
      assert_equal 16, before.samples.size
      assert_equal 15, file.chapter_snapshot.quicktime.size
      assert_equal :clipped, before.ffprobe_comparison[:status]
      assert_equal :planned, file.repair_native_chapter_timing(track_id: 4, profile: :taglib_full_movie)[:status]
      assert file.save_chapters
      after = file.chapter_sample_snapshot
      assert before.preserved_equal?(after)
      assert_equal 3_640_937, after.samples.last.values_at(:start_ticks, :duration_ticks).sum
      verify_ffprobe(after)
    end
    assert_equal original_digest, Digest::SHA256.file(original).hexdigest
  end
end
