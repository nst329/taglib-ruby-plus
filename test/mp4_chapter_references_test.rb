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
      track[:children].select { |a| a[:type] == 'tref' }.flat_map do |tref|
        chap = child(tref, 'chap')
        chap ? chap[:data].unpack('N*').map { |id| [track_id(track), id] } : []
      end
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

  # trefのまとまり・順序を独立parserで検証するためのfixture注入入口。
  def inject_groups(path, mapping)
    edit(path) do |_list, moov|
      moov[:children].select { |a| a[:type] == 'trak' }.each do |track|
        next unless mapping.key?(track_id(track))
        track[:children].reject! { |a| a[:type] == 'tref' }
        mapping.fetch(track_id(track)).each do |group|
          track[:children] << { type: 'tref', children: group.map { |type, ids| { type: type, data: ids.pack('N*') } } }
        end
      end
    end
  end

  def reference_groups(path)
    tracks(path).map do |track|
      [track_id(track), track[:children].select { |a| a[:type] == 'tref' }.map do |tref|
        tref[:children].map { |a| [a[:type], a[:data].unpack('N*')] }
      end]
    end
  end

  def test_multiple_trefs_both_orders_keep_quicktime_after_tag_save
    [false, true].each do |reverse|
      with_fixture(quicktime: true) do |path|
        source, target = references(path).first
        groups = [{ 'chap' => [0] }, { 'chap' => [target] }]
        groups.reverse! if reverse
        inject_groups(path, source => groups, 1 => [{ 'chap' => [0] }], 3 => [{ 'chap' => [0] }])
        TagLib::MP4::File.open(path, false) do |file|
          rows = file.chapter_reference_diagnostics.select { |r| r[:source_track_id] == source }
          assert_equal [0, 1], rows.map { |r| r[:tref_index] }
          assert_equal [reverse ? target : 0, reverse ? 0 : target], rows.map { |r| r[:target_track_id] }
        end
        repair_and_check(path, [[source, target]])
        TagLib::MP4::File.open(path, false) do |file|
          assert_equal chapters.take(2), file.chapter_snapshot.quicktime
          file.tag.title = '修復後のタグ保存'
          assert file.save
        end
        TagLib::MP4::File.open(path, false) { |f| assert_equal chapters.take(2), f.chapter_snapshot.quicktime }
      end
    end
  end

  def test_groups_duplicates_order_other_references_and_original_empty_atoms
    with_fixture(faststart: true) do |path|
      mapping = {
        1 => [{ 'chap' => [0] }, { 'chap' => [2, 0, 2, 3], 'hint' => [2, 2] }, { 'chap' => [3, 2] }],
        2 => [{}, { 'chap' => [] }, { 'chap' => [999], 'hint' => [1] }, { 'chap' => [1, 0, 3, 1] }],
        3 => [{ 'chap' => [0] }]
      }
      inject_groups(path, mapping)
      repair_and_check(path, [[1, 2], [1, 2], [1, 3], [1, 3], [1, 2], [2, 1], [2, 3], [2, 1]])
      assert_equal [[1, [[['chap', [2, 2, 3]], ['hint', [2, 2]]], [['chap', [3, 2]]]]],
                    [2, [[], [['chap', []]], [['hint', [1]]], [['chap', [1, 3, 1]]]]], [3, []]], reference_groups(path)
    end
  end

  def test_duplicate_track_id_is_rejected_without_modifying_original
    with_fixture do |path|
      inject(path, 2 => [0])
      edit(path) do |_list, moov|
        track = moov[:children].select { |a| a[:type] == 'trak' }[1]
        child(track, 'tkhd')[:data][12, 4] = [1].pack('N')
      end
      digest = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |f|
        assert_raise(TagLib::MP4::ChapterReferenceError) { f.remove_dangling_chapter_references }
      end
      assert_equal digest, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_cleanup_failure_preserves_cause_original_and_retry_plan
    with_fixture do |path|
      inject(path, 2 => [0])
      digest = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        file.remove_dangling_chapter_references
        file.define_singleton_method(:write_reference_copy) { |*_args| raise IOError, 'write fault' }
        original = FileUtils.method(:rm_f)
        FileUtils.define_singleton_method(:rm_f) { |*_args| raise IOError, 'cleanup fault' }
        begin
          error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
          assert_equal :cleanup, error.phase
          assert_equal :replace, error.cause.phase
          assert_match(/write fault/, error.cause.message)
          assert_equal false, error.committed
          assert_equal digest, Digest::SHA256.file(path).hexdigest
          assert_equal 1, Dir.glob("#{path}.taglib-mdta-*").size
        ensure
          FileUtils.define_singleton_method(:rm_f, original)
          file.singleton_class.remove_method(:write_reference_copy)
        end
        assert file.save
        assert_empty Dir.glob("#{path}.taglib-mdta-*")
      end
    end
  end

  # 時間のみを差し替え、サンプルとoffsetは保持する。異常例も補正期待値は作らない。
  def inject_timing(path, track_id_value, movie_scale:, movie_duration:, media_duration:, track_duration:, edits:)
    edit(path) do |_list, moov|
      movie = child(moov, 'mvhd')[:data]
      movie[0, 20] = [0x01000000].pack('N') + [0, 0].pack('Q>2') + [movie_scale].pack('N') + [movie_duration].pack('Q>')
      track = moov[:children].find { |t| t[:type] == 'trak' && track_id(t) == track_id_value }
      child(track, 'tkhd')[:data][20, 4] = [track_duration].pack('N')
      child(child(track, 'mdia'), 'mdhd')[:data][16, 4] = [media_duration].pack('N')
      stbl = child(child(child(track, 'mdia'), 'minf'), 'stbl')
      if media_duration == 3_640_937
        child(stbl, 'stts')[:data] = [0, 2, 15, 227_558, 1, 227_567].pack('N6')
      else
        child(stbl, 'stts')[:data] = [0, 2, 1, media_duration / 2, 1, media_duration - media_duration / 2].pack('N6')
      end
      track[:children].reject! { |a| a[:type] == 'edts' }
      if edits
        track[:children] << { type: 'edts', children: [{ type: 'elst', data: [0, edits.size].pack('N2') + edits.map { |d, t, r| [d, t, r].pack('Nl>l>') }.join.b }] }
      end
    end
  end

  def test_reported_timing_inconsistency_is_diagnosed_and_preserved
    with_fixture(quicktime: true) do |path|
      TagLib::MP4::File.open(path, false) do |file|
        # native writerが時刻0の空タイトルpaddingを加え、実サンプルを16件にする。
        file.set_chapters(Array.new(15) { |i| TagLib::MP4::Chapter.new((i + 1) * 50, "時間検証#{i}") }, style: :quicktime)
        assert file.save_chapters
      end
      source, target = references(path).first
      inject_timing(path, target, movie_scale: 441_000_000, movie_duration: 1_605_653_349_300,
        media_duration: 3_640_937, track_duration: 3_640_937, edits: [[0xd865c3b4, 0, 65_536]])
      inject_groups(path, source => [{ 'chap' => [0] }, { 'chap' => [target] }])
      before = TagLib::MP4::File.open(path, false) { |f| f.chapter_timing_diagnostics }
      assert_equal [:tkhd_elst_duration_mismatch, :elst_matches_movie_duration_low32], before.first[:observations]
      assert_equal({ sample_count: 16, duration: 3_640_937 }, before.first[:stts])
      assert_equal :not_attempted, before.first[:correction]
      assert_raise(FrozenError) { before.first[:movie][:duration] = 0 }
      repair_and_check(path, [[source, target]])
      after = TagLib::MP4::File.open(path, false) { |f| f.chapter_timing_diagnostics }
      assert_equal before, after
      TagLib::MP4::File.open(path, false) do |file|
        reader = TagLib::MP4.const_get(:ChapterReader).new(file)
        assert_equal :complete, reader.report[:quicktime][:status]
        assert_equal 15, reader.values[:quicktime].size
        assert_equal '時間検証0', reader.values[:quicktime].first.title
      end
      track = tracks(path).find { |t| track_id(t) == target }
      stsz = child(child(child(child(track, 'mdia'), 'minf'), 'stbl'), 'stsz')[:data]
      assert_equal 16, stsz.byteslice(8, 4).unpack1('N')
    end
  end

  def test_normal_edit_lists_are_observed_without_false_duration_mismatch
    with_fixture(quicktime: true) do |path|
      _, target = references(path).first
      [nil, [[600, 100, 65_536]], [[200, -1, 65_536], [300, 0, 65_536]], [[400, 0, 131_072]], [[400, 0, 0]]].each do |edits|
        duration = edits ? edits.sum(&:first) : 1000
        inject_timing(path, target, movie_scale: 1000, movie_duration: 1000,
          media_duration: 1000, track_duration: duration, edits: edits)
        report = TagLib::MP4::File.open(path, false) { |f| f.chapter_timing_diagnostics.first }
        assert_empty report[:observations]
        assert_equal edits&.map { |d, t, r| { version: 0, segment_duration: d, media_time: t, media_rate: r } }, report[:edits]
      end
    end
  end

  def test_co64_multiple_trefs_four_byte_removal_moves_offsets
    with_fixture(faststart: true) do |path|
      inject_groups(path, 2 => [{ 'chap' => [1, 0] }, { 'hint' => [3] }])
      edit(path) do |list, _moov|
        walk(list) do |a|
          next unless a[:type] == 'stco'
          a[:type] = 'co64'
          a[:data] = a[:data].byteslice(0, 8) + a[:data].byteslice(8..).unpack('N*').pack('Q>*')
        end
      end
      size = File.size(path)
      repair_and_check(path, [[2, 1]])
      assert_equal size + 8, File.size(path)
      assert_equal [[1, []], [2, [[['chap', [1]]], [['hint', [3]]]]], [3, []]], reference_groups(path)
    end
  end

  def test_verification_rejects_regrouping_even_with_identical_flat_references
    with_fixture do |path|
      inject_groups(path, 2 => [{ 'chap' => [1, 0] }, { 'chap' => [3] }])
      digest = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        file.remove_dangling_chapter_references
        original = file.method(:write_reference_copy)
        fixture = self
        file.define_singleton_method(:write_reference_copy) do |plan, source, destination|
          original.call(plan, source, destination)
          fixture.inject_groups(destination, 2 => [{ 'chap' => [1, 3] }])
          Digest::SHA256.file(destination).hexdigest
        end
        error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
        assert_equal :verify, error.phase
      end
      assert_equal digest, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_timing_version_one_and_truncated_edit_list
    with_fixture(quicktime: true) do |path|
      _, target = references(path).first
      inject_timing(path, target, movie_scale: 1000, movie_duration: 1000,
        media_duration: 1000, track_duration: 1000, edits: [[1000, 0, 65_536]])
      edit(path) do |_list, moov|
        track = moov[:children].find { |a| a[:type] == 'trak' && track_id(a) == target }
        %w[tkhd mdhd].each do |type|
          atom = type == 'tkhd' ? child(track, type) : child(child(track, 'mdia'), type)
          data = atom[:data]
          suffix = type == 'tkhd' ? 24 : 20
          fields = type == 'tkhd' ? data.byteslice(12, 8) : data.byteslice(12, 4)
          atom[:data] = [0x01000000 | (data.unpack1('N') & 0xffffff)].pack('N') + [0, 0].pack('Q>2') + fields + [1000].pack('Q>') + data.byteslice(suffix..)
        end
        child(child(track, 'edts'), 'elst')[:data] = [0x01000000, 2].pack('N2') + [200, -1, 65_536, 800, 100, 65_536].pack('Q>q>l>Q>q>l>')
      end
      report = TagLib::MP4::File.open(path, false) { |f| f.chapter_timing_diagnostics.first }
      assert_empty report[:observations]
      assert_equal 1, report[:media][:version]
      assert_equal 1, report[:track_header][:version]
      assert_equal [-1, 100], report[:edits].map { |e| e[:media_time] }
      edit(path) do |_list, moov|
        track = moov[:children].find { |a| a[:type] == 'trak' && track_id(a) == target }
        child(child(track, 'edts'), 'elst')[:data] = [0x01000000, 2].pack('N2')
      end
      digest = Digest::SHA256.file(path).hexdigest
      TagLib::MP4::File.open(path, false) do |file|
        assert_raise(TagLib::MP4::ChapterReferenceError) { file.chapter_timing_diagnostics }
      end
      assert_equal digest, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_reopen_failure_reports_committed_copy_and_can_be_opened_again
    with_fixture(quicktime: true) do |path|
      source, target = references(path).first
      inject_groups(path, source => [{ 'chap' => [0] }, { 'chap' => [target] }])
      # 保存フローが旧native handleをcloseするため、失敗後に二重closeしない。
      file = TagLib::MP4::File.new(path, false)
      file.remove_dangling_chapter_references
      file.define_singleton_method(:initialize) { |*_args| raise IOError, 'reopen fault' }
      error = assert_raise(TagLib::MP4::MdtaSaveError) { file.save }
      assert_equal :reopen, error.phase
      assert_equal true, error.committed
      assert_empty Dir.glob("#{path}.taglib-mdta-*")
      TagLib::MP4::File.open(path, false) do |read|
        assert_empty read.remove_dangling_chapter_references
        assert_equal chapters.take(2), read.chapter_snapshot.quicktime
      end
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
