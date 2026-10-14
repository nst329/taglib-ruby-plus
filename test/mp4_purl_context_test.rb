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

  def test_unindexed_unedited_purl_data_type_change_is_rejected
    [true].each do |unindexed|
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

  # mdirで取得したpurlはraw型・data順も復元候補へ引き継ぐ。
  def source_purl_snapshot(values: ['https://example.test/feed', 'https://example.test/second'], locales: nil)
    locales ||= Array.new(values.length, 0)
    source = File.join(@dir, 'source.mp4')
    FileUtils.cp(@path, source)
    edit_fixture(source) do |moov|
      meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
      fixture_child(meta, 'hdlr')[:data][8, 4] = 'mdir'
      meta[:children].reject! { |row| row[:type] == 'keys' }
      fixture_child(meta, 'ilst')[:children] = parse_boxes(atom_box('purl', values.each_with_index.map do |value, index|
        atom_box('data', [1, locales.fetch(index)].pack('N2') + value)
      end.join.b))
    end
    TagLib::MP4::File.open(source, false) { |file| file.metadata_snapshot }
  end

  def add_mdir_context
    edit_fixture(@path) do |moov|
      udta = fixture_child(moov, 'udta')
      handler = fixture_child(fixture_child(udta, 'meta'), 'hdlr')[:data].dup
      handler[8, 4] = 'mdir'
      udta[:children] << parse_boxes(atom_box('meta', "\0".b * 4 + atom_box('hdlr', handler) + atom_box('ilst', ''.b))).first
    end
  end

  def test_mdta_only_restore_appends_numeric_purl_key
    snapshot = source_purl_snapshot
    before_context = raw_context
    digest = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      diagnosis = file.metadata_context_diagnostics[:purl]
      assert diagnosis[:writable]
      assert_false diagnosis[:existing]
      assert_equal 3, diagnosis[:key_index]
      assert_equal 'mdta', diagnosis[:context_handler]
      assert_equal :append_mdta_key, diagnosis[:reason]
      file.restore_metadata_snapshot(snapshot)
      assert_equal digest, Digest::SHA256.file(@path).hexdigest
      assert file.save
      restored = file.metadata_snapshot
      assert_equal snapshot.purl_raw_digests, restored.purl_raw_digests
      assert_equal snapshot.item('purl')[:value], restored.mdta_values('purl').map { |row| row[:data] }
    end
    after_context = raw_context
    assert_equal before_context.first, after_context.first
    assert_equal before_context.last, after_context.last[0, before_context.last.length]
    purl = after_context.last.last
    assert_equal [0, 0, 0, 3].pack('C*'), purl.first
    assert_empty probe.last
  end

  def test_existing_mdta_purl_key_updates_without_reordering_existing_items
    first = source_purl_snapshot(values: ['https://example.test/old', 'https://example.test/old-2'])
    updated = source_purl_snapshot(values: ['https://example.test/new', 'https://example.test/new-2'])
    TagLib::MP4::File.open(@path, false) do |file|
      file.restore_metadata_snapshot(first)
      assert file.save
      before = file.metadata_context_diagnostics[:structure][:contexts].first
      existing = before[:items].reject { |row| row[:key] == 'purl' }.map { |row| [row[:item_index], row[:raw_type], row[:raw_digest]] }

      diagnosis = file.metadata_context_diagnostics[:purl]
      assert diagnosis[:writable]
      assert diagnosis[:existing]
      assert_equal before[:keys].index('purl') + 1, diagnosis[:key_index]
      file.restore_metadata_snapshot(updated)
      assert file.save
      after = file.metadata_context_diagnostics[:structure][:contexts].first
      purl = after[:items].find { |row| row[:key] == 'purl' }
      assert_equal before[:keys], after[:keys]
      assert_equal existing, after[:items].reject { |row| row[:key] == 'purl' }.map { |row| [row[:item_index], row[:raw_type], row[:raw_digest]] }
      assert_equal before[:items].find { |row| row[:key] == 'purl' }[:item_index], purl[:item_index]
      assert_equal updated.item('purl')[:value], file.metadata_snapshot.mdta_values('purl').map { |row| row[:data] }
      assert_equal updated.purl_raw_digests, file.metadata_snapshot.purl_raw_digests
    end
    assert_empty probe.last
  end

  def test_existing_mdta_purl_snapshot_updates_without_fourcc_item
    initial = source_purl_snapshot(values: ['https://example.test/old'])
    update_source = source_purl_snapshot(values: ['https://example.test/new', 'https://example.test/new-2'])
    update = TagLib::MP4::MetadataSnapshot.new(
      items: update_source.items.reject { |row| row[0] == 'purl' },
      mdta: [['purl', 1, update_source.item('purl')[:value].map { |value| [1, 0, value.b] }]],
      source_structure: update_source.source_structure,
      format_version: update_source.format_version
    )
    TagLib::MP4::File.open(@path, false) do |file|
      file.restore_metadata_snapshot(initial)
      assert file.save
      file.restore_metadata_snapshot(update)
      assert file.save
      actual = file.metadata_context_diagnostics[:structure][:contexts].first
      assert actual[:items].any? { |row| row[:key] == 'purl' && row[:interpretation] == :key_index }
      assert actual[:items].none? { |row| row[:raw_type] == 'purl' }
      assert_equal update.mdta_values('purl'), file.metadata_snapshot.mdta_values('purl')
      assert_equal update.purl_raw_digests, file.metadata_snapshot.purl_raw_digests
    end
    assert_empty probe.last
  end

  def test_mdta_purl_preserves_multiple_locales_and_value_order
    snapshot = source_purl_snapshot(values: ['https://example.test/default', 'https://example.test/ja'], locales: [0, 1041])
    TagLib::MP4::File.open(@path, false) do |file|
      file.restore_metadata_snapshot(snapshot)
      assert file.save
      assert_equal [[1, 0, 'https://example.test/default'.b], [1, 1041, 'https://example.test/ja'.b]],
        file.metadata_snapshot.mdta_values('purl').map { |row| [row[:data_type], row[:locale], row[:data]] }
      assert_equal snapshot.purl_raw_digests, file.metadata_snapshot.purl_raw_digests
    end
    assert_empty probe.last
  end

  def test_mdta_purl_extension_rejects_chunk_offset_outside_mdat_atomically
    snapshot = source_purl_snapshot
    edit_fixture(@path) do |moov|
      each_fixture_atom([moov]) do |node|
        next unless node[:type] == 'stco'

        node[:data][8, 4] = [File.size(@path) + 1024].pack('N')
        break
      end
    end
    before = File.binread(@path)
    TagLib::MP4::File.open(@path, false) do |file|
      error = assert_raise(TagLib::MP4::MetadataSnapshotError) { file.restore_metadata_snapshot(snapshot) }
      assert_equal :purl_atom_extension_unsupported, error.code
      assert_equal :restore, error.phase
    end
    assert_equal before, File.binread(@path)
    assert_empty Dir.glob("#{@path}.taglib-mdta-*")
  end

  def test_mdta_restore_adds_purl_alongside_an_absent_macos_style_mdta_key
    snapshot = source_purl_snapshot.with(mdta: {
      'com.apple.quicktime.location.ISO6709' => [[1, 0, '+35.0000+139.0000/'.b]]
    })
    TagLib::MP4::File.open(@path, false) do |file|
      file.restore_metadata_snapshot(snapshot)
      assert file.save
      actual = file.metadata_snapshot
      assert_equal [[1, 0, '+35.0000+139.0000/'.b]], actual.mdta_values('com.apple.quicktime.location.ISO6709').map { |row|
        [row[:data_type], row[:locale], row[:data]]
      }
      assert_equal snapshot.item('purl')[:value], actual.mdta_values('purl').map { |row| row[:data] }
      assert_equal snapshot.purl_raw_digests, actual.purl_raw_digests
    end
    assert_empty probe.last
  end

  def test_restore_into_existing_mdir_preserves_purl_raw_and_values
    snapshot = source_purl_snapshot
    add_mdir_context
    packets, warnings = probe
    assert_empty warnings
    TagLib::MP4::File.open(@path, false) do |file|
      assert_equal 'mdir', file.metadata_context_diagnostics[:purl][:context][:handler]
      assert file.metadata_context_diagnostics[:purl][:writable]
      file.restore_metadata_snapshot(snapshot)
      assert file.save
    end
    TagLib::MP4::File.open(@path, false) do |file|
      restored = file.metadata_snapshot
      assert snapshot.same_values?(restored)
      assert_equal snapshot.purl_raw_digests, restored.purl_raw_digests
    end
    assert_equal packets, probe.first
    assert_empty probe.last
  end

  def test_snapshot_rejects_existing_mdta_fourcc_purl
    snapshot = source_purl_snapshot
    edit_fixture(@path) do |moov|
      ilst = fixture_child(fixture_child(fixture_child(moov, 'udta'), 'meta'), 'ilst')
      ilst[:children] << parse_boxes(snapshot.source_structure[:purl_raw].first[:raw]).first
    end
    before = File.binread(@path)
    TagLib::MP4::File.open(@path, false) do |file|
      diagnosis = file.metadata_context_diagnostics[:purl]
      assert_false diagnosis[:writable]
      assert_equal :purl_fourcc_context, diagnosis[:code]
      assert_equal :fourcc_purl, diagnosis[:reason]
      error = assert_raise(TagLib::MP4::MetadataSnapshotError) { file.restore_metadata_snapshot(snapshot) }
      assert_equal :purl_fourcc_context, error.code
    end
    assert_equal before, File.binread(@path)
  end

  def test_multiple_mdir_contexts_are_rejected_without_changes
    snapshot = source_purl_snapshot
    add_mdir_context
    add_mdir_context
    digest = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      assert_false file.metadata_context_diagnostics[:purl][:writable]
      error = assert_raise(TagLib::MP4::MetadataSnapshotError) { file.restore_metadata_snapshot(snapshot) }
      assert_equal :ambiguous_purl_context, error.code
    end
    assert_equal digest, Digest::SHA256.file(@path).hexdigest
  end

  def test_paired_save_failure_preserves_original_sha
    snapshot = source_purl_snapshot
    add_mdir_context
    digest = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      file.restore_metadata_snapshot(snapshot)
      file.define_singleton_method(:stage_purl_pair) do |*_args|
        raise TagLib::MP4::MdtaSaveError.new('injected staging failure', phase: :taglib_save, code: :injected)
      end
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
      assert_equal :taglib_save, error.phase
      assert_equal :injected, error.code
      assert_false error.committed
    end
    assert_equal digest, Digest::SHA256.file(@path).hexdigest
    assert_empty Dir.glob("#{@path}.taglib-mdta-*")
  end

  def test_paired_snapshot_restores_mdta_and_can_be_reapplied_or_remove_purl
    original = source_purl_snapshot.with(mdta: { 'gain' => [[1, 1041, '日本語'.b], [33, 0, "\xff".b]] },
      items: [['desc', :string_list, 255, ['説明']]])
    add_mdir_context
    TagLib::MP4::File.open(@path, false) do |file|
      2.times do
        file.restore_metadata_snapshot(original)
        assert file.save
        assert original.same_values?(file.metadata_snapshot)
        assert_equal original.purl_raw_digests, file.metadata_snapshot.purl_raw_digests
      end
      without_purl = original.without(items: ['purl'])
      file.restore_metadata_snapshot(without_purl)
      assert file.save
      assert_nil file.metadata_snapshot.item('purl')
    end
    assert_not_match(/The index of 'data' is out of range/, probe.last)
  end

  def test_single_existing_purl_property_save_preserves_raw_type_and_position
    snapshot = source_purl_snapshot
    edit_fixture(@path) do |moov|
      ilst = fixture_child(fixture_child(fixture_child(moov, 'udta'), 'meta'), 'ilst')
      ilst[:children].unshift(parse_boxes(snapshot.source_structure[:purl_raw].first[:raw]).first)
    end
    TagLib::MP4::File.open(@path, false) do |file|
      original = file.metadata_snapshot
      file.tag.set_property('description', 'keep purl')
      assert file.save
      assert_equal original.purl_raw_digests, file.metadata_snapshot.purl_raw_digests
      context = file.metadata_context_diagnostics[:structure][:contexts].first
      assert_equal 'purl', context[:items].first[:raw_type]
      file.tag.item_map['purl'].set_atom_data_type(1)
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
      assert_equal :purl_data_type_change, error.code
      assert_equal :prepare, error.phase
      assert_false error.committed
    end
  end

  def test_handler_and_invalid_keys_refuse_restore_before_mutation
    snapshot = source_purl_snapshot
    [:handler, :keys].each do |fault|
      path = File.join(@dir, "invalid-#{fault}.mp4")
      FileUtils.cp(@path, path)
      edit_fixture(path) do |moov|
        meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
        if fault == :handler
          fixture_child(meta, 'hdlr')[:data][8, 4] = 'mdir'
        else
          fixture_child(meta, 'keys')[:data][4, 4] = [9999].pack('N')
        end
      end
      digest = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        error = assert_raise(TagLib::MP4::MetadataSnapshotError) { file.restore_metadata_snapshot(snapshot) }
        assert_equal :ambiguous_purl_context, error.code
      end
      assert_equal digest, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_paired_verification_failure_preserves_original_and_blocks_chapter_only_save
    snapshot = source_purl_snapshot
    add_mdir_context
    digest = Digest::SHA256.file(@path).hexdigest
    TagLib::MP4::File.open(@path, false) do |file|
      file.restore_metadata_snapshot(snapshot)
      assert_raise(TagLib::MP4::ChapterSaveError) { file.save_chapters }
      file.define_singleton_method(:mdat_payload_signature) { |_path| :injected_mismatch }
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
      assert_equal :verify, error.phase
      assert_false error.committed
      assert snapshot.same_values?(file.metadata_snapshot), '失敗後も候補snapshotを保持する'
    end
    assert_equal digest, Digest::SHA256.file(@path).hexdigest
    assert_empty Dir.glob("#{@path}.taglib-mdta-*")
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
