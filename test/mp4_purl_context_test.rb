# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'open3'
require 'json'
require 'digest'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_investigation_fixture'

# 実FFprobeと独立parserでpurl警告の生成経路とcontext保持を確認する。
class MP4PurlContextTest < Test::Unit::TestCase
  include MP4InvestigationFixture

  def setup
    @dir = Dir.mktmpdir('purl-context-')
    @path = File.join(@dir, 'synthetic.mp4')
    _, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'color=size=32x32:duration=0.2', '-c:v', 'libx264',
      '-movflags', '+use_metadata_tags', '-metadata', 'title=fixture', @path)
    assert status.success?, error
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def probe
    output, error, status = Open3.capture3(ENV.fetch('FFPROBE', 'ffprobe'), '-v', 'warning',
      '-show_packets', '-show_data_hash', 'sha256', '-show_entries', 'packet=stream_index,size,data_hash', '-of', 'json', @path)
    assert status.success?, error
    [JSON.parse(output), error]
  end

  def raw_context
    moov, = read_fixture_moov(@path)
    meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
    [fixture_child(meta, 'hdlr')[:data], fixture_child(meta, 'keys')&.fetch(:data),
     parse_boxes(fixture_child(meta, 'ilst')[:data]).map { |row| [row[:type], row[:data]] }]
  end

  def test_native_writer_minimal_reproduction_and_public_save_refusal
    before = raw_context
    packets, warnings = probe
    assert_empty warnings
    digest = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.set_property('podcastURL', 'https://example.test/feed')
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
      assert_equal :prepare, error.phase
      assert_false error.committed
      assert_match(/purl.*mdta/, error.message)
      assert_equal digest, Digest::SHA256.file(@path).hexdigest
      # 合成fixtureに限定して下位native writerの原因を再現する。
      assert file.send(:save_without_chapter_state)
    end
    after = raw_context
    assert_equal before.take(2), after.take(2), 'handlerとkeysは変わらない'
    assert_equal before.last, after.last.reject { |type, _data| type == 'purl' }, '元の数値item保持'
    assert_equal ['purl'], (after.last.map(&:first) - before.last.map(&:first))
    saved_packets, warnings = probe
    assert_equal packets, saved_packets
    assert_match(/1886745196 < 1 or >= 3/, warnings)
    TagLib::MP4::File.open(@path, false) do |file|
      context = file.metadata_context_diagnostics[:structure][:contexts].first
      assert_equal 'mdta', context[:handler]
      purl = context[:items].find { |row| row[:raw_type] == 'purl' }
      assert_equal :fourcc, purl[:interpretation]
      assert_equal 1886745196, purl[:numeric_value]
      assert_nil purl[:key_index]
      assert_false purl[:index_in_keys]
      assert context[:items].any? { |row| row[:interpretation] == :key_index && row[:key] == 'title' }
      assert_raise(FrozenError) { purl[:offset] = 0 }
    end
    edit_fixture(@path) do |moov|
      fixture_tracks(moov).first[:children] << { type: 'tref', children: [{ type: 'chap', data: [0].pack('N') }] }
    end
    before_repair = raw_context
    TagLib::MP4::File.open(@path, false) do |file|
      file.remove_chapter_references(references: file.chapter_reference_diagnostics)
      assert file.save_chapters
    end
    assert_equal before_repair, raw_context, '参照解除はmeta全体をraw保持する'
    assert_match(/1886745196/, probe.last)
    TagLib::MP4::File.open(@path, false) do |file|
      assert_empty file.chapter_reference_diagnostics
      file.tag.set_property('description', 'existing purl retained')
      assert file.save
    end
    assert_equal before_repair.take(2), raw_context.take(2)
    assert_equal before_repair.last.select { |type, _data| type == 'purl' }, raw_context.last.select { |type, _data| type == 'purl' }
    assert_equal packets, probe.first
  end

  def test_mdir_purl_saves_without_index_warning
    edit_fixture(@path) do |moov|
      meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
      fixture_child(meta, 'hdlr')[:data][8, 4] = 'mdir'
      meta[:children].reject! { |row| row[:type] == 'keys' }
      fixture_child(meta, 'ilst')[:children] = []
    end
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.set_property('podcastURL', 'https://example.test/feed')
      assert file.save
    end
    assert_empty probe.last
    TagLib::MP4::File.open(@path, false) { |file| assert_equal 'https://example.test/feed', file.tag.property('podcastURL') }
  end

  def test_unindexed_save_does_not_introduce_purl
    inject_metadata(@path, keys: ['opaque'], indices: [0])
    before = File.binread(@path)
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.set_property('podcastURL', 'https://example.test/feed')
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_preserving_unindexed_mdta }
      assert_equal :prepare, error.phase
    end
    assert_equal before, File.binread(@path)
    assert_empty Dir.glob("#{@path}.taglib-mdta-*")
  end

  def test_unindexed_save_preserves_existing_purl_context
    inject_metadata(@path, keys: ['opaque'], indices: [0])
    edit_fixture(@path) do |moov|
      meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
      fixture_child(meta, 'ilst')[:children] << parse_boxes(atom_box('purl',
        atom_box('data', [0, 0].pack('N2') + 'https://example.test/feed'))).first
    end
    before = raw_context
    packets, warnings = probe
    assert_match(/1886745196/, warnings)
    TagLib::MP4::File.open(@path, false) do |file|
      file.tag.item_map.insert('desc', TagLib::MP4::Item.from_string_list(['preserve existing purl']))
      assert file.save_preserving_unindexed_mdta
    end
    after = raw_context
    assert_equal before.take(2), after.take(2)
    assert_equal before.last.select { |type, _data| type == 'purl' || type == [0].pack('N') },
                 after.last.select { |type, _data| type == 'purl' || type == [0].pack('N') }
    assert_equal packets, probe.first
    assert_match(/1886745196/, probe.last)
  end

  def test_diagnostic_failure_is_explicit
    TagLib::MP4::File.open(@path, false) do |file|
      edit_fixture(@path) do |moov|
        meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
        ilst = fixture_child(meta, 'ilst')
        ilst.delete(:children)
        ilst[:data] = [999].pack('N') + 'purl'
      end
      report = file.metadata_context_diagnostics
      assert_equal :failed, report[:status]
      assert_equal :unreadable_structure, report[:issues].first[:code]
      assert_match(/atom length/, report[:issues].first[:message])
    end
  end

  def test_unedited_purl_data_type_change_is_rejected_by_both_save_paths
    [false, true].each do |unindexed|
      inject_metadata(@path, keys: ['opaque'], indices: unindexed ? [0] : [1])
      edit_fixture(@path) do |moov|
        meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
        fixture_child(meta, 'ilst')[:children] << parse_boxes(atom_box('purl',
          atom_box('data', [1, 0].pack('N2') + 'https://example.test/feed'))).first
      end
      before = File.binread(@path)
      TagLib::MP4::File.open(@path, false) do |file|
        file.tag.item_map.insert('desc', TagLib::MP4::Item.from_string_list(['unrelated edit']))
        error = assert_raise(TagLib::MP4::MdtaSaveError) do
          unindexed ? file.save_preserving_unindexed_mdta : file.save
        end
        assert_equal :verify, error.phase
        assert_match(/changed unedited purl bytes/, error.message)
        assert_false error.committed
      end
      assert_equal before, File.binread(@path)
      assert_empty Dir.glob("#{@path}.taglib-mdta-*")
    end
  end

  def test_real_short_colr_warning_diagnosis_and_reference_save_preservation
    edit_fixture(@path) do |moov|
      video = fixture_tracks(moov).first
      stsd = fixture_child(fixture_child(fixture_child(fixture_child(video, 'mdia'), 'minf'), 'stbl'), 'stsd')
      entries = parse_boxes(stsd[:data].byteslice(8..))
      entries.first[:data] += atom_box('colr', 'nclx' + [1, 1, 1].pack('n3'))
      stsd[:data] = stsd[:data].byteslice(0, 8) + render_boxes(entries)
      video[:children] << { type: 'tref', children: [{ type: 'chap', data: [0].pack('N') }] }
    end
    _, warnings = probe
    assert_match(/overread end of atom 'colr' by 1 bytes/, warnings)
    digest = nil
    TagLib::MP4::File.open(@path, false) do |file|
      row = file.color_metadata_diagnostics[:entries].first[:colr].first
      assert_nil row[:full_range]
      assert_equal [:short_color_payload], row[:issues]
      digest = row[:raw_digest]
      file.remove_chapter_references(references: file.chapter_reference_diagnostics)
      assert file.save_chapters
    end
    TagLib::MP4::File.open(@path, false) do |file|
      assert_equal digest, file.color_metadata_diagnostics[:entries].first[:colr].first[:raw_digest]
    end
    assert_match(/overread end of atom 'colr' by 1 bytes/, probe.last)
  end
end
