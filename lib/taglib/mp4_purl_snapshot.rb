# frozen_string_literal: true

require 'tempfile'

module TagLib::MP4
  # purlのraw atomと一意な保存先を検証し、native writerによる型変換を避ける。
  module PurlSnapshot
    module_function

    def box(type, data)
      [data.bytesize + 8].pack('N') + type.b + data.b
    end

    def boxes(raw, start = 0)
      rows, offset = [], start
      while offset < raw.bytesize
        size, type = raw.byteslice(offset, 8)&.unpack('Na4')
        raise ArgumentError, 'invalid purl atom boundary' unless size && size >= 8 && size <= raw.bytesize - offset
        rows << [type, raw.byteslice(offset, size)]
        offset += size
      end
      rows
    end

    # 実ファイルのraw atomをsnapshotへ所有コピーする。offsetは復元先へ持ち込まない。
    def raw_items(path, contexts)
      ::File.open(path, 'rb') do |io|
        contexts.flat_map do |context|
          context[:items].select { |row| row[:raw_type] == 'purl' }.map do |row|
            io.seek(row[:offset])
            { handler: context[:handler], item_index: row[:item_index],
              raw: io.read(row[:end_offset] - row[:offset]) }
          end
        end
      end
    end

    # rawと公開値を照合する。改変snapshotやdata type変更をnative適用前に拒否する。
    def validate_raw!(snapshot)
      item = snapshot.items.assoc('purl')
      rows = snapshot.source_structure[:purl_raw] || []
      return [] unless item
      return [] if rows.empty?
      valid = rows.size == 1 && item[1] == :string_list
      if valid
        raw = rows.first[:raw]
        children = boxes(raw, 8)
        valid = rows.first[:atom_data_type] == item[2] && raw.byteslice(4, 4) == 'purl' && raw.unpack1('N') == raw.bytesize &&
          !children.empty? && children.all? { |type, bytes| type == 'data' && bytes.bytesize >= 16 &&
            bytes.byteslice(12, 4).unpack1('N').zero? } &&
          children.map { |_type, bytes| bytes.byteslice(16..) } == item[3].map(&:b)
      end
      unless valid
        raise MetadataSnapshotError.new('purl raw bytes do not match snapshot type/payload',
          code: :purl_raw_mismatch, phase: :restore)
      end
      rows
    rescue ArgumentError, TypeError, NoMethodError => error
      raise MetadataSnapshotError.new(error.message, code: :purl_raw_mismatch, phase: :restore)
    end

    # 単一context、またはmdta＋mdir各1個のみを認める。通常itemの重複は保存先の曖昧さとして拒否する。
    def destination(path, item_types: {})
      report = MetadataStructureReader.read(path, detailed: true, item_types: item_types)
      contexts = report[:structure][:contexts] || []
      errors = report[:issues].reject { |issue| %i[multiple_meta unrepresented_item].include?(issue[:code]) }
      pair = contexts.size == 2 && contexts.map { |c| c[:handler] }.sort == %w[mdir mdta]
      allowed = errors.empty? && (contexts.size == 1 || pair)
      # 2 contextの場合は通常itemをmdirへ集約済みの構造だけが一意に編集可能。
      if pair
        allowed &&= contexts.find { |c| c[:handler] == 'mdta' }[:items].all? { |row| row[:interpretation] == :key_index }
      end
      target = if allowed
                 contexts.find { |c| c[:handler] == 'mdir' } ||
                   contexts.find { |c| c[:items].any? { |row| row[:raw_type] == 'purl' } }
               end
      code = allowed ? (target ? nil : :purl_context_creation_unsupported) : :ambiguous_purl_context
      { writable: !target.nil?, code: code, context: target && { path: target[:path], offset: target[:offset], handler: target[:handler] },
        contexts: contexts, issues: errors, paired: pair && allowed }
    end

    # 他contextを同じ長さのfreeへ隠す一時コピーでnativeを使う。原本には書き込まない。
    def isolated(path, contexts, target)
      Tempfile.create(['taglib-purl-', '.mp4']) do |temp|
        temp.close
        ::FileUtils.cp(path, temp.path)
        ::File.open(temp.path, 'r+b') do |io|
          contexts.reject { |c| c[:offset] == target[:offset] }.each do |context|
            io.seek(context[:offset] + 4)
            io.write('free')
          end
        end
        yield temp.path
      end
    end

    # native生成metaのpurlだけを置換し、既存位置とdata子atom順を保持する。
    def replace_raw(raw, purl, position: nil)
      children = boxes(raw, 12)
      children = children.map do |type, bytes|
        next [type, bytes] unless type == 'ilst'
        items = boxes(bytes, 8)
        existing = items.index { |name, _| name == 'purl' }
        items.reject! { |name, _| name == 'purl' }
        items.insert([position || existing || items.size, items.size].min, ['purl', purl]) if purl
        [type, box('ilst', items.map(&:last).join.b)]
      end
      box('meta', raw.byteslice(8, 4) + children.map(&:last).join.b)
    end

    def read_meta(path, context)
      ::File.open(path, 'rb') do |io|
        io.seek(context[:offset])
        io.read(context[:end_offset] - context[:offset])
      end
    end
  end
  private_constant :PurlSnapshot

  class Tag
    alias metadata_snapshot_without_purl_raw metadata_snapshot
    alias restore_metadata_snapshot_without_purl_preflight restore_metadata_snapshot

    # 再読込後にもpurlのraw digestを比較できる、所有bytes付きsnapshotを返す。
    def metadata_snapshot
      snapshot = metadata_snapshot_without_purl_raw
      return snapshot unless @metadata_source_path && snapshot.items.assoc('purl')

      contexts = MetadataStructureReader.read(@metadata_source_path, detailed: true)[:structure][:contexts]
      MetadataSnapshot.new(items: snapshot.items, mdta: snapshot.mdta,
        source_structure: snapshot.source_structure.merge(purl_raw: PurlSnapshot.raw_items(@metadata_source_path, contexts).map { |row| row.merge(atom_data_type: snapshot.items.assoc('purl')[2]) }))
    end

    alias metadata_capabilities_without_purl_raw metadata_capabilities

    # context生成の可否は、既存mdirへのraw復元機能と区別して公開する。
    def metadata_capabilities
      MetadataSnapshot.copy(metadata_capabilities_without_purl_raw.merge(
        purl_raw_snapshot_v1: true, purl_existing_mdir_restore_v1: true, purl_context_creation: false))
    end

    # purl保存不可はnative状態変更前に報告する。raw保持計画も成功時だけ更新する。
    def restore_metadata_snapshot(snapshot)
      rows = snapshot.is_a?(MetadataSnapshot) ? PurlSnapshot.validate_raw!(snapshot) : []
      if snapshot.is_a?(MetadataSnapshot) && snapshot.items.assoc('purl') && @metadata_source_path
        result = PurlSnapshot.destination(@metadata_source_path)
        unless result[:writable]
          raise MetadataSnapshotError.new('destination cannot preserve purl metadata context',
            code: result[:code], phase: :restore, issues: result[:issues])
        end
      end
      restore_metadata_snapshot_without_purl_preflight(snapshot)
      @metadata_purl_restore = rows
      self
    end
  end

  class MetadataSnapshot
    # purlの完全raw atomのSHA-256を順序付きで返す。例: source.purl_raw_digests == reopened.purl_raw_digests。
    def purl_raw_digests
      return [].freeze unless items.assoc('purl')

      self.class.copy((source_structure[:purl_raw] || []).map { |row| Digest::SHA256.hexdigest(row.fetch(:raw)) })
    end
  end

  class File
    alias metadata_context_diagnostics_without_purl_target metadata_context_diagnostics
    alias metadata_snapshot_without_purl_pair metadata_snapshot
    alias restore_metadata_snapshot_without_purl_pair restore_metadata_snapshot
    alias save_without_purl_pair save
    alias save_temporary_copy_without_purl_raw save_temporary_copy
    private :save_temporary_copy_without_purl_raw

    # purlの保存先と、新規復元に利用できるかを機械判定可能な形で公開する。
    def metadata_context_diagnostics
      report = metadata_context_diagnostics_without_purl_target
      target = PurlSnapshot.destination(name)
      MetadataSnapshot.copy(report.merge(purl: target.reject { |key, _| %i[contexts issues paired].include?(key) }))
    end

    # 一意なmdta＋mdirを個別にnative解析し、通常itemとmdta値を完全なsnapshotへ合成する。
    def metadata_snapshot
      return @purl_pair_snapshot if @purl_pair_snapshot
      target = PurlSnapshot.destination(name)
      return metadata_snapshot_without_purl_pair unless target[:paired]

      snapshots = target[:contexts].map do |context|
        PurlSnapshot.isolated(name, target[:contexts], context) do |path|
          self.class.open(path, false) { |file| file.metadata_snapshot_without_purl_pair }
        end
      end
      MetadataSnapshot.new(items: snapshots.flat_map(&:items), mdta: snapshots.flat_map(&:mdta),
        source_structure: { contexts: target[:contexts].map { |c| c.slice(:path, :handler, :keys) },
          purl_raw: PurlSnapshot.raw_items(name, target[:contexts]).map { |row| row.merge(atom_data_type: snapshots.flat_map(&:items).assoc('purl')&.fetch(2)) } })
    end

    # 複合contextは候補snapshotを検証してから保留する。saveが全contextを原子的に置換する。
    def restore_metadata_snapshot(snapshot)
      target = PurlSnapshot.destination(name)
      return restore_metadata_snapshot_without_purl_pair(snapshot) unless target[:paired]
      unless snapshot.is_a?(MetadataSnapshot)
        raise MetadataSnapshotError.new('expected MetadataSnapshot', code: :invalid_snapshot, phase: :restore)
      end
      checked = MetadataSnapshot.new(items: snapshot.items, mdta: snapshot.mdta, source_structure: snapshot.source_structure,
        format_version: snapshot.format_version)
      PurlSnapshot.validate_raw!(checked)
      source_digest = Digest::SHA256.file(name).hexdigest
      # 両contextの候補は原本へ適用せず、同じnative契約で全て検証する。
      stage_purl_pair(checked, target)
      unless Digest::SHA256.file(name).hexdigest == source_digest
        raise MetadataSnapshotError.new('destination changed during restore preflight', code: :source_changed, phase: :restore)
      end
      @purl_pair_baseline = metadata_save_signature
      @purl_pair_source_digest = source_digest
      @purl_pair_snapshot = checked
      self
    end

    # 保留snapshotがある場合のみ複合保存経路へ分岐する。
    def save(*args)
      return save_without_purl_pair(*args) unless @purl_pair_snapshot
      raise ArgumentError, 'save does not accept arguments' unless args.empty?
      save_purl_pair
    end

    private

    # 単一contextもnative保存後の一時コピー内でraw purlを復元し、検証してからcommitする。
    def save_temporary_copy(path, write_metadata:)
      save_temporary_copy_without_purl_raw(path, write_metadata: write_metadata)
      rows = tag.instance_variable_get(:@metadata_purl_restore)
      if rows.nil? && @mp4_metadata_snapshot[:items].assoc('purl') == metadata_save_signature[:items].assoc('purl')
        rows = PurlSnapshot.raw_items(name, PurlSnapshot.destination(name)[:contexts])
      end
      return unless write_metadata && rows && !rows.empty?
      restore_purl_raw_copy(path, rows.first[:raw])
    end

    def restore_purl_raw_copy(path, raw)
      original = PurlSnapshot.destination(name)
      position = original[:contexts].flat_map { |c| c[:items] }.find { |r| r[:raw_type] == 'purl' }&.fetch(:item_index)
      output = path + '.purl-raw'
      self.class.open(path, false) do |file|
        editor = MP4AtomEditor.new(file, metadata_transform: ->(meta) { PurlSnapshot.replace_raw(meta, raw, position: position) })
        editor.atom_plan.write_copy(path, output)
      end
      ::File.chmod(::File.stat(path).mode & 0o777, output)
      ::FileUtils.mv(output, path)
      actual = PurlSnapshot.raw_items(path, PurlSnapshot.destination(path)[:contexts])
      unless actual.map { |r| r[:raw] } == [raw]
        raise MdtaSaveError.new('restored purl raw verification failed', phase: :verify, code: :purl_raw_mismatch)
      end
    ensure
      ::FileUtils.rm_f(output) if output
    end

    # contextを隠した作業コピーでnativeへ候補を適用し、各保存済みmeta bytesを得る。
    def stage_purl_pair(snapshot, target)
      rendered = target[:contexts].to_h do |context|
        bytes = PurlSnapshot.isolated(name, target[:contexts], context) do |path|
          self.class.open(path, false) do |file|
            candidate = MetadataSnapshot.new(items: context[:handler] == 'mdir' ? snapshot.items : [],
              mdta: context[:handler] == 'mdta' ? snapshot.mdta : [],
              source_structure: context[:handler] == 'mdir' ? snapshot.source_structure : {})
            file.restore_metadata_snapshot(candidate)
            file.save
          end
          staged = PurlSnapshot.destination(path)[:contexts].first
          PurlSnapshot.read_meta(path, staged)
        end
        [context[:handler], bytes]
      end
      # FFmpegはmdta検出状態を次のmetaへ持ち越すため、mdirを先に配置する。
      target[:contexts].sort_by { |c| c[:offset] }.zip(%w[mdir mdta]).to_h do |context, handler|
        bytes = rendered.fetch(handler)
        [context[:offset], ->(_raw) { bytes }]
      end
    end

    # 全候補・raw・media・原本SHAを照合した後だけrenameする。
    def save_purl_pair
      committed = false
      path = "#{name}.taglib-mdta-#{Process.pid}-#{object_id}"
      unless metadata_save_signature == @purl_pair_baseline && @chapter_changes.empty? &&
          !@chapter_reference_repair && !@chapter_timing_repair
        raise MdtaSaveError.new('save snapshot separately from native edits and chapter plans', phase: :prepare, code: :pending_changes)
      end
      target = PurlSnapshot.destination(name)
      unless target[:paired] && Digest::SHA256.file(name).hexdigest == @purl_pair_source_digest
        raise MdtaSaveError.new('snapshot destination changed', phase: :prepare, code: :source_changed)
      end
      expected = @purl_pair_snapshot
      transforms = stage_purl_pair(expected, target)
      media = mdat_payload_signature(name)
      chapters = chapter_snapshot
      editor = MP4AtomEditor.new(self, metadata_transforms: transforms)
      editor.atom_plan.write_copy(name, path)
      ::File.chmod(::File.stat(name).mode & 0o777, path)
      self.class.open(path, false) do |file|
        actual = file.metadata_snapshot
        raw_equal = expected.purl_raw_digests.empty? || expected.purl_raw_digests == actual.purl_raw_digests
        unless expected.same_values?(actual) && raw_equal &&
            file.send(:mdat_payload_signature, path) == media && file.chapter_snapshot == chapters
          raise MdtaSaveError.new('paired metadata verification failed', phase: :verify, code: :purl_raw_mismatch)
        end
      end
      unless Digest::SHA256.file(name).hexdigest == editor.source_digest
        raise MdtaSaveError.new('source changed during snapshot save', phase: :verify, code: :source_changed)
      end
      source = name
      ::FileUtils.mv(path, source)
      committed = true
      close
      @purl_pair_snapshot = nil
      initialize(source, false)
      true
    rescue MdtaSaveError
      raise
    rescue StandardError => error
      raise MdtaSaveError.new(error.message, phase: committed ? :reopen : :prepare, committed: committed)
    ensure
      ::FileUtils.rm_f(path) if path && !committed
    end
  end
end
