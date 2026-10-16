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

    def purl_row?(row)
      row[:raw_type] == 'purl' || (row[:key] == 'purl' && row[:interpretation] == :key_index)
    end

    # data子atomをwire順のまま値として読む。localeは通常itemのsnapshotで
    # 表現できないため、mdtaへ移す際はこのraw列を正本として扱う。
    def value_rows(raw)
      children = boxes(raw, 8)
      raise ArgumentError, 'purl must contain data atoms' if children.empty?
      unless children.all? { |type, bytes| type == 'data' && bytes.bytesize >= 16 }
        raise ArgumentError, 'purl contains unsupported child atoms'
      end

      children.map do |_type, bytes|
        data_type, locale = bytes.byteslice(8, 8).unpack('N2')
        [data_type, locale, bytes.byteslice(16..).b]
      end
    end

    def normalized_raw(raw)
      return raw unless raw.bytesize >= 8

      raw.byteslice(0, 4) + 'purl' + raw.byteslice(8..).to_s.b
    end

    # 実ファイルのraw atomをsnapshotへ所有コピーする。offsetは復元先へ持ち込まない。
    def raw_items(path, contexts)
      ::File.open(path, 'rb') do |io|
        contexts.flat_map do |context|
          context[:items].select { |row| purl_row?(row) }.map do |row|
            io.seek(row[:offset])
            { handler: context[:handler], item_index: row[:item_index],
              key_index: row[:key_index], key: row[:key], raw_type: row[:raw_type],
              raw: io.read(row[:end_offset] - row[:offset]) }
          end
        end
      end
    end

    # rawと公開値を照合する。改変snapshotやdata type変更をnative適用前に拒否する。
    def validate_raw!(snapshot)
      item = snapshot.items.assoc('purl')
      mdta = snapshot.mdta.find { |row| row[0] == 'purl' }
      rows = snapshot.source_structure[:purl_raw] || []
      return [] unless item || mdta
      return [] if rows.empty?
      valid = rows.size == 1
      if valid
        raw = rows.first[:raw]
        values = value_rows(raw)
        valid = raw.unpack1('N') == raw.bytesize &&
          if item
            item[1] == :string_list && raw.byteslice(4, 4) == 'purl' &&
              rows.first[:atom_data_type] == item[2] &&
              values.map { |_type, _locale, data| data } == item[3].map(&:b)
          else
            values == mdta[2].map { |type, locale, data| [type, locale, data.b] }
          end
      end
      unless valid
        raise MetadataSnapshotError.new('purl raw bytes do not match snapshot type/payload',
          code: :purl_raw_mismatch, phase: :restore)
      end
      rows
    rescue ArgumentError, TypeError, NoMethodError => error
      raise MetadataSnapshotError.new(error.message, code: :purl_raw_mismatch, phase: :restore)
    end

    def snapshot_values(snapshot, raw = nil)
      item = snapshot.items.assoc('purl')
      if item
        return value_rows(raw || (snapshot.source_structure[:purl_raw] || []).fetch(0).fetch(:raw))
      end

      snapshot.mdta.find { |row| row[0] == 'purl' }&.fetch(2)&.map do |type, locale, data|
        [type, locale, data.b]
      end || []
    end

    def context_purl_row(context)
      context[:items].find { |row| purl_row?(row) }
    end

    def context_has_fourcc_purl?(context)
      context[:items].any? { |row| row[:raw_type] == 'purl' }
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
                 contexts.find { |c| c[:handler] == 'mdir' } || contexts.first
               end
      fourcc_purl = target && target[:handler] == 'mdta' && context_has_fourcc_purl?(target)
      existing = target && context_purl_row(target)
      existing_key_index = if target&.fetch(:handler) == 'mdta'
                             target[:keys].index('purl')&.+(1)
                           end
      key_index = if target&.fetch(:handler) == 'mdta'
                    existing_key_index || target[:keys].length + 1
                  end
      code = if fourcc_purl
               :purl_fourcc_context
             elsif !allowed
               :ambiguous_purl_context
             elsif target.nil?
               :purl_context_creation_unsupported
             end
      reason = if fourcc_purl
                 :fourcc_purl
               elsif !allowed
                 :ambiguous_context
               elsif target[:handler] == 'mdta' && existing_key_index
                 :existing_mdta_key
               elsif target[:handler] == 'mdta'
                 :append_mdta_key
               else
                 :existing_mdir_context
               end
      { writable: allowed && !target.nil? && !fourcc_purl, existing: !existing.nil? || !existing_key_index.nil?, key_index: key_index,
        context_handler: target&.fetch(:handler), code: code, reason: reason,
        context: target && { path: target[:path], offset: target[:offset], handler: target[:handler] },
        contexts: contexts, issues: errors, paired: pair && allowed }
    end

    def read_row_raw(path, row)
      ::File.open(path, 'rb') do |io|
        io.seek(row[:offset])
        io.read(row[:end_offset] - row[:offset])
      end
    end

    def destination_purl_raw(path, target)
      context = target[:contexts].find { |candidate| candidate[:offset] == target[:context][:offset] }
      row = context && context_purl_row(context)
      row && read_row_raw(path, row)
    end

    # 既存keyのdata type集合を変更しない。値数やlocaleはsnapshot側へ置換できる。
    def validate_destination_data_type!(path, target, source_raw)
      destination_raw = destination_purl_raw(path, target)
      return unless destination_raw

      source_types = value_rows(source_raw).map(&:first).uniq
      destination_types = value_rows(destination_raw).map(&:first).uniq
      return if source_types == destination_types

      raise MetadataSnapshotError.new('purl data type change is unsupported',
        code: :purl_data_type_change, phase: :restore)
    rescue MetadataSnapshotError
      raise
    rescue ArgumentError, TypeError, NoMethodError => error
      raise MetadataSnapshotError.new(error.message, code: :purl_raw_mismatch, phase: :restore)
    end

    def mdta_candidate_snapshot(snapshot)
      rows = snapshot_values(snapshot)
      mdta = snapshot.mdta.reject { |row| row[0] == 'purl' }
      next_index = mdta.map { |row| row[1] }.max.to_i
      mdta << ['purl', next_index + 1, rows]
      MetadataSnapshot.new(items: snapshot.items.reject { |row| row[0] == 'purl' }, mdta: mdta,
                           source_structure: snapshot.source_structure, format_version: snapshot.format_version)
    end

    def expected_mdta_snapshot(current, snapshot, target)
      rows = snapshot_values(snapshot)
      key_index = target[:key_index] || current.mdta.map { |row| row[1] }.max.to_i + 1
      mdta = current.mdta.reject { |row| row[0] == 'purl' }
      mdta << ['purl', key_index, rows]
      raw_rows = snapshot.source_structure[:purl_raw] || []
      structure = current.source_structure.merge(purl_raw: raw_rows)
      MetadataSnapshot.new(items: current.items.reject { |row| row[0] == 'purl' }, mdta: mdta,
                           source_structure: structure, format_version: current.format_version)
    end

    # metadata atom全体を一度に再構成し、keysとilstのindexを同じ計画で更新する。
    def apply_mdta_purl(raw, source_raw, key_index)
      children = boxes(raw, 12)
      keys_row = children.find { |type, _bytes| type == 'keys' }
      ilst_row = children.find { |type, _bytes| type == 'ilst' }
      raise ArgumentError, 'mdta keys/ilst are missing' unless keys_row && ilst_row

      keys = boxes(keys_row[1], 16)
      key_names = keys.map { |_type, bytes| bytes.byteslice(8..).force_encoding(Encoding::UTF_8) }
      if key_names.include?('purl')
        raise ArgumentError, 'purl key index mismatch' unless key_names.index('purl') + 1 == key_index
        keys_bytes = keys_row[1]
      else
        raise ArgumentError, 'purl key must be appended' unless key_index == key_names.length + 1
        key_entry = box('mdta', 'purl'.b)
        keys_bytes = box('keys', keys_row[1].byteslice(8, 4) + [key_names.length + 1].pack('N') +
          keys.map(&:last).join.b + key_entry)
      end

      item_type = [key_index].pack('N')
      item = [source_raw.bytesize].pack('N') + item_type + source_raw.byteslice(8..).to_s.b
      ilst_items = boxes(ilst_row[1], 8)
      matches = ilst_items.each_index.select { |index| ilst_items[index][0] == item_type }
      if matches.empty?
        ilst_items << [item_type, item]
      else
        first = matches.first
        ilst_items[first] = [item_type, item]
        ilst_items = ilst_items.each_with_index.filter_map do |row, index|
          row unless matches.include?(index) && index != first
        end
      end
      ilst_bytes = box('ilst', ilst_items.map(&:last).join.b)
      payload = children.map do |type, bytes|
        type == 'keys' ? keys_bytes : type == 'ilst' ? ilst_bytes : bytes
      end.join.b
      box('meta', raw.byteslice(8, 4) + payload)
    end

    def extension_plan(file, source_raw, target)
      editor = MP4AtomEditor.new(file,
        metadata_transform: ->(raw) { apply_mdta_purl(raw, source_raw, target.fetch(:key_index)) })
      editor.atom_plan
    rescue MetadataSnapshotError
      raise
    rescue StandardError => error
      raise MetadataSnapshotError.new("cannot extend mdta metadata safely: #{error.message}",
        code: :purl_atom_extension_unsupported, phase: :restore)
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
      purl_item = snapshot.items.assoc('purl')
      purl_mdta = snapshot.mdta.find { |row| row[0] == 'purl' }
      return snapshot unless @metadata_source_path && (purl_item || purl_mdta)

      contexts = MetadataStructureReader.read(@metadata_source_path, detailed: true)[:structure][:contexts]
      MetadataSnapshot.new(items: snapshot.items, mdta: snapshot.mdta,
        source_structure: snapshot.source_structure.merge(purl_raw: PurlSnapshot.raw_items(@metadata_source_path, contexts).map do |row|
          row.merge(atom_data_type: purl_item&.fetch(2) || purl_mdta&.fetch(2)&.first&.first)
        end))
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
    # context固有のitem typeを正規化したpurl raw atomのSHA-256を順序付きで返す。
    def purl_raw_digests
      return [].freeze unless items.assoc('purl') || mdta.find { |row| row[0] == 'purl' }

      self.class.copy((source_structure[:purl_raw] || []).map do |row|
        Digest::SHA256.hexdigest(PurlSnapshot.normalized_raw(row.fetch(:raw)))
      end)
    end
  end

  class File
    alias initialize_without_purl_plan initialize
    alias metadata_context_diagnostics_without_purl_target metadata_context_diagnostics
    alias metadata_snapshot_without_purl_pair metadata_snapshot
    alias restore_metadata_snapshot_without_purl_pair restore_metadata_snapshot
    alias save_without_purl_pair save
    alias save_temporary_copy_without_purl_raw save_temporary_copy
    private :save_temporary_copy_without_purl_raw

    def initialize(*args)
      initialize_without_purl_plan(*args)
      @purl_mdta_plan = nil
      @purl_mdta_snapshot = nil
    end

    # purlの保存先と、新規復元に利用できるかを機械判定可能な形で公開する。
    def metadata_context_diagnostics
      report = metadata_context_diagnostics_without_purl_target
      target = PurlSnapshot.destination(name)
      MetadataSnapshot.copy(report.merge(purl: target.reject { |key, _| %i[contexts issues paired].include?(key) }))
    end

    # 一意なmdta＋mdirを個別にnative解析し、通常itemとmdta値を完全なsnapshotへ合成する。
    def metadata_snapshot
      return @purl_mdta_snapshot if @purl_mdta_snapshot
      return @purl_pair_snapshot if @purl_pair_snapshot
      target = PurlSnapshot.destination(name)
      return metadata_snapshot_without_purl_pair unless target[:paired]

      snapshots = target[:contexts].map do |context|
        PurlSnapshot.isolated(name, target[:contexts], context) do |path|
          self.class.open(path, false) { |file| file.__send__(:metadata_snapshot_without_purl_pair) }
        end
      end
      MetadataSnapshot.new(items: snapshots.flat_map(&:items), mdta: snapshots.flat_map(&:mdta),
        source_structure: { contexts: target[:contexts].map { |c| c.slice(:path, :handler, :keys) },
          purl_raw: PurlSnapshot.raw_items(name, target[:contexts]).map { |row| row.merge(atom_data_type: snapshots.flat_map(&:items).assoc('purl')&.fetch(2)) } })
    end

    # 複合contextは候補snapshotを検証してから保留する。saveが全contextを原子的に置換する。
    def restore_metadata_snapshot(snapshot)
      target = PurlSnapshot.destination(name)
      has_purl = snapshot.is_a?(MetadataSnapshot) &&
        (snapshot.items.assoc('purl') || snapshot.mdta.find { |row| row[0] == 'purl' })
      if target[:context_handler] == 'mdta' && !target[:paired] && has_purl
        return prepare_mdta_purl_restore(snapshot, target)
      end
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
      return save_purl_mdta_extension(*args) if @purl_mdta_plan&.fetch(:mode) == :direct
      return save_without_purl_pair(*args) unless @purl_pair_snapshot
      raise ArgumentError, 'save does not accept arguments' unless args.empty?
      save_purl_pair
    end

    private

    # 通常itemのpurlだけを既存mdtaへ移す。値列以外の保存を伴わない場合は、
    # native writerを通さずatom拡張計画だけを保留して既存metadataを完全保持する。
    def prepare_mdta_purl_restore(snapshot, target)
      checked = MetadataSnapshot.new(items: snapshot.items, mdta: snapshot.mdta,
        source_structure: snapshot.source_structure, format_version: snapshot.format_version)
      rows = PurlSnapshot.validate_raw!(checked)
      if rows.empty?
        raise MetadataSnapshotError.new('purl raw bytes are required for mdta restoration',
          code: :purl_raw_missing, phase: :restore)
      end
      context = target[:contexts].find { |candidate| candidate[:offset] == target[:context][:offset] }
      if PurlSnapshot.context_has_fourcc_purl?(context)
        raise MetadataSnapshotError.new('cannot add purl while mdta contains a fourcc purl item',
          code: :purl_fourcc_context, phase: :restore)
      end
      PurlSnapshot.validate_destination_data_type!(name, target, rows.first.fetch(:raw))
      current = metadata_snapshot_without_purl_pair
      expected = PurlSnapshot.expected_mdta_snapshot(current, checked, target)
      source_digest = Digest::SHA256.file(name).hexdigest
      baseline = metadata_save_signature
      purl_only = (checked.items.all? { |row| row[0] == 'purl' } && checked.mdta.empty?) ||
        (checked.items.empty? && checked.mdta.all? { |row| row[0] == 'purl' })
      if purl_only
        atom_plan = PurlSnapshot.extension_plan(self, rows.first.fetch(:raw), target)
        @purl_mdta_plan = { mode: :direct, atom_plan: atom_plan, raw: rows.first.fetch(:raw),
                            expected: expected, baseline: baseline, source_digest: source_digest,
                            chapters: chapter_snapshot }
        @purl_mdta_snapshot = expected
        return self
      end

      candidate = PurlSnapshot.mdta_candidate_snapshot(checked)
      restore_metadata_snapshot_without_purl_pair(candidate)
      @purl_mdta_plan = { mode: :native, raw: rows.first.fetch(:raw), expected: candidate,
                          baseline: baseline, source_digest: source_digest }
      @purl_mdta_snapshot = candidate
      self
    end

    def save_purl_mdta_extension(*args)
      raise ArgumentError, 'save does not accept arguments' unless args.empty?

      plan = @purl_mdta_plan
      unless metadata_save_signature == plan[:baseline] && @chapter_changes.empty? &&
          !@chapter_reference_repair && !@chapter_timing_repair
        raise MdtaSaveError.new('save snapshot separately from native edits and chapter plans',
          phase: :prepare, code: :pending_changes)
      end
      target = PurlSnapshot.destination(name)
      unless target[:context_handler] == 'mdta' && !target[:paired] &&
          Digest::SHA256.file(name).hexdigest == plan[:source_digest]
        raise MdtaSaveError.new('snapshot destination changed', phase: :prepare, code: :source_changed)
      end

      path = "#{name}.taglib-mdta-#{Process.pid}-#{object_id}"
      committed = false
      media = mdat_payload_signature(name)
      chapters = chapter_snapshot
      plan[:atom_plan].write_copy(name, path)
      ::File.chmod(::File.stat(name).mode & 0o777, path)
      self.class.open(path, false) do |file|
        actual = file.metadata_snapshot
        unless plan[:expected].same_values?(actual) &&
            plan[:expected].purl_raw_digests == actual.purl_raw_digests &&
            file.send(:mdat_payload_signature, path) == media && file.chapter_snapshot == chapters
          raise MdtaSaveError.new('mdta purl extension verification failed',
            phase: :verify, code: :purl_raw_mismatch)
        end
      end
      unless Digest::SHA256.file(name).hexdigest == plan[:source_digest]
        raise MdtaSaveError.new('source changed during snapshot save', phase: :verify, code: :source_changed)
      end
      source = name
      ::FileUtils.mv(path, source)
      committed = true
      close
      initialize(source, false)
      true
    rescue MdtaSaveError
      raise
    rescue StandardError => error
      raise MdtaSaveError.new(error.message, phase: committed ? :reopen : :verify, committed: committed)
    ensure
      ::FileUtils.rm_f(path) if path && !committed
    end

    # native保存後は明示された復元計画か未編集fourccだけを補完する。mdtaはnativeへ任せる。
    def save_temporary_copy(path, write_metadata:)
      save_temporary_copy_without_purl_raw(path, write_metadata: write_metadata)
      return unless write_metadata

      if @purl_mdta_plan
        restore_mdta_purl_copy(path, @purl_mdta_plan.fetch(:raw)) if @purl_mdta_plan.fetch(:mode) == :native
        return
      end

      rows = ordinary_purl_restore_rows
      restore_purl_raw_copy(path, rows.first.fetch(:raw)) unless rows.empty?
    end

    # 通常itemの署名が存在し不変の場合だけrawを補完する。数値keyをfourccへ渡さない。
    def ordinary_purl_restore_rows
      rows = tag.instance_variable_get(:@metadata_purl_restore)
      if rows.nil?
        original = @mp4_metadata_snapshot[:items].assoc('purl')
        return [] unless original && original == metadata_save_signature[:items].assoc('purl')

        rows = PurlSnapshot.raw_items(name, PurlSnapshot.destination(name)[:contexts])
      end
      rows.select { |row| row[:key_index].nil? }
    end

    # atom変換の作業コピー作成・mode保持・置換・cleanupを全復元経路で共有する。
    def rewrite_metadata_copy(path, suffix, &transform)
      output = path + suffix
      self.class.open(path, false) do |file|
        editor = MP4AtomEditor.new(file, metadata_transform: transform)
        editor.atom_plan.write_copy(path, output)
      end
      ::File.chmod(::File.stat(path).mode & 0o777, output)
      ::FileUtils.mv(output, path)
    ensure
      ::FileUtils.rm_f(output) if output
    end

    # snapshotの明示rawを既存の数値keyへ適用する。公開mdta setterの保存には使わない。
    def restore_mdta_purl_copy(path, raw)
      target = PurlSnapshot.destination(path)
      unless target[:context_handler] == 'mdta' && !target[:paired]
        raise MdtaSaveError.new('cannot locate destination mdta for purl', phase: :taglib_save,
          code: :purl_atom_extension_unsupported)
      end
      key_index = target.fetch(:key_index)
      rewrite_metadata_copy(path, '.purl-mdta') do |meta|
        PurlSnapshot.apply_mdta_purl(meta, raw, key_index)
      end
    rescue MdtaSaveError
      raise
    rescue StandardError => error
      raise MdtaSaveError.new("cannot restore purl raw mdta item: #{error.message}",
        phase: :taglib_save, code: :purl_atom_extension_unsupported)
    end

    # 通常itemのrawを元位置へ戻し、独立parserで完全一致を検証する。
    def restore_purl_raw_copy(path, raw)
      original = PurlSnapshot.destination(name)
      position = original[:contexts].flat_map { |c| c[:items] }.find { |r| r[:raw_type] == 'purl' }&.fetch(:item_index)
      rewrite_metadata_copy(path, '.purl-raw') do |meta|
        PurlSnapshot.replace_raw(meta, raw, position: position)
      end
      actual = PurlSnapshot.raw_items(path, PurlSnapshot.destination(path)[:contexts])
      unless actual.map { |r| r[:raw] } == [raw]
        raise MdtaSaveError.new('restored purl raw verification failed', phase: :verify, code: :purl_raw_mismatch)
      end
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
