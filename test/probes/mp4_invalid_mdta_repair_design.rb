# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'taglib_plus'
require_relative '../support/mp4_investigation_fixture'

# 設計専用probe。製品APIの完成や保存障害契約の検証とは扱わない。
class InvalidMdtaRepairDesignTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  def setup
    @dir = Dir.mktmpdir('invalid-mdta-design-')
    @path = File.join(@dir, 'source.mp4')
    _, error, status = Open3.capture3('ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
      'sine=duration=1', '-c:a', 'aac', @path)
    assert status.success?, error
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def metadata(path = @path)
    fixture_child(fixture_child(read_fixture_moov(path).first, 'udta'), 'meta')
  end

  # 不明なfourccを整数として誤削除しない保守的な分類を試す。
  # 例: [0xffffffff].pack('N')はnumeric、'zzzz'は解釈不明として拒否。
  def candidate(meta, layout: :mixed_known_fourcc)
    keys = fixture_child(meta, 'keys') or raise ArgumentError, 'missing keys'
    bytes = keys.fetch(:data)
    raise ArgumentError, 'bad keys header' unless bytes.bytesize >= 8 && bytes.unpack1('N').zero?
    entries = parse_boxes(bytes.byteslice(8..))
    raise ArgumentError, 'bad keys count' unless entries.length == bytes.byteslice(4, 4).unpack1('N')
    names = entries.map do |entry|
      value = entry[:data].dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, 'bad key' unless entry[:type] == 'mdta' && value.valid_encoding? && !value.empty? && !value.include?("\0")
      value
    end
    raise ArgumentError, 'duplicate keys' unless names.uniq == names
    items = fixture_child(meta, 'ilst').fetch(:children)
    ordinary = TagLib::MP4.const_get(:UnindexedMdtaPlan, false)::ORDINARY_TYPES
    removed = items.select do |item|
      type = item.fetch(:type)
      next false if layout == :mixed_known_fourcc && ordinary.include?(type)
      raise ArgumentError, 'ambiguous item type' if layout != :indexed && type.bytes.all? { |byte| byte.between?(32, 126) }
      index = type.unpack1('N')
      index.zero? || index > names.length
    end
    copy = Marshal.load(Marshal.dump(meta))
    fixture_child(copy, 'ilst')[:children] = items.reject { |item| removed.include?(item) }
    [copy, removed.map { |item| item[:type].unpack1('N') }]
  end

  def test_arbitrary_invalid_indices_and_interleaving_preserve_exact_survivors
    inject_metadata(@path, keys: %w[a b], indices: [0, 1, 3, 2, 0xffffffff, 1, 0x01000000, 0x00ffffff, 0])
    before = metadata
    after, removed = candidate(before)
    assert_equal [0, 3, 0xffffffff, 0x01000000, 0x00ffffff, 0], removed
    original = fixture_child(before, 'ilst')[:children]
    survivors = fixture_child(after, 'ilst')[:children]
    assert_equal render_boxes(original.values_at(1, 3, 5, 9)), render_boxes(survivors)
    assert_equal render_boxes([fixture_child(before, 'keys')]), render_boxes([fixture_child(after, 'keys')])
    assert_equal render_boxes([fixture_child(before, 'hdlr')]), render_boxes([fixture_child(after, 'hdlr')])
    assert_equal [], candidate(after).last
  end

  def test_empty_keys_and_duplicate_invalid_items
    inject_metadata(@path, keys: [], indices: [1, 0, 0xffffffff, 1])
    after, removed = candidate(metadata)
    assert_equal [1, 0, 0xffffffff, 1], removed
    assert_equal ["\xa9nam".b], fixture_child(after, 'ilst')[:children].map { |item| item[:type] }
  end

  def test_normal_indices_and_ordinary_fourcc_are_not_changed
    inject_metadata(@path, keys: %w[a b], indices: [1, 2, 1])
    before = metadata
    after, removed = candidate(before)
    assert_empty removed
    assert_equal render_boxes([before]), render_boxes([after])
  end

  def test_bad_keys_and_ambiguous_fourcc_are_not_treated_as_no_repair
    inject_metadata(@path, keys: %w[a b], indices: [0])
    before = metadata
    bad = Marshal.load(Marshal.dump(before))
    fixture_child(bad, 'keys')[:data][4, 4] = [3].pack('N')
    assert_raise(ArgumentError) { candidate(bad) }
    bad = Marshal.load(Marshal.dump(before))
    bad[:children].reject! { |item| item[:type] == 'keys' }
    assert_raise(ArgumentError) { candidate(bad) }
    bad = Marshal.load(Marshal.dump(before))
    fixture_child(bad, 'ilst')[:children].first[:type] = 'zzzz'
    assert_raise(ArgumentError) { candidate(bad) }
    # 同じ4bytesはfourccにも整数indexにもなる。bytesだけでproducerの意図は復元できない。
    assert_equal 'zzzz', ['zzzz'.unpack1('N')].pack('N')
    assert_equal 'covr', ['covr'.unpack1('N')].pack('N')
  end

  def test_explicit_indexed_profile_handles_fourcc_shaped_invalid_indices
    inject_metadata(@path, keys: %w[a b], indices: [1, 'zzzz'.unpack1('N'), 'covr'.unpack1('N'), 2])
    before = metadata
    # このfixtureはindexed profileとして構築するため、末尾の通常titleを外す。
    fixture_child(before, 'ilst')[:children].pop
    assert_raise(ArgumentError) { candidate(before) }
    after, removed = candidate(before, layout: :indexed)
    assert_equal ['zzzz'.unpack1('N'), 'covr'.unpack1('N')], removed
    assert_equal [1, 2], fixture_child(after, 'ilst')[:children].map { |item| item[:type].unpack1('N') }
  end

  def test_current_reader_misses_high_byte_indices
    inject_metadata(@path, keys: %w[a b], indices: [0, 3, 0x00ffffff, 0x01000000, 0xffffffff])
    reader = TagLib::MP4.const_get(:MetadataStructureReader, false)
    report = reader.read(@path, detailed: true)
    assert_equal [0, 3, 0x00ffffff], report[:issues].select { |row| row[:code] == :invalid_index }.map { |row| row[:key_index] }
    rows = report[:structure][:contexts].first[:items]
    assert_equal [:fourcc, :fourcc], rows.values_at(3, 4).map { |row| row[:interpretation] }
    assert_equal [0, 3, 0x00ffffff, 0x01000000, 0xffffffff], candidate(metadata).last
  end

  # 合成候補は独立fixture editorで一度だけ生成し、製品readerで結果を再読込する。
  def test_combined_candidate_preserves_nero_media_and_chunk_locations
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'Nero')], style: :nero)
      file.set_chapters([TagLib::MP4::Chapter.new(0, 'QT')], style: :quicktime)
      assert file.save_chapters
    end
    edit_fixture(@path) do |moov|
      audio = fixture_tracks(moov).find { |track| fixture_child(fixture_child(track, 'mdia'), 'hdlr')[:data].byteslice(8, 4) == 'soun' }
      reference = fixture_child(audio, 'tref')
      audio[:children] << Marshal.load(Marshal.dump(reference))
    end
    inject_metadata(@path, keys: %w[a b], indices: [1, 0, 2, 3, 0xffffffff])
    source = File.binread(@path)
    plan = API.open(@path) { |file| file.plan_quicktime_chapter_removal }
    assert_equal :removable, plan.status
    # 現行公開saveは不正metadataのため保存できないことも固定する。
    API.open(@path) do |file|
      file.remove_quicktime_chapters(plan: file.plan_quicktime_chapter_removal)
      assert_raise(API::Error) { file.save!(to: File.join(@dir, 'rejected.mp4')) }
    end
    output = File.join(@dir, 'candidate.mp4')
    FileUtils.cp(@path, output)
    expected, removed = candidate(metadata)
    assert_equal [0, 3, 0xffffffff], removed
    edit_fixture(output) do |moov|
      moov[:children].reject! { |track| track[:type] == 'trak' && fixture_track_id(track) == plan.target_track_id }
      fixture_tracks(moov).each do |track|
        track[:children].select { |node| node[:type] == 'tref' }.each do |tref|
          tref[:children].reject! { |node| node[:type] == 'chap' }
        end
        track[:children].reject! { |node| node[:type] == 'tref' && node[:children].empty? }
      end
      udta = fixture_child(moov, 'udta')
      udta[:children].map! { |node| node[:type] == 'meta' ? expected : node }
    end
    assert_equal source, File.binread(@path)
    assert_equal render_boxes([expected]), render_boxes([metadata(output)])
    before_roots, after_roots = [@path, output].map { |path| parse_boxes(File.binread(path)) }
    assert_equal before_roots.select { |node| node[:type] == 'mdat' }, after_roots.select { |node| node[:type] == 'mdat' }
    before_moov = before_roots.find { |node| node[:type] == 'moov' }
    after_moov = after_roots.find { |node| node[:type] == 'moov' }
    assert_equal render_boxes([fixture_child(fixture_child(before_moov, 'udta'), 'chpl')]), render_boxes([fixture_child(fixture_child(after_moov, 'udta'), 'chpl')])
    API.open(output) do |file|
      assert_nil file.read_chapters(style: :quicktime)
      assert_equal ['Nero'], file.read_chapters(style: :nero).map(&:title)
      assert_equal %w[a b], file.metadata.mdta.keys

    end
    # 独立parserでmdat内相対offsetと残存track全体を比較する。
    normalized = [before_roots, after_roots].map do |roots|
      cursor = 0
      ranges = roots.filter_map do |root|
        size = render_boxes([root]).bytesize
        start = cursor
        cursor += size
        [start + 8, cursor] if root[:type] == 'mdat'
      end
      tracks = fixture_tracks(roots.find { |node| node[:type] == 'moov' })
        .reject { |track| fixture_track_id(track) == plan.target_track_id }
      tracks.each do |track|
        track[:children].reject! { |node| node[:type] == 'tref' }
        each_fixture_atom([track]) do |node|
          next unless %w[stco co64].include?(node[:type])
          format = node[:type] == 'stco' ? 'N*' : 'Q>*'
          offsets = node[:data].byteslice(8..).unpack(format).map do |offset|
            range = ranges.find { |start, finish| offset >= start && offset < finish }
            assert_not_nil range, 'chunk must point inside mdat'
            offset - range.first
          end
          node[:data] = node[:data].byteslice(0, 8) + offsets.pack(format)
        end
      end
      render_boxes(tracks)
    end
    assert_equal normalized.first, normalized.last
  end
end
