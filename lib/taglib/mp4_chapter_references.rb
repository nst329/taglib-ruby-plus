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
      'edts' => %w[elst], 'dinf' => %w[dref], 'udta' => %w[chpl meta free skip]
    }.freeze
    attr_reader :report, :removed, :source_digest, :preservation_signature

    def initialize(file)
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
        @report = collect_references
        collect_offsets
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

    # 例: {source_track_id: 1, reference_index: 0, target_track_id: 0,
    #       target_exists: false, target_handler: nil, status: :missing}
    def retained_report
      report.reject { |r| r[:status] == :missing }.map do |r|
        # 除去後のindexはchap atom内で詰め直される。
        r.reject { |key, _| key == :reference_index }
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

    # chap・paddingを除く全構造とbytesを比較する。chunk位置はmdat内の相対位置で比較する。
    def preservation(atoms)
      atoms.filter_map do |atom|
        next if %w[chap free skip].include?(atom[:type])
        value = preservation_value(atom)
        next if atom[:type] == 'tref' && value.empty?
        [atom[:type], value]
      end
    end

    def preservation_value(atom)
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
        tref = child(track, 'tref', required: false)
        chap = tref && child(tref, 'chap', required: false)
        next [] unless chap
        data = payload(chap)
        fail!('invalid chap reference payload') unless (data.bytesize % 4).zero?
        ids = data.unpack('N*')
        retained = ids.select { |target| targets.key?(target) }
        @edits[chap[:offset]] = retained if retained != ids
        ids.each_with_index.map do |target, index|
          info = targets[target]
          status = if info.nil?
                     :missing
                   elsif chapter_candidate?(*info)
                     :chapter_candidate
                   else
                     :inappropriate
                   end
          { source_track_id: id, reference_index: index, target_track_id: target,
            target_exists: !info.nil?, target_handler: info&.first, status: status }
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

    def render(atom, delta)
      data = if @edits.key?(atom[:offset])
               @edits.fetch(atom[:offset]).pack('N*')
             elsif @offset_tables.key?(atom[:offset])
               render_offsets(@offset_tables.fetch(atom[:offset]), delta)
             elsif atom[:children].any?
               atom[:children].map { |a| render(a, delta) }.join.b
             else
               return @raw.byteslice(atom[:offset] - @moov[:offset], length(atom))
             end
      return ''.b if %w[chap tref].include?(atom[:type]) && data.empty?
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
      if metadata_dirty? || @chapter_changes.any?
        raise ChapterReferenceError.new('save tag and chapter edits separately from reference repair', code: :pending_changes)
      end
    end

    # 期待bytesと別handleの参照を確認し、原本の変更がない場合だけ既存の原子的置換へ進む。
    def save_reference_repair
      plan = @chapter_reference_repair
      source_path = name
      temp_path = "#{source_path}.taglib-mdta-#{Process.pid}-#{object_id}"
      committed = false
      begin
        prepare_reference_repair!(plan, source_path)
        ::FileUtils.cp(source_path, temp_path)
        expected = write_reference_copy(plan, source_path, temp_path)
        verify_reference_copy(temp_path, plan)
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
        ::FileUtils.rm_f(temp_path) unless committed
      end
    end

    # 未保存更新と原本変更を保存入口で拒否し、既存のprepare例外契約へ変換する。
    def prepare_reference_repair!(plan, source_path)
      ensure_reference_repair_isolated!
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
    def verify_reference_copy(path, plan)
      self.class.open(path, false) do |verification|
        checked = ChapterReferences.new(verification)
        unless checked.removed.empty? && checked.retained_report == plan.retained_report &&
               checked.preservation_signature == plan.preservation_signature
          raise MdtaSaveError.new('chapter reference repair verification failed', phase: :verify)
        end
      end
    rescue MdtaSaveError
      raise
    rescue StandardError => error
      raise MdtaSaveError.new(error.message, phase: :verify)
    end
  end
end
