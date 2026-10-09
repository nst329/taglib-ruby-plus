# frozen_string_literal: true

module TagLib::MP4
  # index 0の意味を推定せず、先頭raw群とmetadata contextの配置を不変値で保持する。
  class UnindexedMdtaPlan
    # nativeの任意4文字Text fallbackをこの限定profileへ広げず、既知の通常atomに限定する。
    ORDINARY_TYPES = (Tag::PROPERTY_ATOMS.values + %w[---- trkn disk cpil pgap pcst shwm tmpo hdvd rate
      tvsn tves cnID sfID atID geID cmID plID stik rtng akID gnre covr purl egid cprt aART
      tvnn catg soal soar soaa sonm soco sosn] + %w[©too ©wrt ©lyr ©enc ©mvi ©mvc ©wrk ©mvn])
      .map { |type| type.encode(Encoding::ISO_8859_1).b.freeze }.uniq.freeze

    attr_reader :raw_signature

    def initialize(raw)
      fail!('unsupported meta header') unless raw.byteslice(4, 4) == 'meta' && raw.unpack1('N') == raw.bytesize && raw.byteslice(8, 4) == "\0".b * 4
      @children = boxes(raw.byteslice(12..))
      fail!('unsupported metadata children') unless @children.all? { |type, _bytes| %w[hdlr keys ilst free].include?(type) }
      %w[hdlr keys ilst].each { |type| fail!("single #{type} required") unless @children.count { |t, _b| t == type } == 1 }
      @handler = @children.assoc('hdlr').last.freeze
      @keys = @children.assoc('keys').last.freeze
      validate_keys(@keys.byteslice(8..))
      fail!('mdta handler required') unless @handler.bytesize >= 32 && @handler.byteslice(16, 4) == 'mdta' && @handler.byteslice(8, 4) == "\0".b * 4
      items = boxes(@children.assoc('ilst').last.byteslice(8..))
      @opaque = items.take_while { |type, _bytes| type == "\0".b * 4 }
      ordinary = items.drop(@opaque.size)
      fail!('only leading index 0 items are supported') if @opaque.empty? || ordinary.any? { |type, _b| type.getbyte(0).zero? }
      fail!('unknown ordinary metadata item') unless ordinary.all? { |type, _b| ORDINARY_TYPES.include?(type) }
      @raw_signature = MetadataSnapshot.copy([@children.map(&:first), @handler, @keys, @opaque.map(&:last)])
      @children, @opaque = MetadataSnapshot.copy(@children), MetadataSnapshot.copy(@opaque)
      freeze
    end

    # 一時native作業用contextだけをmdirへ変換する。通常item bytesは触らない。
    def sanitize(raw)
      current = self.class.new(raw)
      fail!('metadata changed before staging') unless current.raw_signature == raw_signature
      nodes = @children.reject { |type, _b| type == 'keys' }.map do |type, bytes|
        if type == 'hdlr'
          bytes = bytes.dup
          bytes[16, 4] = 'mdir'
        elsif type == 'ilst'
          bytes = box('ilst', boxes(bytes.byteslice(8..)).drop(@opaque.size).map(&:last).join.b)
        end
        [type, bytes]
      end
      box('meta', "\0".b * 4 + nodes.map(&:last).join.b)
    end

    # 元のcontext順と0 item群を戻す。nativeが生成した通常itemだけを採用する。
    def restore(raw)
      nodes = boxes(raw.byteslice(12..))
      fail!('unsupported staging metadata') unless raw.byteslice(4, 4) == 'meta' && raw.byteslice(8, 4) == "\0".b * 4 &&
        nodes.all? { |type, _b| %w[hdlr ilst free].include?(type) } && %w[hdlr ilst].all? { |type| nodes.count { |t, _b| t == type } == 1 }
      handler = nodes.assoc('hdlr').last
      fail!('staging handler is not mdir') unless handler.byteslice(16, 4) == 'mdir'
      ordinary = boxes(nodes.assoc('ilst').last.byteslice(8..))
      fail!('numeric staging items are unsupported') if ordinary.any? { |type, _b| type.getbyte(0).zero? }
      ilst = box('ilst', @opaque.map(&:last).join.b + ordinary.map(&:last).join.b)
      box('meta', "\0".b * 4 + @children.map { |type, bytes| type == 'ilst' ? ilst : bytes }.join.b)
    end

    private

    def validate_keys(data)
      fail!('invalid keys header') unless data.bytesize >= 8 && data.unpack1('N').zero?
      count = data.byteslice(4, 4).unpack1('N')
      fail!('keys count exceeds limit') if count > 50_000
      rows = boxes(data.byteslice(8..))
      fail!('keys count mismatch') unless rows.size == count
      keys = rows.map do |type, bytes|
        key = bytes.byteslice(8..).dup.force_encoding(Encoding::UTF_8)
        fail!('unsupported mdta key') unless type == 'mdta' && !key.empty? && key.valid_encoding? && !key.include?("\0")
        key
      end
      fail!('duplicate mdta keys') unless keys.uniq.size == keys.size
    end

    # metadataだけの境界検証。extended/zero-size headerはこのprofileでは拒否する。
    def boxes(data)
      rows, offset = [], 0
      while offset < data.bytesize
        fail!('too many metadata atoms') if rows.size >= 50_000
        fail!('truncated metadata atom') if data.bytesize - offset < 8
        size, type = data.byteslice(offset, 8).unpack('Na4')
        fail!('unsupported metadata boundary') unless size >= 8 && size <= data.bytesize - offset
        rows << [type, data.byteslice(offset, size)]
        offset += size
      end
      rows
    end

    def box(type, data)
      [data.bytesize + 8].pack('N') + type + data
    end

    def fail!(message)
      raise MetadataSnapshotError.new(message, code: :unsupported_unindexed_mdta, phase: :capture)
    end
  end
  private_constant :UnindexedMdtaPlan

  class File
    # 未対応index 0のraw bytesを保持し、通常タグだけを明示的に保存する。
    def save_preserving_unindexed_mdta
      phase, committed = :prepare, false
      source_path = name
      temp_path = "#{source_path}.taglib-mdta-#{Process.pid}-#{object_id}"
      begin
        if @chapter_changes.any? || @chapter_reference_repair || @chapter_timing_repair
          raise MdtaSaveError.new('save chapter and repair plans separately from unindexed metadata', phase: :prepare)
        end
        expected = unindexed_regular_snapshot
        raw_plan, sanitize_plan, preserved, chapters = prepare_unindexed_context(source_path)
        ::FileUtils.cp(source_path, temp_path)
        phase = :prepare
        sanitize_plan.write_copy(source_path, temp_path)
        phase = :taglib_save
        write_unindexed_regular_copy(temp_path, expected)
        phase = :reinsert
        reinsert_unindexed_copy(temp_path, raw_plan)
        phase = :verify
        verify_unindexed_copy(temp_path, raw_plan, expected, preserved, chapters)
        unless Digest::SHA256.file(source_path).hexdigest == sanitize_plan.source_digest
          raise MdtaSaveError.new('source changed during unindexed metadata save', phase: :verify)
        end
        phase = :replace
        ::FileUtils.mv(temp_path, source_path)
        committed = true
        phase = :reopen
        close
        initialize(source_path, false)
        true
      rescue MdtaSaveError
        raise
      rescue StandardError => error
        raise MdtaSaveError.new(error.message, committed: committed, phase: phase)
      ensure
        unless committed
          failure = $!
          begin
            ::FileUtils.rm_f(temp_path)
            ::FileUtils.rm_f("#{temp_path}.raw-reinsert")
          rescue StandardError => error
            raise MdtaSaveError.new("unindexed metadata cleanup failed: #{error.message}; temporary file: #{temp_path}", phase: :cleanup), cause: failure || error
          end
        end
      end
    end

    private

    # 原本からraw保持計画・作業用moov計画・保持署名・chapter期待値を取得する。
    def prepare_unindexed_context(source_path)
      self.class.open(source_path, false) do |original|
        issues = MetadataStructureReader.read(source_path, item_types: original.tag.item_map.to_a.to_h { |k, v| [k, v.type] })[:issues]
        unless issues.any? && issues.all? { |i| i[:code] == :invalid_index && i[:key_index].zero? }
          raise MdtaSaveError.new('unsupported unindexed metadata structure', phase: :prepare)
        end
        unless unindexed_alias_value(tag) == unindexed_alias_value(original.tag) &&
          tag.mdta_items == original.tag.mdta_items && tag._metadata_keys == original.tag._metadata_keys
          raise MdtaSaveError.new('opaque metadata aliases or mdta keys were edited', phase: :prepare)
        end
        plan = nil
        editor = MP4AtomEditor.new(original, metadata_transform: ->(raw) { plan = UnindexedMdtaPlan.new(raw); plan.sanitize(raw) })
        [plan, editor.atom_plan, editor.preservation_signature, original.chapter_snapshot]
      end
    end

    def unindexed_alias_value(value)
      item = value.item_map.to_a.find { |key, _v| key.empty? }&.last
      item && value.send(:snapshot_item_value, item)
    end

    # unsupportedなnative状態全体をcopyせず、通常itemの型付き値だけを取り出す。
    def unindexed_regular_snapshot
      rows = tag.item_map.to_a.reject { |key, _item| key.empty? }.map { |key, item| [key, *tag.send(:snapshot_item_value, item)] }
      MetadataSnapshot.new(items: rows, mdta: [])
    end

    def write_unindexed_regular_copy(path, expected)
      self.class.open(path, false) do |temporary|
        temporary.tag.restore_metadata_snapshot(expected)
        unless temporary.send(:save_without_chapter_state)
          raise MdtaSaveError.new('TagLib failed to save staged metadata', phase: :taglib_save)
        end
      end
    end

    # raw再挿入も別出力へ書き、一時コピー内の失敗を原本へ波及させない。
    def reinsert_unindexed_copy(path, raw_plan)
      output = "#{path}.raw-reinsert"
      self.class.open(path, false) do |temporary|
        editor = MP4AtomEditor.new(temporary, metadata_transform: raw_plan.method(:restore))
        editor.atom_plan.write_copy(path, output)
      end
      ::File.chmod(::File.stat(path).mode & 0o777, output)
      ::FileUtils.mv(output, path)
    end

    # native viewで見えないraw群も独立に比較し、順序・重複・payload喪失を拒否する。
    def verify_unindexed_copy(path, raw_plan, expected, preserved, chapters)
      self.class.open(path, false) do |verification|
        seen = nil
        editor = MP4AtomEditor.new(verification, metadata_transform: ->(raw) { seen = UnindexedMdtaPlan.new(raw); raw })
        unless seen.raw_signature == raw_plan.raw_signature && editor.preservation_signature == preserved &&
          expected.logical_equal?(verification.send(:unindexed_regular_snapshot)) && verification.chapter_snapshot == chapters
          raise MdtaSaveError.new('unindexed metadata preservation verification failed', phase: :verify)
        end
      end
    end
  end
end
