# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'digest'
require 'open3'
require 'json'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'

# 合成した映像・音声・字幕MP4を、独立したatom解析と別handleで保存後まで検証する。
class MP4ChapterReferencesTest < Test::Unit::TestCase
  CONTAINERS = %w[moov trak mdia minf stbl tref udta edts dinf].freeze

  def box(type, payload)
    [payload.bytesize + 8].pack('N') + type.b + payload
  end

  # fixture用の独立parser。製品側のparserや修復計画を期待値生成に使わない。
  def atoms(data)
    result = []
    offset = 0
    while offset < data.bytesize
      size, type = data.byteslice(offset, 8).unpack('Na4')
      header = 8
      if size == 1
        size = data.byteslice(offset + 8, 8).unpack1('Q>')
        header = 16
      elsif size.zero?
        size = data.bytesize - offset
      end
      raise 'fixture atom boundary' if size < header || offset + size > data.bytesize
      payload = data.byteslice(offset + header, size - header)
      result << { type: type, data: payload, children: CONTAINERS.include?(type) ? atoms(payload) : nil }
      offset += size
    end
    result
  end

  def render(list)
    list.map { |a| box(a[:type], a[:children] ? render(a[:children]) : a[:data]) }.join.b
  end

  def child(atom, type)
    atom[:children].find { |a| a[:type] == type }
  end

  def walk(list, &block)
    list.each { |a| block.call(a); walk(a[:children], &block) if a[:children] }
  end

  # fixtureへの注入時にも、moov移動後のchunk位置を独立して補正する。
  def edit(path)
    original = File.binread(path)
    list = atoms(original)
    moov = list.find { |a| a[:type] == 'moov' }
    old_end = render(list.take_while { |a| a != moov }).bytesize + render([moov]).bytesize
    yield list, moov
    delta = render(list).bytesize - original.bytesize
    walk(list) do |a|
      next unless %w[stco co64].include?(a[:type])
      format = a[:type] == 'stco' ? 'N*' : 'Q>*'
      values = a[:data].byteslice(8..).unpack(format).map { |v| v >= old_end ? v + delta : v }
      a[:data] = a[:data].byteslice(0, 8) + values.pack(format)
    end
    File.binwrite(path, render(list))
  end

  def tracks(path)
    atoms(File.binread(path)).find { |a| a[:type] == 'moov' }[:children].select { |a| a[:type] == 'trak' }
  end

  def track_id(track)
    header = child(track, 'tkhd')[:data]
    header.byteslice(header.getbyte(0) == 1 ? 20 : 12, 4).unpack1('N')
  end

  def references(path)
    tracks(path).flat_map do |track|
      tref = child(track, 'tref')
      chap = tref && child(tref, 'chap')
      chap ? chap[:data].unpack('N*').map { |id| [track_id(track), id] } : []
    end
  end

  def inject(path, mapping)
    edit(path) do |_list, moov|
      moov[:children].select { |a| a[:type] == 'trak' }.each do |track|
        next unless mapping.key?(track_id(track))
        tref = child(track, 'tref')
        unless tref
          tref = { type: 'tref', children: [] }
          track[:children] << tref
        end
        tref[:children].reject! { |a| a[:type] == 'chap' }
        tref[:children] << { type: 'chap', data: mapping.fetch(track_id(track)).pack('N*') }
      end
    end
  end

  def chapters
    Array.new(16) { |i| TagLib::MP4::Chapter.new(start_time: i * 50, title: "章#{i}") }
  end

  def with_fixture(quicktime: false, faststart: false)
    Dir.mktmpdir('dangling-chapter-') do |dir|
      subtitle = File.join(dir, 'captions.srt')
      File.write(subtitle, "1\n00:00:00,000 --> 00:00:00,800\n日本語字幕\n")
      path = File.join(dir, 'synthetic.mp4')
      _, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
        '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1',
        '-f', 'lavfi', '-i', 'sine=duration=1', '-i', subtitle,
        '-map', '0:v', '-map', '1:a', '-map', '2:s', '-c:v', 'mpeg4', '-c:a', 'aac', '-c:s', 'mov_text',
        '-metadata', 'title=保持する日本語', '-movflags', faststart ? '+faststart+use_metadata_tags' : '+use_metadata_tags', path)
      assert status.success?, error
      TagLib::MP4::File.open(path, false) do |file|
        snapshot = file.tag.metadata_snapshot.with(mdta: { 'binary' => [[33, 7, "\0\xff".b], [33, 7, "\0\xff".b]], 'empty-key' => [] })
        file.tag.restore_metadata_snapshot(snapshot)
        file.tag.item_map.insert('covr', TagLib::MP4::Item.from_cover_art_list([
          TagLib::MP4::CoverArt.new(TagLib::MP4::CoverArt::JPEG, File.binread(File.join(__dir__, 'data/globe_east_90.jpg')))]))
        file.set_chapters(chapters, style: :nero)
        file.set_chapters(chapters.take(2), style: :quicktime) if quicktime
        assert file.save
      end
      yield path
    end
  end

  # 保持対象はraw leaf bytes・全mdat・全track IDで独立して比較する。
  def retained(path)
    list = atoms(File.binread(path))
    leaves = []
    walk(list) do |a|
      next if a[:children] || %w[chap stco co64 free skip].include?(a[:type])
      leaves << [a[:type], a[:data].bytesize, Digest::SHA256.hexdigest(a[:data])]
    end
    [tracks(path).map { |t| track_id(t) }, leaves]
  end

  def repair_and_check(path, expected)
    before = retained(path)
    metadata = TagLib::MP4::File.open(path, false) { |f| f.tag.metadata_snapshot }
    TagLib::MP4::File.open(path, false) do |file|
      digest = Digest::SHA256.file(path).hexdigest
      removed = file.remove_dangling_chapter_references
      assert removed.all? { |r| r[:status] == :missing && !r[:target_exists] }
      assert removed.frozen?
      assert_equal digest, Digest::SHA256.file(path).hexdigest, '除去計画だけでは原本を書き換えない'
      assert_empty file.remove_dangling_chapter_references
      assert file.save_chapters
    end
    assert_equal expected, references(path), '保存後のatom構造'
    assert_equal before, retained(path), '全トラック・media・Nero・metadata・artworkのraw保持'
    TagLib::MP4::File.open(path, false) do |read|
      assert_equal chapters, read.nero_chapters
      assert metadata.structure_equal?(read.tag.metadata_snapshot)
      assert_empty read.remove_dangling_chapter_references
    end
  end

  def test_nero_only_zero_references_on_video_audio_subtitle
    with_fixture do |path|
      inject(path, 1 => [0], 2 => [0], 3 => [0])
      TagLib::MP4::File.open(path, false) do |file|
        report = file.chapter_reference_diagnostics
        assert_equal [[1, 0], [2, 0], [3, 0]], report.map { |r| [r[:source_track_id], r[:target_track_id]] }
        assert_raise(FrozenError) { report.first[:target_track_id] = 2 }
        assert_empty file.quicktime_chapters
        assert_equal chapters, file.nero_chapters
      end
      repair_and_check(path, [])
    end
  end

  # FFmpegの字幕titleに付随するudta/nameをopaque payloadとして保持する。
  def test_subtitle_udta_name_is_preserved_during_reference_repair
    with_fixture do |path|
      edit(path) do |_list, moov|
        subtitle = moov[:children].select { |a| a[:type] == 'trak' }.find { |t| track_id(t) == 3 }
        udta = child(subtitle, 'udta')
        unless udta
          udta = { type: 'udta', children: [] }
          subtitle[:children] << udta
        end
        udta[:children] << { type: 'name', data: '日本語（SpeechAnalyzer）'.b }
      end
      inject(path, 1 => [0], 2 => [0], 3 => [0])
      repair_and_check(path, [])
      subtitle = tracks(path).find { |track| track_id(track) == 3 }
      assert_equal '日本語（SpeechAnalyzer）'.b, child(child(subtitle, 'udta'), 'name')[:data]
    end
  end

  def test_nonzero_missing_references_and_duplicates
    with_fixture do |path|
      inject(path, 1 => [99, 99], 2 => [999])
      repair_and_check(path, [])
    end
  end

  def test_existing_inappropriate_target_is_preserved_in_mixed_payload
    with_fixture(faststart: true) do |path|
      inject(path, 2 => [1, 99])
      TagLib::MP4::File.open(path, false) do |file|
        report = file.chapter_reference_diagnostics
        assert_equal [:inappropriate, :missing], report.map { |r| r[:status] }
        assert_equal [true, false], report.map { |r| r[:target_exists] }
      end
      repair_and_check(path, [[2, 1]])
      # moov先頭・4 bytes除去による8 bytes移動後もデコードできる。
      _, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error', '-i', path, '-map', '0:v', '-map', '0:a', '-f', 'null', '-')
      assert status.success?, error
    end
  end

  def test_valid_quicktime_mixed_with_missing_reference
    with_fixture(quicktime: true) do |path|
      valid = references(path).first
      assert_not_nil valid
      inject(path, valid.first => [valid.last, 0])
      repair_and_check(path, [valid])
      TagLib::MP4::File.open(path, false) { |f| assert_equal chapters.take(2), f.quicktime_chapters }
    end
  end

  def test_no_references_and_valid_quicktime_are_noop
    [false, true].each do |quicktime|
      with_fixture(quicktime: quicktime) do |path|
        digest = Digest::SHA256.file(path).hexdigest
        TagLib::MP4::File.open(path, false) do |file|
          assert_empty file.remove_dangling_chapter_references
          assert_empty file.remove_dangling_chapter_references
          assert_equal quicktime ? [:chapter_candidate] : [], file.chapter_reference_diagnostics.map { |r| r[:status] }
          assert file.save_chapters
        end
        assert_equal digest, Digest::SHA256.file(path).hexdigest
      end
    end
  end

  def test_co64_offsets_and_non_chapter_track_references_are_preserved
    with_fixture(faststart: true) do |path|
      edit(path) do |list, moov|
        track = moov[:children].find { |a| a[:type] == 'trak' && track_id(a) == 2 }
        track[:children] << { type: 'tref', children: [{ type: 'hint', data: [1].pack('N') }] }
        walk(list) do |a|
          next unless a[:type] == 'stco'
          a[:type] = 'co64'
          a[:data] = a[:data].byteslice(0, 8) + a[:data].byteslice(8..).unpack('N*').pack('Q>*')
        end
      end
      inject(path, 2 => [1, 999])
      repair_and_check(path, [[2, 1]])
      assert_equal [1].pack('N'), child(child(tracks(path)[1], 'tref'), 'hint')[:data]
    end
  end

  def test_extended_moov_header_and_missing_first_reference
    with_fixture(quicktime: true) do |path|
      valid = references(path).first
      inject(path, valid.first => [0, valid.last, 999, valid.last])
      data = File.binread(path)
      moov_position = data.index('moov') - 4
      size = data.byteslice(moov_position, 4).unpack1('N')
      old_end = moov_position + size
      list = atoms(data)
      walk(list) do |a|
        next unless %w[stco co64].include?(a[:type])
        format = a[:type] == 'stco' ? 'N*' : 'Q>*'
        offsets = a[:data].byteslice(8..).unpack(format).map { |v| v >= old_end ? v + 8 : v }
        a[:data] = a[:data].byteslice(0, 8) + offsets.pack(format)
      end
      data = render(list)
      data[moov_position, 8] = [1].pack('N') + 'moov' + [size + 8].pack('Q>')
      File.binwrite(path, data)
      repair_and_check(path, [valid, valid])
    end
  end

  def test_bad_chunk_boundary_and_external_data_reference_fail
    [:chunk, :external].each do |kind|
      with_fixture do |path|
        inject(path, 2 => [0])
        edit(path) do |list, _moov|
          changed = false
          walk(list) do |a|
            next if changed
            if kind == :chunk && a[:type] == 'stco'
              a[:data][8, 4] = [0].pack('N')
              changed = true
            elsif kind == :external && a[:type] == 'dref'
              a[:data][-4, 4] = [0].pack('N')
              changed = true
            end
          end
        end
        digest = Digest::SHA256.file(path).hexdigest
        TagLib::MP4::File.open(path, false) do |file|
          assert_raise(TagLib::MP4::ChapterReferenceError) { file.remove_dangling_chapter_references }
        end
        assert_equal digest, Digest::SHA256.file(path).hexdigest
      end
    end
  end

  def test_verification_and_replace_failures_keep_original
    [:verify, :verify_atom, :replace].each do |phase|
      with_fixture do |path|
        inject(path, 2 => [0])
        digest = Digest::SHA256.file(path).hexdigest
        TagLib::MP4::File.open(path, false) do |file|
          file.remove_dangling_chapter_references
          if phase != :replace
            original = file.method(:write_reference_copy)
            file.define_singleton_method(:write_reference_copy) do |plan, source, destination|
              original.call(plan, source, destination)
              # コピーのmediaを壊し、壊れたbytesのhashを返しても保持検証で拒否する。
              data = File.binread(destination)
              if phase == :verify_atom
                position = data.index('moov') - 4
                data[position, 4] = [0xffff_ffff].pack('N')
              else
                position = data.index('mdat') + 4
                data.setbyte(position, data.getbyte(position) ^ 0xff)
              end
              File.binwrite(destination, data)
              Digest::SHA256.file(destination).hexdigest
            end
            error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
          else
            original = FileUtils.method(:mv)
            FileUtils.define_singleton_method(:mv) { |_from, _to| raise IOError, 'injected rename failure' }
            begin
              error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
            ensure
              FileUtils.define_singleton_method(:mv, original)
            end
          end
          assert_equal phase == :verify_atom ? :verify : phase, error.phase
          assert_equal false, error.committed
          assert_equal digest, Digest::SHA256.file(path).hexdigest
          assert_empty Dir.glob("#{path}.taglib-mdta-*")
        end
      end
    end
  end

  def test_file_mode_and_save_entry_point_are_preserved
    with_fixture do |path|
      inject(path, 1 => [0])
      File.chmod(0o600, path)
      TagLib::MP4::File.open(path, false) { |f| f.remove_dangling_chapter_references; assert f.save }
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_empty references(path)
    end
  end

  def test_malformed_atom_and_payload_fail_without_changes
    [:boundary, :payload, :duplicate, :unsupported].each do |kind|
      with_fixture do |path|
        inject(path, 2 => [0])
        edit(path) do |_list, moov|
          track = moov[:children].find { |a| a[:type] == 'trak' && track_id(a) == 2 }
          tref = child(track, 'tref')
          case kind
          when :payload then child(tref, 'chap')[:data] = 'bad'.b
          when :duplicate then tref[:children] << child(tref, 'chap').dup
          when :unsupported then moov[:children] << { type: 'mvex', data: ''.b }
          end
        end
        if kind == :boundary
          data = File.binread(path)
          offset = data.index('chap') - 4
          data[offset, 4] = [0xffff_ffff].pack('N')
          File.binwrite(path, data)
        end
        digest = Digest::SHA256.file(path).hexdigest
        TagLib::MP4::File.open(path, false) do |file|
          assert_raise(TagLib::MP4::ChapterReferenceError) { file.chapter_reference_diagnostics }
          assert_raise(TagLib::MP4::ChapterReferenceError) { file.remove_dangling_chapter_references }
        end
        assert_equal digest, Digest::SHA256.file(path).hexdigest
      end
    end
  end

  def test_save_failure_keeps_original_and_pending_plan_for_retry
    with_fixture do |path|
      inject(path, 2 => [0])
      digest = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        assert_equal 1, file.remove_dangling_chapter_references.size
        file.define_singleton_method(:write_reference_copy) { |_plan, _source, destination| File.binwrite(destination, 'broken'); raise IOError, 'injected write failure' }
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
        assert_equal false, error.committed
        assert_equal digest, Digest::SHA256.file(path).hexdigest
        assert_empty Dir.glob("#{path}.taglib-mdta-*")
        file.singleton_class.remove_method(:write_reference_copy)
        assert file.save_chapters
      end
      assert_empty references(path)
    end
  end

  def test_source_changes_and_pending_edits_are_rejected
    with_fixture do |path|
      inject(path, 2 => [0])
      TagLib::MP4::File.open(path, false) do |file|
        file.tag.title = '未保存'
        assert_raise(TagLib::MP4::ChapterReferenceError) { file.remove_dangling_chapter_references }
      end
      TagLib::MP4::File.open(path, false) do |file|
        file.remove_dangling_chapter_references
        file.set_chapters([], style: :nero)
        assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
      end
      TagLib::MP4::File.open(path, false) do |file|
        file.remove_dangling_chapter_references
        File.open(path, 'ab') { |io| io.write(box('free', ''.b)) }
        digest = Digest::SHA256.file(path).hexdigest
        assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
        assert_equal digest, Digest::SHA256.file(path).hexdigest
      end
    end
  end

  def test_repair_plan_is_immutable_and_survives_closed_handle
    with_fixture do |path|
      inject(path, 2 => [0])
      plan = TagLib::MP4::File.open(path, false) do |file|
        file.remove_dangling_chapter_references
        file.instance_variable_get(:@chapter_reference_repair)
      end
      assert plan.frozen?
      assert_raise(FrozenError) { plan.removed.first[:target_track_id] = 1 }
      assert_raise(FrozenError) { plan.source_digest << 'x' }
      assert_raise(FrozenError) { plan.instance_variable_set(:@moov_start, 0) }
      assert_equal false, plan.instance_variables.any? { |name| plan.instance_variable_get(name).is_a?(TagLib::MP4::File) }
      output = File.join(File.dirname(path), 'detached.mp4')
      plan.write_copy(path, output)
      assert_empty references(output)
      assert_equal [[2, 0]], references(path)
      assert_equal retained(path), retained(output)
    end
  end

  def test_diagnosis_and_saved_copy_verification_do_not_build_repair_bytes
    with_fixture do |path|
      inject(path, 2 => [0])
      TagLib::MP4::File.open(path, false) do |file|
        file.remove_dangling_chapter_references
        parser = TagLib::MP4::ChapterReferences
        original = parser.instance_method(:replacement)
        parser.define_method(:replacement) { raise 'diagnosis must not render repair bytes' }
        begin
          assert_equal [0], file.chapter_reference_diagnostics.map { |r| r[:target_track_id] }
          assert file.save_chapters
        ensure
          parser.define_method(:replacement, original)
          parser.send(:private, :replacement)
        end
      end
      assert_empty references(path)
    end
  end

  def test_regular_read_and_save_do_not_automatically_repair
    with_fixture do |path|
      inject(path, 2 => [0])
      digest = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        file.nero_chapters
        file.quicktime_chapters
        assert_raise(TagLib::MP4::MdtaSaveError) { file.save_chapters }
      end
      assert_equal [[2, 0]], references(path)
      assert_equal digest, Digest::SHA256.file(path).hexdigest
    end
  end

  if ENV['LEGACY_CHAPTER_REPRO']
    # 2.3.2.9の公開APIで「trueなのに欠落参照が残る」現象を再現する専用実行。
    def test_legacy_remove_success_leaves_dangling_reference
      with_fixture do |path|
        inject(path, 1 => [0], 2 => [0], 3 => [0])
        digest = Digest::SHA256.file(path).hexdigest
        TagLib::MP4::File.open(path, false) do |file|
          file.remove_chapters(style: :quicktime)
          assert file.save_chapters
        end
        assert_equal digest, Digest::SHA256.file(path).hexdigest
        assert_equal [[1, 0], [2, 0], [3, 0]], references(path)
        TagLib::MP4::File.open(path, false) { |f| assert_equal chapters, f.nero_chapters }
      end
    end
  end
end
