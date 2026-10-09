# frozen_string_literal: true

module TagLib::MP4
  # 参照診断・修復計画の拒否理由。保存失敗は既存のMdtaSaveErrorで報告する。
  class ChapterReferenceError < ArgumentError
    attr_reader :code

    def initialize(message, code: :malformed)
      @code = code
      super(message)
    end
  end

  # 原本の参照と保持対象を解析する。変更bytesの生成は明示的な計画作成に限定する。
  class ChapterReferences
    MAX_MOOV_BYTES = 64 * 1024 * 1024
    UNSUPPORTED = %w[moof mvex mfra cmov rmra uuid saio saiz senc iloc].freeze
    # 位置依存データを見落とさないため、編集対象の外側も対応済みの構造に限定する。
    STRUCTURES = {
      root: %w[ftyp moov mdat free skip wide],
      'moov' => %w[mvhd trak udta meta iods free skip],
      'trak' => %w[tkhd tref edts mdia udta free skip],
      'mdia' => %w[mdhd hdlr minf free skip],
      'minf' => %w[vmhd smhd gmhd nmhd hdlr dinf stbl free skip],
      'stbl' => %w[stsd stts ctts cslg stsc stsz stz2 stco co64 stss stps sdtp sgpd sbgp padb stdp free skip],
      'edts' => %w[elst], 'dinf' => %w[dref], 'udta' => %w[chpl meta name free skip]
    }.freeze
    attr_reader :report, :removed, :source_digest, :preservation_signature, :timing_report

    def initialize(file, timing: false, ignore_metadata: false)
      @ignore_metadata = ignore_metadata
      @file = file
      ::File.open(file.name, 'rb') do |io|
        initial_digest = Digest::SHA256.file(file.name).hexdigest
        @io = io
        @atoms = file.send(:parse_mp4_atoms, io, 0, io.stat.size)
        @moov = one(@atoms, 'moov')
        fail!('moov exceeds repair limit', :unsupported) if length(@moov) > MAX_MOOV_BYTES
        walk(@atoms) { |atom| fail!("unsupported #{atom[:type]} structure", :unsupported) if UNSUPPORTED.include?(atom[:type]) }
        validate_structure(@atoms, :root)
        @mdat_ranges = @atoms.select { |a| a[:type] == 'mdat' }.map { |a| [a[:payload_offset], a[:end_offset]] }
        @raw = bytes(@moov)
        @edits = {}
        @offset_tables = {}
        # [source_track_id, 元tref_index] => 保存後tref_index。例: [2, 1] => 0。
        @tref_positions = {}
        @report = collect_references
        collect_offsets
        @timing_report = MetadataSnapshot.copy(collect_timing) if timing
        prepare_atom_edits
        @preservation_signature = MetadataSnapshot.copy(preservation(@atoms))
        @removed = @report.select { |r| r[:status] == :missing }
        io.rewind
        @source_digest = Digest::SHA256.file(io).hexdigest
        fail!('source changed during reference analysis', :source_changed) unless @source_digest == initial_digest
      end
      @report = MetadataSnapshot.copy(@report)
      @removed = MetadataSnapshot.copy(@removed)
      @source_digest.freeze
    rescue MdtaSaveError, SystemCallError, IOError => error
      raise ChapterReferenceError, error.message
    ensure
      @io = nil
    end

    # 保存後の位置を順序付きで計算する。元位置は公開report/removedに保持する。
    def retained_report
      positions = Hash.new(0)
      report.reject { |r| r[:status] == :missing }.map do |r|
        key = [r[:source_track_id], r[:tref_index]]
        index = positions[key]
        positions[key] += 1
        r.merge(tref_index: @tref_positions.fetch(key), reference_index: index)
      end
    end

    # 欠落がある場合だけ、handleから独立した不変の保存計画を生成する。
    def repair_plan
      return nil if removed.empty?

      ChapterReferenceRepair.new(moov_start: @moov[:offset], moov_end: @moov[:end_offset],
                                 replacement: replacement, source_digest: source_digest,
                                 removed: removed, retained_report: retained_report,
                                 preservation_signature: preservation_signature)
    end

    private

    # 派生editorが検証済みatomだけを変更するための解析中hook。
    def prepare_atom_edits; end

    def fail!(message, code = :malformed)
      raise ChapterReferenceError.new(message, code: code)
    end

    def one(atoms, type, required: true)
      selected = atoms.select { |a| a[:type] == type }
      fail!("duplicate #{type} atom", :unsupported) if selected.size > 1
      fail!("missing #{type} atom") if selected.empty? && required
      selected.first
    end

    def child(atom, type, required: true)
      one(atom[:children], type, required: required)
    end

    def length(atom)
      atom[:end_offset] - atom[:offset]
    end

    def bytes(atom)
      @file.send(:read_mp4_bytes, @io, atom[:offset], length(atom))
    end

    def payload(atom)
      @file.send(:read_mp4_bytes, @io, atom[:payload_offset], atom[:end_offset] - atom[:payload_offset])
    end

    def walk(atoms, &block)
      atoms.each do |atom|
        block.call(atom)
        walk(atom[:children], &block)
      end
    end

    def validate_structure(atoms, parent)
      atoms.each do |atom|
        supported = STRUCTURES[parent]
        fail!("unsupported #{parent}/#{atom[:type]}", :unsupported) if supported && !supported.include?(atom[:type])
        if atom[:type] == 'meta'
          fail!('unsupported meta version', :unsupported) unless payload(atom).byteslice(0, 4) == "\0".b * 4
          children = @file.send(:parse_mp4_atoms, @io, atom[:payload_offset] + 4, atom[:end_offset])
          fail!('unsupported meta structure', :unsupported) unless children.all? { |a| %w[hdlr keys ilst free].include?(a[:type]) }
        end
        validate_structure(atom[:children], atom[:type])
      end
    end

    # 欠落ID除去後のchapを含む構造とbytesを比較する。chunk位置はmdat内の相対位置で比較する。
    def preservation(atoms)
      atoms.filter_map do |atom|
        next if %w[free skip].include?(atom[:type]) || deleted_reference_atom?(atom) || (@ignore_metadata && atom[:type] == 'meta')
        value = preservation_value(atom)
        [atom[:type], value]
      end
    end

    def preservation_value(atom)
      return @edits.fetch(atom[:offset]) if @edits.key?(atom[:offset])
      return payload(atom).unpack('N*') if atom[:type] == 'chap'
      return offset_signature(@offset_tables.fetch(atom[:offset])) if @offset_tables.key?(atom[:offset])
      return preservation(atom[:children]) if atom[:children].any?

      payload_signature(atom)
    end

    # 絶対位置の変更を許しつつ、同じmdat内の同じmedia bytesを指すことを比較する。
    def offset_signature(table)
      header, offsets, width = table
      relative = offsets.map do |offset|
        index = @mdat_ranges.index { |first, last| offset >= first && offset < last }
        [index, offset - @mdat_ranges.fetch(index).first]
      end
      [header, width, relative]
    end

    # 大きなmdatも全読込せず、保持対象payloadのサイズとhashを取得する。
    def payload_signature(atom)
      digest = Digest::SHA256.new
      @io.seek(atom[:payload_offset])
      size = atom[:end_offset] - atom[:payload_offset]
      remaining = size
      while remaining.positive?
        data = @io.read([remaining, 64 * 1024].min)
        fail!('truncated preservation payload') unless data && !data.empty?
        digest.update(data)
        remaining -= data.bytesize
      end
      [size, digest.hexdigest]
    end

    def track_info(track)
      header = payload(child(track, 'tkhd'))
      version = header.getbyte(0)
      fail!('unsupported tkhd version', :unsupported) unless [0, 1].include?(version)
      fail!('truncated tkhd') if header.bytesize < (version == 1 ? 96 : 84)
      id = header.byteslice(version == 1 ? 20 : 12, 4).unpack1('N')
      fail!('zero actual track ID') if id.zero?
      mdia = child(track, 'mdia')
      handler = payload(child(mdia, 'hdlr'))
      fail!('truncated hdlr') if handler.bytesize < 24
      fail!('unsupported hdlr version', :unsupported) unless handler.byteslice(0, 4) == "\0".b * 4
      [id, handler.byteslice(8, 4), track]
    end

    def collect_references
      tracks = @moov[:children].select { |a| a[:type] == 'trak' }.map { |t| track_info(t) }
      fail!('duplicate track IDs', :unsupported) unless tracks.map(&:first).uniq.size == tracks.size
      targets = tracks.to_h { |id, handler, track| [id, [handler, track]] }
      tracks.flat_map do |id, _handler, track|
        saved_index = 0
        track[:children].select { |a| a[:type] == 'tref' }.each_with_index.flat_map do |tref, tref_index|
          chap = child(tref, 'chap', required: false)
          ids = []
          if chap
            data = payload(chap)
            fail!('invalid chap reference payload') unless (data.bytesize % 4).zero?
            ids = data.unpack('N*')
            retained = ids.select { |target| targets.key?(target) }
            @edits[chap[:offset]] = retained if retained != ids
          end
          @tref_positions[[id, tref_index]] = saved_index
          saved_index += 1 unless deleted_reference_atom?(tref)
          ids.each_with_index.map do |target, index|
            info = targets[target]
            status = if info.nil?
                       :missing
                     elsif chapter_candidate?(*info)
                       :chapter_candidate
                     else
                       :inappropriate
                     end
            { source_track_id: id, tref_index: tref_index, reference_index: index, target_track_id: target,
              target_exists: !info.nil?, target_handler: info&.first, status: status }
          end
        end
      end
    end

    def chapter_candidate?(handler, track)
      return false unless handler == 'text'
      stbl = child(child(child(track, 'mdia'), 'minf'), 'stbl')
      stsd = child(stbl, 'stsd')
      description = payload(stsd)
      fail!('truncated stsd') if description.bytesize < 8
      fail!('unsupported stsd version', :unsupported) unless description.byteslice(0, 4) == "\0".b * 4
      entries = @file.send(:parse_mp4_atoms, @io, stsd[:payload_offset] + 8, stsd[:end_offset])
      fail!('stsd count mismatch') unless entries.size == description.byteslice(4, 4).unpack1('N')
      # text handlerだけで字幕をchapterと断定しない。候補判定は完全なchapter解析とは別。
      entries.size == 1 && entries.first[:type] == 'text'
    end

    # 補正値を推定せず、chapter候補の生値と確実に比較できる関係だけを診断する。
    def collect_timing
      movie = timing_header(child(@moov, 'mvhd'), 'mvhd')
      @moov[:children].select { |a| a[:type] == 'trak' }.filter_map do |track|
        id, handler, = track_info(track)
        next unless chapter_candidate?(handler, track)
        media = timing_header(child(child(track, 'mdia'), 'mdhd'), 'mdhd')
        header = timing_header(child(track, 'tkhd'), 'tkhd')
        stbl = child(child(child(track, 'mdia'), 'minf'), 'stbl')
        data = payload(child(stbl, 'stts'))
        fail!('invalid stts timing header') unless data.bytesize >= 8 && data.byteslice(0, 4) == "\0".b * 4
        count = data.byteslice(4, 4).unpack1('N')
        fail!('stts timing count mismatch') unless data.bytesize == 8 + count * 8
        entries = data.byteslice(8..).unpack('N*').each_slice(2).to_a
        sample_count = entries.sum(&:first)
        sample_duration = entries.sum { |number, delta| number * delta }
        edits = timing_edits(track)
        issues = []
        issues << :mdhd_stts_duration_mismatch unless media[:duration] == sample_duration
        if edits
          issues << :tkhd_elst_duration_mismatch unless header[:duration] == edits.sum { |e| e[:segment_duration] }
          # 下位32bit一致は観測であり、overflowや生成原因の断定ではない。
          if movie[:duration] > 0xffff_ffff && edits.any? { |e| e[:version].zero? && e[:segment_duration] == (movie[:duration] & 0xffff_ffff) }
            issues << :elst_matches_movie_duration_low32
          end
        elsif (header[:duration] * media[:timescale] - sample_duration * movie[:timescale]).abs > media[:timescale]
          # movie tick単位の丸めを許容する。edit listありのmedia/movie差は異常としない。
          issues << :tkhd_media_duration_mismatch
        end
        { track_id: id, movie: movie, media: media, track_header: header,
          stts: { sample_count: sample_count, duration: sample_duration }, edits: edits,
          observations: issues, correction: :not_attempted }
      end
    end

    # v0/v1の時間幅を保持し、浮動小数点への変換なしに比較できる生値を返す。
    def timing_header(atom, type)
      data = payload(atom)
      version = data.getbyte(0)
      fail!("unsupported #{type} timing version", :unsupported) unless [0, 1].include?(version)
      scale_offset = version == 1 ? 20 : 12
      duration_offset = type == 'tkhd' ? (version == 1 ? 28 : 20) : scale_offset + 4
      width = version == 1 ? 8 : 4
      minimum = { 'mvhd' => [100, 112], 'mdhd' => [24, 36], 'tkhd' => [84, 96] }.fetch(type)[version]
      fail!("truncated #{type} timing") if data.bytesize < minimum
      result = { version: version, duration: data.byteslice(duration_offset, width).unpack1(width == 8 ? 'Q>' : 'N') }
      unless type == 'tkhd'
        result[:timescale] = data.byteslice(scale_offset, 4).unpack1('N')
        fail!("zero #{type} timescale") if result[:timescale].zero?
      end
      result
    end

    # empty edit・トリミング・複数edit・rateを生値のまま返し、正常な編集を補正しない。
    def timing_edits(track)
      edts = child(track, 'edts', required: false)
      return nil unless edts
      data = payload(child(edts, 'elst'))
      version = data.getbyte(0)
      fail!('unsupported elst timing version', :unsupported) unless [0, 1].include?(version)
      fail!('invalid elst timing header') unless data.bytesize >= 8 && data.byteslice(1, 3) == "\0".b * 3
      count = data.byteslice(4, 4).unpack1('N')
      width = version == 1 ? 20 : 12
      fail!('elst timing count mismatch') unless data.bytesize == 8 + count * width
      Array.new(count) do |index|
        entry = data.byteslice(8 + index * width, width)
        duration, time, rate = entry.unpack(version == 1 ? 'Q>q>l>' : 'Nl>l>')
        { version: version, segment_duration: duration, media_time: time, media_rate: rate }
      end
    end

    def collect_offsets
      @moov[:children].select { |a| a[:type] == 'trak' }.each do |track|
        minf = child(child(track, 'mdia'), 'minf')
        dref = payload(child(child(minf, 'dinf'), 'dref'))
        fail!('external or unsupported data reference', :unsupported) unless dref == [0, 1, 12].pack('N3') + 'url ' + [1].pack('N')
        stbl = child(minf, 'stbl')
        tables = stbl[:children].select { |a| %w[stco co64].include?(a[:type]) }
        fail!('missing or multiple chunk offset tables', :unsupported) unless tables.size == 1
        table = tables.first
        data = payload(table)
        width = table[:type] == 'stco' ? 4 : 8
        fail!('invalid chunk offset header') unless data.bytesize >= 8 && data.byteslice(0, 4) == "\0".b * 4
        count = data.byteslice(4, 4).unpack1('N')
        fail!('chunk offset count mismatch') unless data.bytesize == 8 + count * width
        offsets = data.byteslice(8..).unpack(width == 4 ? 'N*' : 'Q>*')
        offsets.each do |offset|
          fail!('chunk offset outside mdat') unless @mdat_ranges.any? { |first, last| offset >= first && offset < last }
        end
        # atom位置 => [fullbox header/count bytes, 絶対chunk位置の配列, 整数幅4または8]。
        @offset_tables[table[:offset]] = [data.byteslice(0, 8), offsets, width]
      end
    end

    # 今回の編集で空になった参照atomだけを削除し、元から空のatomは保持する。
    def deleted_reference_atom?(atom)
      return @edits.key?(atom[:offset]) && @edits.fetch(atom[:offset]).empty? if atom[:type] == 'chap'
      atom[:type] == 'tref' && atom[:children].any? && atom[:children].all? { |a| deleted_reference_atom?(a) }
    end

    def render(atom, delta)
      return ''.b if deleted_reference_atom?(atom)
      data = if @edits.key?(atom[:offset])
               @edits.fetch(atom[:offset]).pack('N*')
             elsif @offset_tables.key?(atom[:offset])
               render_offsets(@offset_tables.fetch(atom[:offset]), delta)
             elsif atom[:children].any?
               atom[:children].map { |a| render(a, delta) }.join.b
             else
               return @raw.byteslice(atom[:offset] - @moov[:offset], length(atom))
             end
      box(atom, data)
    end

    def render_offsets(table, delta)
      header, offsets, width = table
      adjusted = offsets.map { |v| v >= @moov[:end_offset] ? v + delta : v }
      fail!('chunk offset overflow', :unsupported) if adjusted.any? { |v| v >= 1 << (width * 8) }
      header + adjusted.pack(width == 4 ? 'N*' : 'Q>*')
    end

    def box(atom, data)
      if atom[:payload_offset] - atom[:offset] == 16
        [1].pack('N') + atom[:type] + [data.bytesize + 16].pack('Q>') + data
      else
        fail!('atom size overflow', :unsupported) if data.bytesize + 8 > 0xffff_ffff
        [data.bytesize + 8].pack('N') + atom[:type] + data
      end
    end

    def replacement
      edited = render(@moov, 0)
      removed_bytes = length(@moov) - edited.bytesize
      # 4 bytesだけ空いた場合はfreeの最小8 bytesを満たせないため、moovを8 bytes伸ばす。
      padding = removed_bytes >= 8 ? removed_bytes : removed_bytes + 8
      delta = padding - removed_bytes
      edited = render(@moov, delta)
      header_size = @moov[:payload_offset] - @moov[:offset]
      box(@moov, edited.byteslice(header_size..) + [padding].pack('N') + 'free' + "\0".b * (padding - 8)).freeze
    end
  end

  # 解析済み期待値と生成済みbytesを所有する保存計画。File・native・IOを保持しない。
  class ChapterReferenceRepair
    attr_reader :source_digest, :removed, :retained_report, :preservation_signature

    # 例: moov_start/endは原本境界、replacementは欠落IDだけを除去したmoov bytes。
    def initialize(moov_start:, moov_end:, replacement:, source_digest:, removed:, retained_report:, preservation_signature:)
      @moov_start, @moov_end = moov_start, moov_end
      @replacement = MetadataSnapshot.copy(replacement)
      @source_digest = MetadataSnapshot.copy(source_digest)
      @removed = MetadataSnapshot.copy(removed)
      @retained_report = MetadataSnapshot.copy(retained_report)
      @preservation_signature = MetadataSnapshot.copy(preservation_signature)
      freeze
    end

    # 原本のmoov以外を逐次コピーし、生成済みmoovだけを一時出力へ適用する。
    def write_copy(source, destination)
      ::File.open(source, 'rb') do |input|
        ::File.open(destination, 'wb') do |output|
          IO.copy_stream(input, output, @moov_start)
          output.write(@replacement)
          input.seek(@moov_end)
          IO.copy_stream(input, output)
        end
      end
      Digest::SHA256.file(destination).hexdigest
    end
  end

  class File
    # 原本上の全chap参照を不変のRuby値として診断する。未保存の除去計画は反映しない。
    def chapter_reference_diagnostics
      ChapterReferences.new(self).report
    end

    # 参照修復とは独立にchapter候補の時間情報を観測する。時間atomは変更しない。
    def chapter_timing_diagnostics
      ChapterReferences.new(self, timing: true).timing_report
    end

    # 欠落参照だけを保存待ちにする。存在する参照先の適否には関与しない。
    def remove_dangling_chapter_references
      ensure_reference_repair_isolated!
      analysis = ChapterReferences.new(self)
      if @chapter_reference_repair
        unless @chapter_reference_repair.source_digest == analysis.source_digest
          raise ChapterReferenceError.new('source changed since repair was planned', code: :source_changed)
        end
        return [].freeze
      end
      @chapter_reference_repair = analysis.repair_plan
      analysis.removed
    end

    private

    def ensure_reference_repair_isolated!
      if metadata_dirty? || @chapter_changes.any? || @chapter_timing_repair
        raise ChapterReferenceError.new('save tag and chapter edits separately from reference repair', code: :pending_changes)
      end
    end

    # 期待bytesと別handleの参照を確認し、原本の変更がない場合だけ既存の原子的置換へ進む。
    def save_reference_repair(plan = @chapter_reference_repair, timing: false)
      source_path = name
      temp_path = "#{source_path}.taglib-mdta-#{Process.pid}-#{object_id}"
      committed = false
      begin
        prepare_reference_repair!(plan, source_path, timing: timing)
        ::FileUtils.cp(source_path, temp_path)
        expected = write_reference_copy(plan, source_path, temp_path)
        verify_reference_copy(temp_path, plan, timing: timing)
        unless Digest::SHA256.file(temp_path).hexdigest == expected && Digest::SHA256.file(source_path).hexdigest == plan.source_digest
          raise MdtaSaveError.new('reference repair bytes or source changed during verification', phase: :verify)
        end
        ::FileUtils.mv(temp_path, source_path)
        committed = true
        close
        begin
          initialize(source_path, false)
        rescue StandardError => error
          raise MdtaSaveError.new(error.message, committed: true, phase: :reopen)
        end
        true
      rescue MdtaSaveError
        raise
      rescue StandardError => error
        raise MdtaSaveError.new(error.message, committed: committed, phase: committed ? :reopen : :replace)
      ensure
        unless committed
          failure = $!
          begin
            ::FileUtils.rm_f(temp_path)
          rescue StandardError => cleanup_error
            raise MdtaSaveError.new("reference repair cleanup failed: #{cleanup_error.message}; temporary file: #{temp_path}",
                                    committed: false, phase: :cleanup), cause: failure || cleanup_error
          end
        end
      end
    end

    # 未保存更新と原本変更を保存入口で拒否し、既存のprepare例外契約へ変換する。
    def prepare_reference_repair!(plan, source_path, timing: false)
      timing ? ensure_timing_repair_isolated! : ensure_reference_repair_isolated!
      unless Digest::SHA256.file(source_path).hexdigest == plan.source_digest
        raise MdtaSaveError.new('source changed since reference repair was planned', phase: :prepare)
      end
    rescue ChapterReferenceError => error
      raise MdtaSaveError.new(error.message, phase: :prepare)
    end

    # 書込操作を保存フローの境界に置き、不変計画を変更せずに適用する。
    def write_reference_copy(plan, source_path, temp_path)
      plan.write_copy(source_path, temp_path)
    end

    # 別handleの解析失敗も検証エラーとして報告し、原本置換へ進めない。
    def verify_reference_copy(path, plan, timing: false)
      self.class.open(path, false) do |verification|
        checked = ChapterReferences.new(verification)
        unless checked.removed.empty? && (timing ? checked.report : checked.retained_report) == plan.retained_report &&
               checked.preservation_signature == plan.preservation_signature
          raise MdtaSaveError.new('chapter atom repair verification failed', phase: :verify)
        end
        verification.chapter_snapshot if timing
      end
    rescue MdtaSaveError
      raise
    rescue StandardError => error
      raise MdtaSaveError.new(error.message, phase: :verify)
    end
  end
end
