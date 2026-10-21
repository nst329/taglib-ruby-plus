# frozen_string_literal: true

module TagLib::MP4
  # 同じmoov座標でmetadata除去と専用chapter除去を合成する内部editor。
  class LimitedRepairEditor < QuickTimeChapterRemovalReferences
    attr_reader :metadata_report, :removed_metadata, :quicktime_report

    # QuickTimeの既存安全判定とmetadataのraw編集を同じ解析世代へ束縛する。
    def initialize(file, chapter_report:, mdta_layout:)
      @allow_missing_only = true
      @mdta_layout = mdta_layout
      @metadata_atom_count = 0
      @removed_metadata = []
      @metadata_replacements = {}
      @metadata_context_headers = {}
      super(file, chapter_report: chapter_report)
    end

    # metadataだけの変更にも既存の逐次コピー計画を使用する。
    def repair_plan
      return nil if @removed_metadata.empty? && removed.empty?

      ChapterReferenceRepair.new(moov_start: @moov[:offset], moov_end: @moov[:end_offset],
        replacement: replacement, source_digest: source_digest, removed: removed,
        retained_report: retained_report, preservation_signature: preservation_signature)
    end

    private

    # 両領域を一回の構造解析で独立診断し、安全な編集だけを同じmoovへ登録する。
    def prepare_atom_edits
      begin
        super
        reason = if @dangling_only
                   :missing_reference
                 elsif @chapter_report[:quicktime][:status] == :complete
                   :quicktime_time_mismatch
                 else
                   @chapter_report[:quicktime][:reason_code] || :quicktime_broken
                 end
        @quicktime_report = { status: :required, reason_code: reason,
          operation: reason == :missing_reference ? :remove_dangling_chapter_references : :remove_broken_quicktime_chapters,
          target_track_id: @target_track_id, track_ids: @track_ids }
      rescue ChapterReferenceError => error
        raise if error.code == :source_changed
        status = %i[quicktime_complete quicktime_absent].include?(error.code) ? :not_needed : :blocked
        @quicktime_report = { status: status, reason_code: error.code,
          target_track_id: nil, track_ids: @track_ids, issues: status == :blocked ? repair_failure_issues(error) : [] }
      end
      begin
        prepare_metadata_edits
      rescue ChapterReferenceError => error
        raise if error.code == :source_changed
        @metadata_report = { status: :blocked, reason_code: error.code,
          issues: repair_failure_issues(error) }
      end
    end

    # 解析済みの具体的な診断を優先し、情報のない拒否だけを補完する。
    def repair_failure_issues(error)
      return error.issues unless error.issues.empty?

      [{ code: error.code, message: error.message }]
    end

    # 原本raw bytes上で不正indexだけを除き、保持対象はnativeへ変換しない。
    def prepare_metadata_edits
      contexts = metadata_contexts
      @metadata_report = { status: :not_needed, reason_code: :metadata_absent, removed: [] }
      return if contexts.empty?
      validate_context_set!(contexts)
      contexts.each { |context| prepare_metadata_context(context) }
      @metadata_report = { status: @removed_metadata.empty? ? :not_needed : :required,
        reason_code: @removed_metadata.empty? ? :metadata_complete : :invalid_index, removed: @removed_metadata }
    end

    # metaの実親を保持し、同じ名前の別udtaを同一contextと誤認しない。
    def metadata_contexts
      contexts = []
      visit = lambda do |atoms, parent|
        atoms.each do |atom|
          contexts << { atom: atom, udta: parent } if atom[:type] == 'meta'
          visit.call(atom[:children], atom) if atom[:children] && !atom[:children].empty?
        end
      end
      visit.call(@moov[:children], nil)
      contexts
    end

    # 複数contextは検証済みの同一udta mdir+mdta pairだけ許可する。
    def validate_context_set!(contexts)
      return if contexts.one?
      fail!('multiple metadata contexts', :multiple_meta) unless contexts.size == 2
      normalized = contexts.map do |context|
        parent = context[:udta]
        {
          handler: metadata_context_header(context).fetch(:handler), keys: [],
          path: supported_metadata_parent?(parent) ? 'moov/udta/meta' : nil,
          parent_offset: parent && parent[:offset], parent_end_offset: parent && parent[:end_offset]
        }
      end
      fail!('multiple metadata contexts', :multiple_meta) unless contexts.all? { |context| supported_metadata_parent?(context[:udta]) } &&
        MetadataContextPolicy.safe_pair?(normalized)
    end

    def supported_metadata_parent?(parent)
      parent && parent[:type] == 'udta' && @moov[:children].any? { |atom| atom.equal?(parent) }
    end

    # contextごとに一度だけ子atomとhandlerを解析し、集合検証と編集で再利用する。
    # 例: { raw: meta全体のbytes, children: 元順序のatom配列, handler: 'mdta' }。
    def metadata_context_header(context, raw: nil)
      meta = context.fetch(:atom)
      return @metadata_context_headers.fetch(meta[:offset]) if @metadata_context_headers.key?(meta[:offset])

      raw ||= bytes(meta)
      children = boxes(raw, 12)
      handlers = children.select { |row| row[:type] == 'hdlr' }
      fail!('single metadata handler required', :unsupported) unless handlers.one?
      hdlr = handlers.first[:raw]
      fail!('invalid metadata handler', :unsupported) unless hdlr.bytesize >= 32 && hdlr.byteslice(8, 4) == "\0".b * 4
      @metadata_context_headers[meta[:offset]] = { raw: raw, children: children, handler: hdlr.byteslice(16, 4) }
    end

    # 保持するmdirと編集するmdtaを同じraw構造検証へ通す。
    def prepare_metadata_context(context)
      meta = context[:atom]
      fail!('unsupported metadata location', :unsupported) unless supported_metadata_parent?(context[:udta])
      raw = @metadata_context_headers.dig(meta[:offset], :raw) || bytes(meta)
      fail!('unsupported metadata header', :unsupported) unless raw.unpack1('N') == raw.bytesize && raw.byteslice(8, 4) == "\0".b * 4
      header = metadata_context_header(context, raw: raw)
      children = header.fetch(:children)
      handler = header.fetch(:handler)
      if handler == 'mdir'
        fail!('unsupported mdir children', :unsupported) unless children.all? { |row| %w[hdlr ilst free].include?(row[:type]) }
        lists = children.select { |row| row[:type] == 'ilst' }
        fail!('multiple ilst', :unsupported) if lists.size > 1
        if lists.one?
          boxes(lists.first[:raw], 8).each do |item|
            fail!('unknown ordinary item', :unsupported) unless UnindexedMdtaPlan::ORDINARY_TYPES.include?(item[:type])
            validate_item(item, ordinary: true)
          end
        end
        return
      end
      fail!('unsupported metadata handler', :unsupported) unless handler == 'mdta'
      fail!('unsupported mdta children', :unsupported) unless children.all? { |row| %w[hdlr keys ilst free].include?(row[:type]) }
      %w[hdlr keys ilst].each { |type| fail!("single #{type} required", :unsupported) unless children.count { |row| row[:type] == type } == 1 }
      keys = children.find { |row| row[:type] == 'keys' }[:raw]
      fail!('invalid keys header', :malformed) unless keys.bytesize >= 16 && keys.byteslice(8, 4) == "\0".b * 4
      count = keys.byteslice(12, 4).unpack1('N')
      fail!('keys limit exceeded', :limit) if count > 50_000
      entries = boxes(keys, 16)
      fail!('keys count mismatch', :malformed) unless entries.size == count
      names = entries.map do |entry|
        name = entry[:raw].byteslice(8..).dup.force_encoding(Encoding::UTF_8)
        fail!('invalid key', :malformed) unless entry[:type] == 'mdta' && name.valid_encoding? && !name.empty? && !name.include?("\0")
        name
      end
      fail!('duplicate keys', :unsupported) unless names.uniq.size == names.size
      ilst = children.find { |row| row[:type] == 'ilst' }
      ordinary = UnindexedMdtaPlan::ORDINARY_TYPES
      survivors = boxes(ilst[:raw], 8).reject do |item|
        type = item[:type]
        index = type.unpack1('N')
        if @mdta_layout != :indexed && ordinary.include?(type)
          validate_item(item, ordinary: true)
          next false
        end
        if @mdta_layout.nil? && type.getbyte(0) != 0
          fail!('metadata item interpretation requires explicit layout', :ambiguous_item_type)
        end
        if index.between?(1, count)
          validate_item(item, ordinary: false)
          next false
        end

        @removed_metadata << { path: 'moov/udta/meta/ilst', index: index, keys_count: count, reason: index.zero? ? :zero : :out_of_range,
          offset: meta[:offset] + ilst[:offset] + item[:offset], size: item[:raw].bytesize,
          sha256: Digest::SHA256.hexdigest(item[:raw]), item_position: item[:position] }
        true
      end
      unless @removed_metadata.empty?
        replacement_ilst = make_box('ilst', survivors.map { |item| item[:raw] }.join.b)
        @metadata_replacements[meta[:offset]] = make_box('meta', raw.byteslice(8, 4) + children.map { |row| row.equal?(ilst) ? replacement_ilst : row[:raw] }.join.b)
      end
    end

    # 保持する値の構造だけを検査し、data typeやpayloadの意味は変換しない。
    def validate_item(item, ordinary:)
      children = boxes(item[:raw], 8)
      allowed = ordinary && item[:type] == '----' ? %w[data mean name] : %w[data]
      fail!('invalid metadata value children', :malformed) if children.empty? || children.any? { |row| !allowed.include?(row[:type]) }
      data = children.select { |row| row[:type] == 'data' }
      fail!('invalid metadata data header', :malformed) if data.empty? || data.any? { |row| row[:raw].bytesize < 16 }
      fail!('invalid freeform header', :malformed) if children.any? { |row| %w[mean name].include?(row[:type]) && row[:raw].bytesize < 12 }
    end

    # 通常8byte atomの境界・件数を検証し、元位置とraw bytesを所有する。
    def boxes(raw, start)
      rows = []
      offset = start
      while offset < raw.bytesize
        @metadata_atom_count += 1
        fail!('metadata item limit exceeded', :limit) if @metadata_atom_count > 50_000
        fail!('truncated metadata header', :malformed) if raw.bytesize - offset < 8
        size, type = raw.byteslice(offset, 8).unpack('Na4')
        fail!('invalid metadata boundary', :malformed) unless size >= 8 && size <= raw.bytesize - offset
        rows << { type: type, offset: offset, position: rows.size, raw: raw.byteslice(offset, size) }
        offset += size
      end
      rows
    end

    def make_box(type, data)
      [data.bytesize + 8].pack('N') + type + data
    end

    def render(atom, delta)
      @metadata_replacements[atom[:offset]] || super
    end

    def preservation_value(atom)
      if (raw = @metadata_replacements[atom[:offset]])
        payload = raw.byteslice(8..)
        [payload.bytesize, Digest::SHA256.hexdigest(payload)]
      else
        super
      end
    end
  end
  private_constant :LimitedRepairEditor
end
