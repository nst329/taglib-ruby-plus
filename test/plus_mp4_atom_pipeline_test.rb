# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib_plus'
require_relative 'support/mp4_investigation_fixture'

# metadata置換と共通atom編集の、原本読取量と保存後の保持を独立に確認する。
class PlusMP4AtomPipelineTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  def setup
    @dir = Dir.mktmpdir('atom-pipeline-')
    @source = File.join(@dir, 'source.m4a')
    @output = File.join(@dir, 'output.m4a')
    FileUtils.cp(File.expand_path('data/mp4.m4a', __dir__), @source)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_metadata_replacement_reads_retained_track_payload_once
    name = 'track-name:'.b + 'x'.b * (2 * 1024 * 1024)
    edit_fixture(@source) do |moov|
      track = fixture_tracks(moov).first
      udta = fixture_child(track, 'udta')
      unless udta
        udta = { type: 'udta', children: [] }
        track[:children] << udta
      end
      udta[:children] << { type: 'name', data: name }
    end
    API.open(@source) do |file|
      roots = file.send(:header_reader).structure
      moov = roots.find { |atom| atom[:type] == 'moov' }
      track = moov[:children].find { |atom| atom[:type] == 'trak' }
      udta = track[:children].find { |atom| atom[:type] == 'udta' }
      name_atom = udta[:children].find { |atom| atom[:type] == 'name' }
      file.define_singleton_method(:read_native) { raise 'metadata replacement must not load old native values' }
      validation_reads = measure_source_reads do
        file.metadata = API::MetadataSnapshot.new(items: [API::MetadataItem.new(
          key: '©nam', kind: :string_list, atom_data_type: 255, value: ['新しいタイトル'])])
      end
      assert_empty validation_reads.select { |offset, length|
        offset < name_atom[:end_offset] && offset + length > name_atom[:payload_offset]
      }
      calls = measure_source_reads do
        file.save!(to: @output)
      end
      payload_reads = calls.select do |offset, length|
        offset < name_atom[:end_offset] && offset + length > name_atom[:payload_offset]
      end
      assert_equal 1, calls.count([name_atom[:offset], name.bytesize + 8])
      # 計画生成で1回、原本全体のコピー・SHA走査で1回。OS内部の物理I/Oとは区別する。
      assert_operator payload_reads.sum(&:last), :<=, name.bytesize * 2 + 65536
    end
    movie = read_fixture_moov(@output).first
    actual = fixture_child(fixture_child(fixture_tracks(movie).first, 'udta'), 'name')
    assert_equal name, actual.fetch(:data)
    API.open(@output) { |file| assert_equal ['新しいタイトル'], file.metadata.properties[:title] }
  end

  def test_single_render_preserves_media_and_offsets_for_growth_shrink_and_extended_headers
    # [metadata増減bytes, moov直下freeの全長, 期待するmoov増加bytes]。
    # 4 bytesだけ余る場合も、最小8 bytesのfreeを作る既存仕様を維持する。
    cases = [[8, 0, 8], [8, 16, 0], [8, 12, 8], [64, 16, 48], [-4, 0, 8], [-32, 0, 0]]
    [false, true].each do |extended|
      cases.each do |growth, padding, expected_delta|
        make_faststart_fixture(padding: padding, extended: extended)
        original = File.binread(@source)
        roots = parse_boxes(original)
        offsets = chunk_offsets(roots)
        transform = lambda do |raw|
          meta = parse_boxes(raw).first
          fixture_child(meta, 'free')[:data] = 'p'.b * (32 + growth)
          render_boxes([meta])
        end
        API.open(@source) do |file|
          editor_class = TagLib::MP4.const_get(:MP4AtomEditor, false)
          editor = editor_class.new(file.send(:header_reader), metadata_transform: transform, capture_raw: false)
          render = editor.method(:render)
          renders = []
          editor.define_singleton_method(:render) do |atom, delta|
            renders << delta if atom[:type] == 'moov'
            render.call(atom, delta)
          end
          editor.atom_plan.write_copy(@source, @output)
          assert_equal [expected_delta], renders, [growth, padding, extended].inspect
        end
        actual = parse_boxes(File.binread(@output))
        assert_equal original, File.binread(@source)
        assert_equal roots.find { |node| node[:type] == 'mdat' }, actual.find { |node| node[:type] == 'mdat' }
        assert_equal offsets.map { |values| values.map { |value| value + expected_delta } }, chunk_offsets(actual)
        assert_equal extended, actual.find { |node| node[:type] == 'moov' }.fetch(:extended)
        API.open(@output) { |file| assert_equal :complete, file.diagnose(:structure)[:status] }
      end
    end
  end

  private

  # moovをmdatより前へ移し、stco/co64と拡張headerを独立fixture側で構成する。
  def make_faststart_fixture(padding:, extended:)
    roots = parse_boxes(File.binread(File.expand_path('data/mp4.m4a', __dir__)))
    old_media_start = roots.take_while { |node| node[:type] != 'mdat' }.sum { |node| render_boxes([node]).bytesize } + 8
    moov = roots.find { |node| node[:type] == 'moov' }
    moov[:extended] = extended
    moov[:children].reject! { |node| node[:type] == 'free' }
    moov[:children] << { type: 'free', data: 'f'.b * (padding - 8) } if padding.positive?
    meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
    meta[:children].reject! { |node| node[:type] == 'free' }
    meta[:children] << { type: 'free', data: 'p'.b * 32 }
    each_fixture_atom([moov]) do |node|
      next unless extended && node[:type] == 'stco'

      node[:type] = 'co64'
      node[:data] = node[:data].byteslice(0, 8) + node[:data].byteslice(8..).unpack('N*').pack('Q>*')
    end
    roots.delete(moov)
    roots.insert(1, moov)
    new_media_start = roots.take_while { |node| node[:type] != 'mdat' }.sum { |node| render_boxes([node]).bytesize } + 8
    each_fixture_atom([moov]) do |node|
      next unless %w[stco co64].include?(node[:type])

      format = node[:type] == 'stco' ? 'N*' : 'Q>*'
      values = node[:data].byteslice(8..).unpack(format).map { |value| value + new_media_start - old_media_start }
      node[:data] = node[:data].byteslice(0, 8) + values.pack(format)
    end
    File.binwrite(@source, render_boxes(roots))
  end

  def chunk_offsets(roots)
    values = []
    each_fixture_atom(roots) do |node|
      next unless %w[stco co64].include?(node[:type])

      values << node[:data].byteslice(8..).unpack(node[:type] == 'stco' ? 'N*' : 'Q>*')
    end
    values
  end

  # 実File#readの範囲だけを計測し、native内部I/OやOSキャッシュの効果とは区別する。
  def measure_source_reads
    original = File.instance_method(:read)
    path = @source
    calls = []
    File.define_method(:read) do |*args, **kwargs|
      offset = pos
      value = original.bind_call(self, *args, **kwargs)
      calls << [offset, value.bytesize] if self.path == path && value.is_a?(String)
      value
    end
    yield
    calls
  ensure
    File.define_method(:read, original) if original
  end
end
