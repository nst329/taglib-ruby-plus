# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'digest'
$LOAD_PATH.unshift(ENV.fetch('PLUS_BINDING_LIB', File.expand_path('../../lib', __dir__)))
require 'taglib_plus'
require_relative '../support/mp4_investigation_fixture'

# metadata完全復元の受入probe。通常の *_test.rb globには含めず、公開APIと独立fixtureで保存契約を検証する。
class PlusMP4MetadataContract < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  def setup
    @dir = Dir.mktmpdir('plus-metadata-contract-')
    @source, @target = %w[source target].map { |name| File.join(@dir, "#{name}.mp4") }
    subtitle = File.join(@dir, 'subtitle.srt')
    File.write(subtitle, "1\n00:00:00,000 --> 00:00:00,400\n字幕\n")
    run!(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=0.5',
      '-f', 'lavfi', '-i', 'sine=duration=0.5', '-i', subtitle,
      '-c:v', 'libx264', '-c:a', 'aac', '-c:s', 'mov_text', '-write_btrt', '0',
      '-metadata', 'title=元のタイトル', @source)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_merge_reproduces_duplicate_ffprobe_title
    source = snapshot(@source)
    remux
    API.open(@target) do |file|
      file.metadata = file.metadata.with(items: source.items.to_h { |item| [item.key, item] }, mdta: source.mdta)
      file.save!
    end
    assert_equal '元のタイトル;元のタイトル', tags(@target).fetch('title')
  end

  def test_direct_assignment_removes_destination_only_values
    source = snapshot(@source)
    remux
    before = preserved(@target)
    save_snapshot(source)
    actual = snapshot(@target)
    assert_equal source.items, actual.items, '通常itemの型・値・順序を保つ'
    assert_empty actual.mdta.fetch('destination-only', []), '復元元にない値を残さない'
    assert_equal '元のタイトル', tags(@target).fetch('title')
    assert_equal before, preserved(@target)
  end

  def test_title_only_direct_assignment_is_also_complete_replacement
    # titleだけなら保存先を残す特別なmerge経路へ入る問題も検出する。
    source = snapshot(@source).without(items: ['©too'])
    remux
    save_snapshot(source)
    assert_empty snapshot(@target).mdta.fetch('destination-only', [])
    assert_equal '元のタイトル', tags(@target).fetch('title')
  end

  def test_arbitrary_mdta_preserves_type_locale_bytes_order_and_duplicates
    remux
    expected = API::MetadataSnapshot.new(mdta: {
      'com.apple.quicktime.location.ISO6709' => typed_values,
      'custom.binary' => typed_values, 'empty' => []
    })
    before = preserved(@target)
    save_snapshot(expected)
    actual = snapshot(@target)
    expected.mdta.each { |key, values| assert_equal values, actual.mdta.fetch(key) }
    assert_empty actual.items
    assert_empty actual.mdta.fetch('title', [])
    assert_empty actual.mdta.fetch('destination-only', [])
    assert_equal before, preserved(@target)
  end

  def test_captured_purl_snapshot_with_without_survives_cross_context_restore
    inject_purl
    original = sha(@source)
    source = snapshot(@source).with(properties: { comment: '保持' }).without(properties: [:genre])
    remux
    before = preserved(@target)
    saved = save_snapshot(source)
    actual = snapshot(@target)
    assert_equal actual, saved[:snapshots][:metadata]
    assert_nil saved[:snapshots][:metadata].item('purl'), '入力の通常purlを期待値のまま返さない'
    assert_equal actual.mdta.fetch('purl'), saved[:snapshots][:metadata].mdta.fetch('purl')
    assert_equal source.items.reject { |item| item.key == 'purl' }, actual.items
    assert_equal [[1, 1041, 'https://example.test/feed'.b], [1, 7, 'https://example.test/feed'.b]],
      actual.mdta.fetch('purl').map { |value| [value.data_type, value.locale, value.data] }
    assert_empty actual.mdta.fetch('destination-only', [])
    assert_equal original, sha(@source)
    assert_equal before, preserved(@target)
    assert_equal '元のタイトル', tags(@target).fetch('title')
  end

  def test_rawless_item_merge_reports_specific_failure_without_changing_original
    inject_purl
    source = snapshot(@source)
    remux
    before = sha(@target)
    error = assert_raise(API::Error) do
      API.open(@target) do |file|
        file.metadata = file.metadata.with(items: source.items.to_h { |item| [item.key, item] }, mdta: source.mdta)
        file.save!
      end
    end
    assert_equal before, sha(@target), '失敗しても原本を変更しない'
    assert_equal :purl_raw_missing, error.code, 'genericなsaveへ原因を潰さない'
    assert_not_empty error.issues
    assert_equal false, error.committed
  end

  def test_proposed_context_layout_preserves_all_values_without_semantic_conversion
    inject_purl
    inject_artworks
    source = snapshot(@source).with(mdta: { 'custom.binary' => typed_values,
      'com.apple.quicktime.location.ISO6709' => typed_values })
    remux
    API.open(@target) do |file|
      file.chapters = API::ChapterSnapshot.new(nero: [API::Chapter.new(start_ms: 0, title: '保持する章')])
      file.save!
    end
    before = preserved(@target)
    # 製品writerの代用ではなく、提案するwire構造を検証する一時fixture。
    source_moov, = read_fixture_moov(@source)
    source_meta = fixture_child(fixture_child(source_moov, 'udta'), 'meta')
    edit_fixture(@target) do |moov|
      udta = fixture_child(moov, 'udta')
      mdta_meta = fixture_child(udta, 'meta')
      keys = source.mdta.keys.map { |key| atom_box('mdta', key.b) }.join.b
      fixture_child(mdta_meta, 'keys')[:data] = [0, source.mdta.size].pack('N2') + keys
      ilst = source.mdta.each_with_index.map do |(_key, values), index|
        data = values.map { |value| atom_box('data', [value.data_type, value.locale].pack('N2') + value.data) }.join.b
        atom_box([index + 1].pack('N'), data)
      end.join.b
      fixture_child(mdta_meta, 'ilst')[:children] = parse_boxes(ilst)
      udta[:children].unshift(source_meta)
    end
    actual = snapshot(@target)
    assert_equal source.items, actual.items, 'purl・画像を含む通常itemの型と値を維持'
    source_wire = metadata_item_bytes(@source)
    assert_equal source_wire, metadata_item_bytes(@target).first(source_wire.length)
    assert_equal source.mdta, actual.mdta, '任意mdtaの型・locale・bytes・順序・重複を維持'
    assert_equal before, preserved(@target)
    assert_equal '元のタイトル', tags(@target).fetch('title')
    assert_false actual.mdta.key?('destination-only')
  end

  def test_existing_mdir_destination_accepts_complete_mdir_snapshot
    destination = File.join(@dir, 'mdir-target.mp4')
    FileUtils.cp(@source, destination)
    expected = snapshot(@source).with(properties: { title: '別の題名', comment: '復元' })
    before = preserved(destination)
    API.open(destination) { |file| file.metadata = expected; file.save! }
    assert_equal expected.items, snapshot(destination).items
    assert_equal before, preserved(destination)
  end

  # nativeの署名実装とは独立に、映像・音声・字幕packetのbytes保持を確認する。
  def test_complete_metadata_and_both_chapter_formats_save_together
    remux
    expected = snapshot(@source).with(mdta: { 'custom.binary' => typed_values })
    before = packet_hashes(@target)
    API.open(@target) do |file|
      file.metadata = expected
      file.chapters = file.chapters.with(
        nero: [API::Chapter.new(start_ms: 0, title: 'Nero')],
        quicktime: [API::Chapter.new(start_ms: 0, title: 'QuickTime')])
      file.save!
    end
    actual = snapshot(@target)
    assert_equal expected.items, actual.items
    assert_equal expected.mdta, actual.mdta
    assert_equal before, packet_hashes(@target)
    API.open(@target) do |file|
      assert_equal ['Nero'], file.chapters.nero.map(&:title)
      assert_equal ['QuickTime'], file.chapters.quicktime.map(&:title)
      assert_equal :complete, file.diagnose(:metadata)[:status]
    end
  end

  def test_invalid_chunk_offsets_are_rejected_without_changing_original
    inject_purl
    source = snapshot(@source)
    remux
    edit_fixture(@target) do |moov|
      each_fixture_atom([moov]) do |atom|
        next unless atom[:type] == 'stco'

        atom[:data][8, 4] = [File.size(@target) + 4096].pack('N')
        break
      end
    end
    before = sha(@target)
    API.open(@target) do |file|
      error = assert_raise(API::Error) { file.metadata = source; file.save! }
      assert_equal before, sha(@target)
      assert_equal false, error.committed
      assert_not_equal :save, error.code, error.message
      assert_not_empty error.issues
    end
  end

  def test_artworks_returns_symbols_and_preserves_all_images
    inject_artworks
    actual = snapshot(@source).artworks
    assert_equal [:jpeg, :png, :bmp, :jpeg], actual.map(&:format)
    assert_equal image_rows.map(&:last), actual.map(&:data)
  end

  def test_artworks_public_write_round_trip_preserves_order_and_duplicates
    inject_artworks
    source = snapshot(@source)
    remux
    API.open(@target) do |file|
      file.metadata = file.metadata.with(artworks: source.artworks)
      file.save!
    end
    actual = snapshot(@target).artworks
    assert_equal source.artworks, actual
  end

  { jpeg: 13, png: 14, bmp: 27 }.each do |format, wire_type|
    define_method("test_artwork_#{format}_is_readable") do
      row = image_rows.find { |type, _bytes| type == wire_type }
      inject_artworks(rows: [row])
      image = snapshot(@source).artworks.fetch(0)
      assert_equal format, image.format
      assert_equal row.last, image.data
    end
  end

  def test_unknown_artwork_format_uses_public_error_contract
    source = API::MetadataSnapshot.new(items: [API::MetadataItem.new(
      key: 'covr', kind: :cover_art_list, atom_data_type: 255, value: [[999, 'unknown'.b]])])
    error = assert_raise(API::Error) { source.artworks }
    assert_equal :unsupported_artwork, error.code
    assert_equal :validate, error.phase
    assert_equal false, error.committed
    assert_not_empty error.issues
  end

  private

  # 失敗は原因の公開属性と原本SHAを必ず記録し、単なるsave失敗で済ませない。
  def save_snapshot(expected)
    original = sha(@target)
    API.open(@target) { |file| file.metadata = expected; file.save! }
  rescue API::Error => error
    assert_equal original, sha(@target), '公開前の失敗では入力SHAが不変'
    flunk({ message: error.message, code: error.code, phase: error.phase,
      committed: error.committed, issues: error.issues, input_sha_unchanged: true }.inspect)
  end

  def snapshot(path)
    API.open(path) { |file| file.metadata }
  end

  def ffmpeg
    ENV.fetch('FFMPEG', '/Users/nasu/Bin/ffmpeg')
  end

  def run!(*command)
    output, error, status = Open3.capture3(*command)
    assert status.success?, "#{command.first} failed (#{status.exitstatus}): #{error}"
    [output, error]
  end

  def remux
    run!(ffmpeg, '-v', 'error', '-i', @source, '-map', '0:v:0', '-map', '0:a', '-map', '0:s',
      '-map', '0:s', '-c', 'copy', '-movflags', 'use_metadata_tags', '-write_btrt', '0',
      '-metadata', 'title=元のタイトル', '-metadata', 'destination-only=remove', @target)
  end

  def tags(path)
    output, warnings = run!(ENV.fetch('FFPROBE', '/Users/nasu/Bin/ffprobe'), '-v', 'warning',
      '-show_entries', 'format_tags', '-of', 'json', path)
    assert_not_match(/index.*out of range|1886745196/, warnings)
    JSON.parse(output).fetch('format').fetch('tags', {})
  end

  # chapter追加で変わるstream indexではなくtrack IDごとに元の媒体packetを比較する。
  def packet_hashes(path)
    output, = run!(ENV.fetch('FFPROBE', '/Users/nasu/Bin/ffprobe'), '-v', 'error',
      '-show_packets', '-show_streams', '-show_data_hash', 'sha256',
      '-show_entries', 'stream=index,id,codec_type:packet=stream_index,data_hash',
      '-of', 'json', path)
    data = JSON.parse(output)
    tracks = data.fetch('streams').select { |stream| %w[video audio subtitle].include?(stream['codec_type']) }
      .to_h { |stream| [stream.fetch('index'), stream.fetch('id')] }
    data.fetch('packets').select { |packet| tracks.key?(packet.fetch('stream_index')) }
      .group_by { |packet| tracks.fetch(packet.fetch('stream_index')) }
      .transform_values { |packets| packets.map { |packet| packet.fetch('data_hash') } }
  end

  # 製品のsignatureを使わず、mdat・trackの配置と字幕packetを独立に比較する。
  def preserved(path)
    roots = parse_boxes(File.binread(path))
    moov = roots.find { |atom| atom[:type] == 'moov' }
    tracks = fixture_tracks(moov).map do |track|
      each_fixture_atom([track]) do |atom|
        next unless %w[stco co64].include?(atom[:type])

        atom[:data] = atom[:data].byteslice(0, 8) + "\0".b * (atom[:data].bytesize - 8)
      end
      [fixture_track_id(track), render_boxes([fixture_child(track, 'mdia')])]
    end
    [roots.select { |atom| atom[:type] == 'mdat' }.map { |atom| Digest::SHA256.hexdigest(atom[:data]) },
     tracks, API.open(path) { |file| file.chapters }]
  end

  def metadata_item_bytes(path)
    moov, = read_fixture_moov(path)
    fixture_child(moov, 'udta')[:children].select { |node| node[:type] == 'meta' }.flat_map do |meta|
      fixture_child(meta, 'ilst')[:children].map { |item| render_boxes([item]) }
    end
  end

  def sha(path)
    Digest::SHA256.file(path).hexdigest
  end

  def typed_values
    [API::MdtaValue.new(data_type: 1, locale: 1041, data: '日本語'),
     API::MdtaValue.new(data_type: 33, locale: 7, data: "\0\xff".b),
     API::MdtaValue.new(data_type: 1, locale: 1041, data: '日本語')]
  end

  # raw型・localeは公開constructorで指定できないため、入力fixtureだけ独立parserで合成する。
  def inject_purl
    edit_fixture(@source) do |moov|
      meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
      values = [1041, 7].map { |locale| atom_box('data', [1, locale].pack('N2') + 'https://example.test/feed'.b) }.join.b
      fixture_child(meta, 'ilst')[:children] << parse_boxes(atom_box('purl', values)).first
    end
  end

  def inject_artworks(rows: image_rows)
    edit_fixture(@source) do |moov|
      meta = fixture_child(fixture_child(moov, 'udta'), 'meta')
      values = rows.map { |format, bytes| atom_box('data', [format, 0].pack('N2') + bytes) }.join.b
      fixture_child(meta, 'ilst')[:children] << parse_boxes(atom_box('covr', values)).first
    end
  end

  def image_rows
    @image_rows ||= begin
      jpeg = File.binread(File.expand_path('../data/globe_east_90.jpg', __dir__))
      paths = %w[png bmp].map { |format| File.join(@dir, "cover.#{format}") }
      paths.each do |path|
        run!(ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'color=size=16x16:duration=0.1',
          '-frames:v', '1', '-threads', '1', path)
      end
      [[13, jpeg], [14, File.binread(paths[0])], [27, File.binread(paths[1])], [13, jpeg]]
    end
  end
end
