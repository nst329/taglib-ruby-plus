# frozen_string_literal: true

require 'stringio'
require_relative 'mp4_hint_validation'

module TagLib::MP4
  # 参照診断・修復計画の拒否理由。保存失敗は既存のMdtaSaveErrorで報告する。
  class ChapterReferenceError < ArgumentError
    attr_reader :code, :issues

    def initialize(message, code: :malformed, issues: [])
      @issues = MetadataSnapshot.copy(issues)
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
      'minf' => %w[vmhd smhd gmhd nmhd hmhd hdlr dinf stbl free skip],
      'stbl' => %w[stsd stts ctts cslg stsc stsz stz2 stco co64 stss stps sdtp sgpd sbgp padb stdp free skip],
      'edts' => %w[elst], 'dinf' => %w[dref], 'udta' => %w[chpl meta name hnti free skip]
    }.freeze
    attr_reader :report, :removed, :source_digest, :preservation_signature, :timing_report, :track_ids

    def initialize(file, timing: false, ignore_metadata: false, removal: nil, capture_raw: true, capture_signature: true)
      @removal = removal
      @selected_keys = normalize_selection(removal) unless removal.nil? || removal == :missing
      @ignore_metadata = ignore_metadata
      @file = file
      @generation = file.io_generation if file.respond_to?(:io_generation)
      ::File.open(file.name, 'rb') do |io|
        @generation&.check!
        initial_digest = Digest::SHA256.file(file.name).hexdigest unless @generation
        @io = io
        @atoms = if @generation
                   @generation.atom_index { file.send(:parse_mp4_atoms, io, 0, io.stat.size) }
                 else
                   file.send(:parse_mp4_atoms, io, 0, io.stat.size)
                 end
        @moov = one(@atoms, 'moov')
        fail!('moov exceeds repair limit', :unsupported) if length(@moov) > MAX_MOOV_BYTES
        @title_payloads = {}
        walk(@atoms) { |atom| fail!("unsupported #{atom[:type]} structure", :unsupported) if UNSUPPORTED.include?(atom[:type]) }
        hint_validator = HintValidator.new(file: file, io: io)
        validate_structure(@atoms, :root, hint_validator)
        @raw = bytes(@moov) if capture_raw
        validate_title_boxes!
        @mdat_ranges = @atoms.select { |a| a[:type] == 'mdat' }.map { |a| [a[:payload_offset], a[:end_offset]] }
        @edits = {}
        # atom開始offset => 置換済みatom全体のbytes。生成・サイズ・保持検証で共有する。
        @atom_replacements = {}
        @offset_tables = {}
        # [source_track_id, 元tref_index] => 保存後tref_index。例: [2, 1] => 0。
        @tref_positions = {}
        @report = collect_references
        validate_selection!
        collect_offsets
        tracks = @moov[:children].select { |atom| atom[:type] == 'trak' }.map { |track| track_info(track) }
        @track_ids = tracks.map(&:first).freeze
        hint_validator.validate_tracks(tracks: tracks, offset_tables: @offset_tables, mdat_ranges: @mdat_ranges)
        @timing_report = MetadataSnapshot.copy(collect_timing) if timing
        prepare_atom_edits
        @preservation_signature = MetadataSnapshot.copy(preservation(@atoms)) if capture_signature
        @removed = @report.select { |r| selected_reference?(r) }
        io.rewind
        if @generation
          @generation.check!
        else
          @source_digest = Digest::SHA256.file(io).hexdigest
          fail!('source changed during reference analysis', :source_changed) unless @source_digest == initial_digest
        end
      end
      @report = MetadataSnapshot.copy(@report)
      @removed = MetadataSnapshot.copy(@removed)
      @source_digest.freeze
    rescue MdtaSaveError => error
      raise ChapterReferenceError, error.message
    ensure
      @io = nil
    end

    # 保存後の位置を順序付きで計算する。元位置は公開report/removedに保持する。
    def retained_report
      positions = Hash.new(0)
      report.reject { |r| selected_reference?(r) }.map do |r|
        key = [r[:source_track_id], r[:tref_index]]
        index = positions[key]
        positions[key] += 1
        r.merge(tref_index: @tref_positions.fetch(key), reference_index: index)
      end
    end

    # 明示した除去対象がある場合だけ、handleから独立した保存計画を生成する。
    def repair_plan
      return nil if removed.empty?

      ChapterReferenceRepair.new(moov_start: @moov[:offset], moov_end: @moov[:end_offset],
                                 replacement: replacement, source_digest: source_digest,
                                 removed: removed, retained_report: retained_report,
                                 preservation_signature: preservation_signature)
    end

    private

    REFERENCE_KEYS = %i[source_track_id tref_index reference_index target_track_id].freeze
    private_constant :REFERENCE_KEYS

    def reference_key(row)
      REFERENCE_KEYS.map { |key| row.fetch(key) }
    end

    def normalize_selection(rows)
      valid = rows.is_a?(Array) && rows.all? do |row|
        row.is_a?(Hash) && REFERENCE_KEYS.all? { |key| row[key].is_a?(Integer) && row[key] >= 0 }
      end
      unless valid
        fail!('references must contain diagnostic positions', :invalid_selection)
      end
      keys = rows.map { |row| reference_key(row) }
      fail!('duplicate reference selection', :invalid_selection) unless keys.uniq.size == keys.size
      keys.to_h { |key| [key, true] }
    end

    def selected_reference?(row)
      return row[:status] == :missing if @removal == :missing
      @selected_keys && @selected_keys.key?(reference_key(row))
    end

    def validate_selection!
      return unless @selected_keys
      actual = @report.to_h { |row| [reference_key(row), row] }
      fail!('selected reference no longer exists', :invalid_selection) unless @selected_keys.keys.all? { |key| actual.key?(key) }
      # 診断行全体を渡した場合、参照位置以外の観測値の変化も拒否する。
      @removal.each do |row|
        current = actual.fetch(reference_key(row))
        fail!('reference diagnostics changed', :invalid_selection) unless row.all? { |key, value| current.key?(key) && current[key] == value }
      end
    end

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

    # 同じ解析で取得したmoovを再利用し、leafごとの再読込を避ける。
    def bytes(atom)
      return @raw.byteslice(atom[:offset] - @moov[:offset], length(atom)) if cached_atom?(atom)

      @file.send(:read_mp4_bytes, @io, atom[:offset], length(atom))
    end

    def payload(atom)
      return @title_payloads.fetch(atom[:offset]) if atom[:type] == 'titl' && @title_payloads&.key?(atom[:offset])
      size = atom[:end_offset] - atom[:payload_offset]
      return @raw.byteslice(atom[:payload_offset] - @moov[:offset], size) if cached_atom?(atom)

      @file.send(:read_mp4_bytes, @io, atom[:payload_offset], size)
    end

    def cached_atom?(atom)
      @raw && atom[:offset] >= @moov[:offset] && atom[:end_offset] <= @moov[:end_offset]
    end

    def walk(atoms, &block)
      atoms.each do |atom|
        block.call(atom)
        walk(atom[:children], &block)
      end
    end

    def validate_structure(atoms, parent, hint_validator)
      atoms.each do |atom|
        supported = STRUCTURES[parent]
        titl_candidate = atom[:type] == 'titl' # 配置とpayloadはvalidate_title_boxes!で一括検証する。
        fail!("unsupported #{parent}/#{atom[:type]}", :unsupported) if supported && !supported.include?(atom[:type]) && !titl_candidate
        if atom[:type] == 'meta'
          # version/flagsの確認に、置換予定の画像や旧metadata本文を読み込まない。
          valid_version = atom[:end_offset] - atom[:payload_offset] >= 4 &&
            @file.send(:read_mp4_bytes, @io, atom[:payload_offset], 4) == "\0".b * 4
          fail!('unsupported meta version', :unsupported) unless valid_version
          children = @file.send(:parse_mp4_atoms, @io, atom[:payload_offset] + 4, atom[:end_offset])
          fail!('unsupported meta structure', :unsupported) unless children.all? { |a| %w[hdlr keys ilst free].include?(a[:type]) }
        end
        hint_validator.validate_information(atom) if atom[:type] == 'hnti'
        validate_structure(atom[:children], atom[:type], hint_validator)
      end
    end

    # movie/trackのuser data内のTitleを個別検証し、順序・重複を含めてraw保持する。
    def validate_title_boxes!
      @title_contexts = []
      collect_title_contexts(@atoms)
      @title_contexts.each do |context|
        atom = context.fetch(:atom)
        @title_payloads[atom[:offset]] = validated_title_payload(context)
      end
    end

    # 単一Titleの保持条件を検証し、失敗には原本上の位置を付与する。
    def validated_title_payload(context)
      atom = context.fetch(:atom)
      unless [%w[moov udta], %w[moov trak udta]].include?(context.fetch(:ancestors))
        fail!('unsupported titl location: expected movie or track user data', :unsupported)
      end
      raw_atom = bytes(atom)
      declared_size = raw_atom.unpack1('N')
      fail!('unsupported titl zero size form', :unsupported) if declared_size.zero?
      header = atom[:payload_offset] - atom[:offset]
      declared_size = raw_atom.byteslice(8, 8).unpack1('Q>') if declared_size == 1
      fail!('malformed titl atom boundary') unless declared_size == length(atom)
      raw = raw_atom.byteslice(header..)
      validate_title_payload!(raw)
      raw
    rescue ChapterReferenceError => error
      fail_title!(context, error.message, error.code)
    end

    # 同種兄弟の番号付きpathを保持し、複数track・重複Titleの拒否箇所を特定する。
    def collect_title_contexts(atoms, ancestors = [], path = '')
      counts = Hash.new(0)
      atoms.each do |atom|
        type = atom[:type]
        counts[type] += 1
        current = "#{path}/#{type}[#{counts[type]}]"
        if type == 'titl'
          @title_contexts << { atom: atom, ancestors: ancestors, path: current }
        end
        collect_title_contexts(atom[:children], ancestors + [type], current) if atom[:children].any?
      end
    end

    # 共通解析失敗でも、公開診断まで実座標と具体的な拒否理由を失わない。
    def fail_title!(context, message, code = :unsupported)
      atom = context.fetch(:atom)
      issue = { code: code, message: message, location: context.fetch(:path),
                details: { atom_path: context.fetch(:path), offset: atom[:offset], size: length(atom) } }
      raise ChapterReferenceError.new(message, code: code, issues: [issue])
    end

    # 対応するversion・言語・文字列表現だけを検証し、元bytesの再構成は行わない。
    def validate_title_payload!(raw)
      fail!('malformed titl payload', :malformed) if raw.bytesize < 7
      fail!('unsupported titl version or flags', :unsupported) unless raw.byteslice(0, 4) == "\0".b * 4

      language = raw.byteslice(4, 2).unpack1('n')
      fail!('unsupported titl language', :unsupported) unless (language & 0x8000).zero? &&
        [10, 5, 0].all? { |shift| ((language >> shift) & 0x1f).between?(1, 26) }

      text = raw.byteslice(6..)
      if text.start_with?("\xFE\xFF".b)
        validate_title_utf16!(text)
      else
        validate_title_utf8!(text)
      end
    end

    def validate_title_utf16!(text)
      fail!('malformed titl UTF-16 payload', :malformed) unless text.bytesize.even? && text.end_with?("\0\0".b)
      body = text.byteslice(0, text.bytesize - 2).force_encoding(Encoding::UTF_16BE)
      fail!('malformed titl UTF-16 payload', :malformed) unless body.valid_encoding? && !body.byteslice(2..).unpack('n*').include?(0)
    end

    def validate_title_utf8!(text)
      fail!('malformed titl UTF-8 payload', :malformed) unless text.end_with?("\0".b)
      body = text.byteslice(0, text.bytesize - 1).dup.force_encoding(Encoding::UTF_8)
      fail!('malformed titl UTF-8 payload', :malformed) unless body.valid_encoding? && !body.include?("\0")
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
      if (raw = @atom_replacements[atom[:offset]])
        header = raw.unpack1('N') == 1 ? 16 : 8
        data = raw.byteslice(header..)
        return [data.bytesize, Digest::SHA256.hexdigest(data)]
      end
      return @edits.fetch(atom[:offset]) if @edits.key?(atom[:offset])
      # Titleはpayloadだけでなくheader形式も含めて独立再読込時に保持を検証する。
      return [length(atom), Digest::SHA256.hexdigest(bytes(atom))] if atom[:type] == 'titl'
      return payload(atom).unpack('N*') if atom[:type] == 'chap'
      return offset_signature(@offset_tables.fetch(atom[:offset])) if @offset_tables.key?(atom[:offset])
      return preservation(atom[:children]) if atom[:children].any?

      payload_signature(atom)
    end

    # 絶対位置の変更を許しつつ、同じmdat内の同じmedia bytesを指すことを比較する。
    # chunk数に比例する配列を保持せず、mdat内の相対位置だけを固定長digestへ畳み込む。
    def offset_signature(table)
      header, offsets, width = table
      format = width == 4 ? 'N*' : 'Q>*'
      if @mdat_ranges.size == 1
        base = @mdat_ranges.first.first
        relative = offsets.map { |offset| offset - base }
        digest = Digest::SHA256.digest(relative.pack(format))
      else
        indexes = Array.new(offsets.length)
        relative = offsets.each_with_index.map do |offset, position|
          index = mdat_index_for(offset)
          indexes[position] = index
          offset - @mdat_ranges.fetch(index).first
        end
        digest = Digest::SHA256.digest(indexes.pack('N*') + relative.pack(format))
      end
      [header, width, offsets.length, digest]
    end

    # 複数mdatでも保存前後の相対位置を比較できるよう、所属mdatを二分探索で確定する。
    def mdat_index_for(offset)
      low = 0
      high = @mdat_ranges.length - 1
      while low <= high
        middle = (low + high) / 2
        first, last = @mdat_ranges[middle]
        return middle if offset >= first && offset < last

        if offset < first
          high = middle - 1
        else
          low = middle + 1
        end
      end
      fail!('chunk offset outside mdat')
    end

    # 大きなmdatも全読込せず、保持対象payloadのサイズとhashを取得する。
    def payload_signature(atom)
      # Plusはコピー時のmdat署名と出力の独立署名で媒体保持を検証する。
      return [atom[:end_offset] - atom[:payload_offset]] if @generation && atom[:type] == 'mdat'
      if cached_atom?(atom)
        data = payload(atom)
        return [data.bytesize, Digest::SHA256.hexdigest(data)]
      end
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
      tracks.flat_map do |id, source_handler, track|
        source_enabled = (payload(child(track, 'tkhd')).unpack1('N') & 1) != 0
        saved_index = 0
        track[:children].select { |a| a[:type] == 'tref' }.each_with_index.flat_map do |tref, tref_index|
          chap = child(tref, 'chap', required: false)
          ids = []
          if chap
            data = payload(chap)
            fail!('invalid chap reference payload') unless (data.bytesize % 4).zero?
            ids = data.unpack('N*')
            retained = ids.each_with_index.reject do |target, index|
              selected_reference?(source_track_id: id, tref_index: tref_index, reference_index: index,
                                  target_track_id: target, status: targets.key?(target) ? :existing : :missing)
            end.map(&:first)
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
              source_handler: source_handler, source_enabled: source_enabled,
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
      # stsdの内側はroot indexの対象外。取得済みpayloadを同じ境界parserへ渡す。
      entries = (@sample_entries ||= {})[stsd[:offset]] ||= if cached_atom?(stsd)
        @file.send(:parse_mp4_atoms, StringIO.new(description), 8, description.bytesize, 1)
      else
        @file.send(:parse_mp4_atoms, @io, stsd[:payload_offset] + 8, stsd[:end_offset])
      end
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
        validate_chunk_offsets!(offsets)
        # atom位置 => [fullbox header/count bytes, 絶対chunk位置の配列, 整数幅4または8]。
        @offset_tables[table[:offset]] = [data.byteslice(0, 8), offsets, width]
      end
    end

    # mdat範囲外のchunk offsetを拒否する。通常の単一mdatは最小・最大だけで判定する。
    def validate_chunk_offsets!(offsets)
      return if offsets.empty?
      if @mdat_ranges.size == 1
        first, last = @mdat_ranges.first
        fail!('chunk offset outside mdat') unless offsets.min >= first && offsets.max < last
        return
      end
      offsets.each { |offset| mdat_index_for(offset) }
    end

    # 今回の編集で空になった参照atomだけを削除し、元から空のatomは保持する。
    def deleted_reference_atom?(atom)
      return true if @deleted_atom_offsets&.include?(atom[:offset])
      return @edits.key?(atom[:offset]) && @edits.fetch(atom[:offset]).empty? if atom[:type] == 'chap'
      atom[:type] == 'tref' && atom[:children].any? && atom[:children].all? { |a| deleted_reference_atom?(a) }
    end

    def render(atom, delta)
      return @atom_replacements.fetch(atom[:offset]) if @atom_replacements.key?(atom[:offset])
      return ''.b if deleted_reference_atom?(atom)
      data = if @edits.key?(atom[:offset])
               @edits.fetch(atom[:offset]).pack('N*')
             elsif @offset_tables.key?(atom[:offset])
               render_offsets(@offset_tables.fetch(atom[:offset]), delta)
             elsif atom[:children].any?
               atom[:children].map { |a| render(a, delta) }.join.b
             else
               return @raw ? @raw.byteslice(atom[:offset] - @moov[:offset], length(atom)) : bytes(atom)
             end
      box(atom, data)
    end

    # 保持payloadを読まず、境界と編集済み参照数だけで出力サイズを決める。
    def rendered_size(atom)
      return @atom_replacements.fetch(atom[:offset]).bytesize if @atom_replacements.key?(atom[:offset])
      return 0 if deleted_reference_atom?(atom)
      header = atom[:payload_offset] - atom[:offset]
      return header + @edits.fetch(atom[:offset]).size * 4 if @edits.key?(atom[:offset])
      return length(atom) if atom[:children].empty?

      header + atom[:children].sum { |child| rendered_size(child) }
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
      removed_bytes = length(@moov) - rendered_size(@moov)
      # 4 bytesだけ空いた場合はfreeの最小8 bytesを満たせないため、moovを8 bytes伸ばす。
      padding = removed_bytes >= 8 ? removed_bytes : removed_bytes + 8
      delta = padding - removed_bytes
      edited = render(@moov, delta)
      header_size = @moov[:payload_offset] - @moov[:offset]
      box(@moov, edited.byteslice(header_size..) + [padding].pack('N') + 'free' + "\0".b * (padding - 8)).freeze
    end
  end

  # 壊れたQuickTime chapterだけを、専用text trackと一緒に除去する限定解析。
  # 音声・映像由来の全chap参照が同一trackを指し、他用途の参照がない場合だけ生成できる。
  class QuickTimeChapterRemovalReferences < ChapterReferences
    # chapのsourceとして安全性を証明できるtrack handlerだけを許可する。
    # videoは音声外参照でも、chap以外の共有がないことを別途確認できる。
    SAFE_SOURCE_HANDLERS = %w[soun vide].freeze
    SUBTITLE_SOURCE_HANDLERS = %w[text sbtl subp clcp].freeze

    attr_reader :target_track_id

    def initialize(file, chapter_report:, timing: true)
      @chapter_report = chapter_report
      super(file, timing: timing, removal: @allow_missing_only ? :missing : nil)
    end

    private

    def prepare_atom_edits
      super
      validate_quicktime_report!
      rows = @report
      fail!('no QuickTime chapter reference', :quicktime_absent) if rows.empty?
      if @allow_missing_only && rows.all? { |row| row[:status] == :missing }
        @dangling_only = true
        @target_track_id = nil
        @removal = :missing
        @deleted_track_offsets = []
        recalculate_tref_positions!
        return
      end
      validate_source_handlers!(rows)
      fail!('QuickTime reference target is missing', :missing_reference) unless rows.all? { |row| row[:target_exists] }
      fail!('QuickTime reference target is not a dedicated text track', :shared_reference) unless rows.all? { |row| row[:status] == :chapter_candidate }

      target_ids = rows.map { |row| row[:target_track_id] }.uniq
      fail!('QuickTime chapter references have multiple targets', :multiple_references) unless target_ids.one?

      @target_track_id = target_ids.first
      target = @moov[:children].find { |atom| atom[:type] == 'trak' && track_info(atom).first == @target_track_id }
      fail!('QuickTime chapter track is missing', :missing_reference) unless target
      fail!('QuickTime chapter track is shared by another reference', :shared_reference) if other_target_references?(target)
      title = @title_contexts.find do |context|
        atom = context.fetch(:atom)
        atom[:offset] >= target[:offset] && atom[:end_offset] <= target[:end_offset]
      end
      fail_title!(title, 'cannot preserve titl inside removed QuickTime chapter track') if title

      @selected_keys = rows.to_h { |row| [reference_key(row), true] }
      @removal = rows
      @deleted_track_offsets = [target[:offset]]
      @report.each do |row|
        next unless selected_reference?(row)

        tref = tref_for(row)
        chap = child(tref, 'chap')
        @edits[chap[:offset]] = []
      end
      recalculate_tref_positions!
    end

    def validate_source_handlers!(rows)
      unsupported = rows.map { |row| row[:source_handler] }.uniq.reject { |handler| SAFE_SOURCE_HANDLERS.include?(handler) }
      return if unsupported.empty?

      code = unsupported.all? { |handler| SUBTITLE_SOURCE_HANDLERS.include?(handler) } ? :subtitle_source : :unsupported_source_handler
      row = rows.find { |reference| unsupported.include?(reference[:source_handler]) }
      fail!("QuickTime reference source is not a safe media track: " \
            "source_track_id=#{row[:source_track_id]} handler=#{row[:source_handler]} " \
            "target_track_id=#{row[:target_track_id]} target_exists=#{row[:target_exists]}", code)
    end

    def validate_quicktime_report!
      nero = @chapter_report.fetch(:nero)
      unless @allow_broken_nero
        fail!('Nero chapter read is incomplete', :nero_unreadable) unless %i[complete absent].include?(nero[:status])
      end
      quicktime = @chapter_report.fetch(:quicktime)
      if quicktime[:status] == :complete && !@timing_report.any? { |row| row[:observations].any? }
        fail!('QuickTime chapter is not broken', :quicktime_complete)
      end
      fail!('QuickTime chapter is absent', :quicktime_absent) if quicktime[:status] == :absent
    end

    def tref_for(row)
      track = @moov[:children].find { |atom| atom[:type] == 'trak' && track_info(atom).first == row[:source_track_id] }
      tref = track[:children].select { |atom| atom[:type] == 'tref' }.fetch(row[:tref_index])
      tref
    end

    def other_target_references?(target)
      @moov[:children].select { |atom| atom[:type] == 'trak' }.any? do |track|
        track[:children].select { |atom| atom[:type] == 'tref' }.any? do |tref|
          tref[:children].any? do |reference|
            next false if reference[:type] == 'chap'

            data = payload(reference)
            fail!('unknown target reference structure', :unknown_structure) unless (data.bytesize % 4).zero?
            data.unpack('N*').include?(@target_track_id)
          end
        end
      end
    end

    def recalculate_tref_positions!
      positions = Hash.new(0)
      @moov[:children].select { |atom| atom[:type] == 'trak' }.each do |track|
        source_id = track_info(track).first
        track[:children].select { |atom| atom[:type] == 'tref' }.each_with_index do |tref, tref_index|
          key = [source_id, tref_index]
          rows = @report.select { |row| [row[:source_track_id], row[:tref_index]] == key }
          @tref_positions[key] = positions[source_id]
          positions[source_id] += 1 unless rows.any? && rows.all? { |row| selected_reference?(row) }
        end
      end
    end

    def deleted_reference_atom?(atom)
      return true if atom[:type] == 'trak' && @deleted_track_offsets&.include?(atom[:offset])

      super
    end

    def reference_key(row)
      %i[source_track_id tref_index reference_index target_track_id].map { |key| row.fetch(key) }
    end
  end

  # QuickTime参照除去と、破損Neroのchpl atom除去を同じmoov編集へ束ねる。
  # 破損と断定できない未対応構造は呼出し側でblockedとして扱う。
  class BrokenChapterRemovalReferences < QuickTimeChapterRemovalReferences
    attr_reader :removed_nero

    def initialize(file, chapter_report:, remove_nero: false)
      @allow_broken_nero = remove_nero
      @remove_nero = remove_nero
      super(file, chapter_report: chapter_report, timing: false)
    end

    def repair_plan
      return super unless @removed_nero

      ChapterReferenceRepair.new(moov_start: @moov[:offset], moov_end: @moov[:end_offset],
                                 replacement: replacement, source_digest: source_digest,
                                 removed: removed + [@removed_nero], retained_report: retained_report,
                                 preservation_signature: preservation_signature)
    end

    private

    def prepare_atom_edits
      quicktime_broken = @chapter_report.fetch(:quicktime)[:status] == :malformed
      if @remove_nero
        udta = child(@moov, 'udta', required: false)
        chpl = udta && child(udta, 'chpl', required: false)
        fail!('broken Nero chapter atom is missing', :nero_absent) unless chpl
        @deleted_atom_offsets = [chpl[:offset]]
        @removed_nero = { style: :nero, atom_offset: chpl[:offset], status: :malformed }
      end
      if quicktime_broken
        super
      else
        @target_track_id = nil
        @deleted_track_offsets = []
      end
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
    def write_copy(source, destination, &copy)
      return copy.call(source, destination, [@moov_start, @moov_end, @replacement]) if copy
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
      ChapterReferences.new(self, capture_raw: false, capture_signature: false).report
    end

    # 参照修復とは独立にchapter候補の時間情報を観測する。時間atomは変更しない。
    def chapter_timing_diagnostics
      ChapterReferences.new(self, timing: true, capture_raw: false, capture_signature: false).timing_report
    end

    # 欠落参照だけを保存待ちにする。存在する参照先の適否には関与しない。
    def remove_dangling_chapter_references
      ensure_reference_repair_isolated!
      analysis = ChapterReferences.new(self, removal: :missing)
      if @chapter_reference_repair
        unless @chapter_reference_repair.source_digest == analysis.source_digest
          raise ChapterReferenceError.new('source changed since repair was planned', code: :source_changed)
        end
        return [].freeze
      end
      @chapter_reference_repair = analysis.repair_plan
      analysis.removed
    end

    # 診断で指定したchap関係だけを解除する。トラックやmediaは削除しない。
    def remove_chapter_references(references:)
      ensure_reference_repair_isolated!
      unless references.is_a?(Array)
        raise ChapterReferenceError.new('references must be an array', code: :invalid_selection)
      end
      if @chapter_reference_repair
        raise ChapterReferenceError.new('reference repair already planned', code: :pending_changes)
      end
      analysis = ChapterReferences.new(self, removal: references)
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
        unless checked.report == plan.retained_report &&
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
