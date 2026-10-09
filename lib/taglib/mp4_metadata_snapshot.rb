# frozen_string_literal: true

module TagLib::MP4
  # Capture/restore failures describe a rejected operation; File#save keeps its existing error contract.
  class MetadataSnapshotError < ArgumentError
    attr_reader :code, :phase, :issues

    def initialize(message, code:, phase:, issues: [])
      @code, @phase, @issues = code, phase, MetadataSnapshot.copy(issues)
      super(message)
    end
  end

  # Immutable, Ruby-owned typed metadata. Example: tag.restore_metadata_snapshot(source.tag.metadata_snapshot).
  # items: [key, kind, atom_data_type, payload]; mdta: [key, source_index, [[type, locale, binary], ...]].
  class MetadataSnapshot
    KINDS = %i[bool int int_pair byte uint long_long string_list byte_vector_list cover_art_list].freeze
    attr_reader :format_version, :items, :mdta, :source_structure

    def initialize(items:, mdta:, source_structure: {}, format_version: 1)
      fail_input('unsupported snapshot version') unless format_version == 1
      fail_input('items and mdta must be Arrays') unless items.is_a?(Array) && mdta.is_a?(Array)
      validate_items!(items)
      validate_mdta!(mdta)
      fail_input('source_structure must be a Hash') unless source_structure.is_a?(Hash)
      @format_version = format_version
      @items = self.class.copy(items.map do |key, kind, type, payload|
        [key, kind, type, binary_payload(kind, payload)]
      end.sort_by(&:first))
      @mdta = self.class.copy(mdta.map { |key, index, values| [key, index, values.map { |type, locale, bytes| [type, locale, bytes.b] }] })
      @source_structure = self.class.copy(source_structure)
      freeze
    end

    # Compare ordered values within keys, allowing independent destination keys-table indices.
    def logical_equal?(other)
      other.is_a?(self.class) && items == other.items && logical_mdta == other.send(:logical_mdta)
    end

    # Observed metadata structure only; this does not mean byte-identical MP4/unknown atoms.
    def structure_equal?(other)
      logical_equal?(other) && mdta.map { |k, i, _v| [k, i] } == other.mdta.map { |k, i, _v| [k, i] } &&
        source_structure == other.source_structure
    end

    def self.copy(value)
      copied = case value
               when Hash then value.to_h { |k, v| [copy(k), copy(v)] }
               when Array then value.map { |v| copy(v) }
               when String then value.dup
               when Symbol, Integer, TrueClass, FalseClass, NilClass then value
               else raise ArgumentError, "unsupported snapshot value: #{value.class}"
               end
      copied.freeze
    end

    private

    # Validate the complete input before creating the immutable representation.
    def validate_items!(items)
      seen = {}
      items.each do |row|
        fail_input('invalid item row') unless row.is_a?(Array) && row.length == 4
        key, kind, type, payload = row
        text!(key, 'item key', nul: false)
        fail_input('duplicate item key') if seen[key]
        seen[key] = true
        fail_input('unsupported item kind') unless KINDS.include?(kind)
        integer!(type, 0, 0xffff_ffff)
        validate_payload!(kind, payload)
      end
    end

    def validate_mdta!(mdta)
      seen = {}
      indices = {}
      mdta.each do |row|
        fail_input('invalid mdta group') unless row.is_a?(Array) && row.length == 3
        key, index, values = row
        text!(key, 'mdta key', nul: false)
        integer!(index, 1, 0xffff_ffff)
        fail_input('duplicate mdta key/index') if seen[key] || indices[index]
        seen[key] = indices[index] = true
        fail_input('mdta values must be an Array') unless values.is_a?(Array)
        values.each do |value|
          fail_input('invalid mdta value') unless value.is_a?(Array) && value.length == 3
          integer!(value[0], 0, 0xffff_ffff)
          integer!(value[1], 0, 0xffff_ffff)
          fail_input('mdta data must be a String') unless value[2].is_a?(String)
        end
      end
    end

    def binary_payload(kind, payload)
      case kind
      when :byte_vector_list then payload.map(&:b)
      when :cover_art_list then payload.map { |format, bytes| [format, bytes.b] }
      else payload
      end
    end

    def logical_mdta
      mdta.reject { |_key, _index, values| values.empty? }.to_h { |key, _index, values| [key, values] }
    end

    def fail_input(message)
      raise MetadataSnapshotError.new(message, code: :invalid_snapshot, phase: :validate)
    end

    def integer!(value, min, max)
      fail_input('integer outside supported range') unless value.is_a?(Integer) && value.between?(min, max)
    end

    def text!(value, name, nul: true)
      unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?
        fail_input("#{name} must be UTF-8")
      end
      fail_input("#{name} must not be empty or contain NUL") if !nul && (value.empty? || value.include?("\0"))
    end

    def validate_payload!(kind, payload)
      case kind
      when :bool then fail_input('bool must be true/false') unless payload == true || payload == false
      when :int then integer!(payload, -0x8000_0000, 0x7fff_ffff)
      when :byte then integer!(payload, 0, 255)
      when :uint then integer!(payload, 0, 0xffff_ffff)
      when :long_long then integer!(payload, -0x8000_0000_0000_0000, 0x7fff_ffff_ffff_ffff)
      when :int_pair
        fail_input('int_pair requires two integers') unless payload.is_a?(Array) && payload.length == 2
        payload.each { |value| integer!(value, -0x8000_0000, 0x7fff_ffff) }
      when :string_list
        fail_input('string_list requires an Array') unless payload.is_a?(Array)
        payload.each { |value| text!(value, 'item text') }
      when :byte_vector_list
        fail_input('byte_vector_list requires Strings') unless payload.is_a?(Array) && payload.all? { |v| v.is_a?(String) }
      when :cover_art_list
        fail_input('cover_art_list requires an Array') unless payload.is_a?(Array)
        payload.each do |art|
          fail_input('invalid artwork') unless art.is_a?(Array) && art.length == 2 && art[1].is_a?(String)
          integer!(art[0], 0, 0xffff_ffff)
        end
      end
    end
  end

  # Read-only result; an unknown or incomplete structure is never declared restorable.
  class MetadataDiagnostics
    attr_reader :status, :issues, :structure, :capabilities

    def initialize(status:, issues:, structure: {}, capabilities: {})
      @status, @issues, @structure = status, MetadataSnapshot.copy(issues), MetadataSnapshot.copy(structure)
      @capabilities = MetadataSnapshot.copy(capabilities)
      freeze
    end

    def restorable?
      %i[absent editable].include?(status) && issues.none? { |issue| issue[:severity] == :error }
    end
  end

  # Bounded metadata-only inspection. Media payloads are skipped; no repair/write is performed.
  class MetadataStructureReader
    LIMIT = 64 * 1024 * 1024
    CONTAINERS = %w[moov udta trak mdia].freeze

    def self.read(path, item_types: {})
      new.read(path, item_types: item_types)
    end

    def read(path, item_types: {})
      @item_types = item_types
      @issues, @metas, @count = [], [], 0
      @ordinary_keys = {}
      ::File.open(path, 'rb') { |io| walk(io, 0, io.stat.size, []) }
      issue(:multiple_meta, 'metadata', 'multiple metadata contexts') if @metas.length > 1
      { issues: @issues, structure: { contexts: @metas } }
    rescue StandardError => error
      { issues: [{ code: :unreadable_structure, severity: :error, path: 'metadata', message: error.message }], structure: {} }
    end

    private

    def issue(code, path, message, **fields)
      @issues << { code: code, severity: :error, path: path, message: message, **fields }
    end

    def boxes(io, start, limit)
      offset = start
      rows = []
      while offset < limit
        @count += 1
        raise 'metadata atom count exceeds limit' if @count > 50_000
        raise 'truncated atom header' if limit - offset < 8
        io.seek(offset)
        size, type = io.read(8).unpack('Na4')
        header = 8
        if size == 1
          header = 16
          raise 'truncated extended atom header' if limit - offset < header
          size = io.read(8).unpack1('Q>')
        elsif size.zero?
          size = limit - offset
        end
        raise 'invalid atom length' if size < header || size > limit - offset
        rows << [type, offset + header, offset + size, header]
        offset += size
      end
      rows
    end

    def walk(io, start, limit, path)
      raise 'metadata nesting exceeds limit' if path.length > 8
      boxes(io, start, limit).each do |type, payload, finish, header|
        current = path + [type]
        if type == 'meta'
          issue(:unsupported_scope, current.join('/'), 'metadata outside moov/udta') unless path == %w[moov udta]
          inspect_meta(io, payload, finish, current, header)
        elsif type == 'moof'
          issue(:fragmented_file, current.join('/'), 'fragmented MP4 is unsupported')
        elsif CONTAINERS.include?(type)
          walk(io, payload, finish, current)
        end
      end
    end

    def inspect_meta(io, start, finish, path, header)
      name = path.join('/')
      raise 'metadata exceeds inspection size limit' if finish - start > LIMIT
      issue(:extended_metadata, name, 'extended metadata atom is unsupported') unless header == 8
      io.seek(start)
      flags = io.read(4)
      raise 'truncated metadata FullBox' unless flags&.bytesize == 4
      issue(:invalid_fullbox, name, 'meta version/flags must be zero') unless flags == "\0".b * 4
      children = boxes(io, start + 4, finish)
      %w[hdlr keys ilst].each do |type|
        issue(:duplicate_atom, name + '/' + type, 'duplicate metadata atom') if children.count { |r| r[0] == type } > 1
      end
      handler_row = children.find { |r| r[0] == 'hdlr' }
      handler = if handler_row && handler_row[2] - handler_row[1] >= 12
                  io.seek(handler_row[1] + 8)
                  io.read(4)
                end
      key_row = children.find { |r| r[0] == 'keys' }
      ilst = children.find { |r| r[0] == 'ilst' }
      unless %w[mdta mdir].include?(handler) && ilst && ((handler == 'mdta') == !key_row.nil?)
        issue(:handler_keys_mismatch, name, 'handler/keys/ilst do not match a supported layout')
      end
      keys = key_row ? read_keys(io, key_row, name) : []
      @metas << { path: name, handler: handler, keys: keys }
      return unless ilst

      boxes(io, ilst[1], ilst[2]).each do |type, payload, ending, _h|
        unless handler == 'mdta' && type.getbyte(0) == 0
          inspect_ordinary(io, type, payload, ending, name)
          next
        end
        index = type.unpack1('N')
        if index.zero? || index > keys.length
          issue(:invalid_index, name + '/ilst', 'mdta index outside keys table', key_index: index)
          next
        end
        data = boxes(io, payload, ending)
        if data.empty? || data.any? { |r| r[0] != 'data' || r[2] - r[1] < 8 || r[3] != 8 }
          issue(:invalid_mdta_value, name + '/ilst', 'unsupported mdta data children', key_index: index)
        end
      end
    end

    def inspect_ordinary(io, type, start, finish, path)
      parts = boxes(io, start, finish)
      key = ordinary_key(io, type, parts)
      issue(:duplicate_item, path + '/ilst', 'duplicate ordinary atom cannot be captured completely', key: key) if @ordinary_keys[key]
      @ordinary_keys[key] = true
      allowed = type == '----' ? %w[data mean name] : %w[data]
      values = parts.select { |entry| entry[0] == 'data' }
      if values.empty? || parts.any? { |entry| !allowed.include?(entry[0]) || entry[3] != 8 }
        issue(:unsupported_item_structure, path + '/ilst', 'unsupported ordinary item children', key: key)
      end
      if @item_types[key]&.between?(1, 6) && values.length != 1
        issue(:unsupported_item_structure, path + '/ilst', 'scalar item has multiple values', key: key)
      end
      data_types = values.map do |row|
        raise 'truncated ordinary data' if row[2] - row[1] < 8
        io.seek(row[1])
        data_type, locale = io.read(8).unpack('N2')
        issue(:unsupported_item_locale, path + '/ilst', 'native ordinary items cannot preserve locale', key: key) unless locale.zero?
        data_type
      end
      if type != 'covr' && data_types.uniq.length > 1
        issue(:unsupported_item_structure, path + '/ilst', 'ordinary item has differing data types', key: key)
      end
      unless @item_types.key?(key)
        issue(:unrepresented_item, path + '/ilst', 'ordinary atom has no complete native Item', key: key)
        return
      end
      return unless @item_types[key] == 7

      values.each do |row|
        raise 'truncated ordinary data' if row[2] - row[1] < 8
        io.seek(row[1] + 8)
        text = io.read(row[2] - row[1] - 8).force_encoding(Encoding::UTF_8)
        unless text.valid_encoding? && !text.include?("\0")
          issue(:unsupported_text, path + '/ilst', 'native text parser cannot preserve these bytes', key: key)
        end
      end
    end

    # Decode the iTunes/freeform identity used by native ItemMap without losing name bytes.
    def ordinary_key(io, type, parts)
      key = type.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
      if type == '----'
        headers = %w[mean name].map do |name|
          raise 'duplicate freeform header' unless parts.count { |entry| entry[0] == name } == 1
          row = parts.find { |entry| entry[0] == name }
          raise 'invalid freeform header' unless row && row[2] - row[1] >= 4
          io.seek(row[1] + 4)
          value = io.read(row[2] - row[1] - 4).force_encoding(Encoding::UTF_8)
          raise 'unsupported freeform name' unless value.valid_encoding? && !value.include?("\0")
          value
        end
        key = '----:' + headers.join(':')
      end
      key
    end

    def read_keys(io, row, path)
      io.seek(row[1])
      data = io.read(row[2] - row[1])
      raise 'truncated keys FullBox' if data.bytesize < 8
      flags, count = data.unpack('N2')
      raise 'unsupported keys FullBox' unless flags.zero?
      raise 'keys count exceeds metadata length' if count > (data.bytesize - 8) / 8
      offset = 8
      keys = Array.new(count) do
        size = data.byteslice(offset, 4)&.unpack1('N')
        raise 'invalid keys entry' unless size && size >= 8 && offset + size <= data.bytesize
        namespace = data.byteslice(offset + 4, 4)
        key = data.byteslice(offset + 8, size - 8).force_encoding(Encoding::UTF_8)
        raise 'invalid mdta key' unless namespace == 'mdta' && !key.empty? && key.valid_encoding? && !key.include?("\0")
        offset += size
        key
      end
      raise 'trailing keys bytes' unless offset == data.bytesize
      issue(:duplicate_key, path + '/keys', 'duplicate mdta key') unless keys.uniq == keys
      keys
    end
  end

  class Tag
    # Report backend support separately from per-file structural editability.
    def metadata_capabilities
      available = respond_to?(:_metadata_keys) && !_metadata_keys.nil?
      MetadataSnapshot.copy(snapshot_v1: available, atomic_restore_v1: available, diagnostics: true,
                            reason: available ? nil : :native_snapshot_api_unavailable)
    end

    # Inspection refuses unsupported layouts rather than silently dropping values.
    def metadata_diagnostics
      native = respond_to?(:_metadata_status) ? _metadata_status : :unknown
      entries = item_map.to_a
      info = if @metadata_source_path
               MetadataStructureReader.read(@metadata_source_path, item_types: @metadata_disk_item_types || entries.to_h { |key, item| [key, item.type] })
             else
               { issues: [{ code: :unbound_tag, severity: :error, path: 'metadata', message: 'File-owned Tag required' }], structure: {} }
             end
      issues = info[:issues].dup
      if @metadata_file_valid == false
        issues << { code: :invalid_file, severity: :error, path: 'metadata', message: 'native File is invalid' }
      end
      if native == :unknown || native == :unsupported
        issues << { code: :unsupported_native_structure, severity: :error, path: 'metadata', message: "native status: #{native}" }
      end
      entries.each do |key, item|
        next if item.type.between?(1, 9) && respond_to?(:_metadata_item_supported) && _metadata_item_supported(key, item)
        issues << { code: :unsupported_item, severity: :error, path: 'metadata/ilst', key: key,
                    message: 'item type/encoding cannot round-trip through native writer' }
      end
      structure = info[:structure]
      if native == :editable && structure[:contexts]&.length == 1
        structure = { contexts: [structure[:contexts].first.merge(keys: _metadata_keys)] }
      end
      MetadataDiagnostics.new(status: native, issues: issues, structure: structure, capabilities: metadata_capabilities)
    end

    # Return a deeply immutable snapshot with no native owners; source File may then close.
    def metadata_snapshot
      report = require_snapshot_support!(:snapshot_v1, :unsupported_capture, :capture,
                                         'cannot capture complete metadata')
      items = item_map.to_a.map { |key, item| [key, *snapshot_item_value(item)] }
      visible = mdta_items.group_by(&:key)
      groups = _metadata_keys.each_with_index.map do |key, index|
        [key, index + 1, (visible[key] || []).map { |v| [v.data_type, v.locale, v.data] }]
      end
      MetadataSnapshot.new(items: items, mdta: groups, source_structure: report.structure)
    end

    # Replace all managed values as one native commit. File#save performs disk commit separately.
    def restore_metadata_snapshot(snapshot)
      unless snapshot.is_a?(MetadataSnapshot)
        raise MetadataSnapshotError.new('expected MetadataSnapshot', code: :invalid_snapshot, phase: :restore)
      end
      # Revalidate the complete value even if a caller allocated a forged instance.
      checked = MetadataSnapshot.new(items: snapshot.items, mdta: snapshot.mdta,
                                     source_structure: snapshot.source_structure, format_version: snapshot.format_version)
      require_snapshot_support!(:atomic_restore_v1, :unsupported_restore, :restore,
                                'destination cannot restore metadata')
      candidate = snapshot_item_map(checked.items)
      begin
        applied = _restore_metadata(candidate, checked.mdta)
      rescue RuntimeError => error
        raise MetadataSnapshotError.new(error.message, code: :native_candidate_failed, phase: :restore)
      end
      unless applied
        raise MetadataSnapshotError.new('native rejected metadata candidate', code: :unsupported_restore, phase: :restore)
      end
      self
    end

    private

    # Capture and restoration share the same structural/capability preflight and error contract.
    def require_snapshot_support!(capability, code, phase, message)
      report = metadata_diagnostics
      unless report.capabilities[capability] && report.restorable?
        raise MetadataSnapshotError.new(message, code: code, phase: phase, issues: report.issues)
      end
      report
    end

    # Build and validate all ordinary items before the single native restoration commit.
    def snapshot_item_map(items)
      candidate = ItemMap.new
      items.each do |key, kind, type, payload|
        item = snapshot_native_item(kind, type, payload)
        unless _metadata_item_supported(key, item)
          raise MetadataSnapshotError.new("unsupported item: #{key}", code: :unsupported_item, phase: :restore)
        end
        candidate.insert(key, item)
      end
      candidate
    end

    def snapshot_item_value(item)
      kind = MetadataSnapshot::KINDS[item.type - 1] if item.type.between?(1, 9)
      raise MetadataSnapshotError.new('unsupported item type', code: :unsupported_item, phase: :capture) unless kind
      payload = case kind
                when :string_list then item._snapshot_strings
                when :cover_art_list then item.to_cover_art_list.map { |art| [art.format, art.data] }
                else item.public_send("to_#{kind}")
                end
      [kind, item.atom_data_type, payload]
    end

    def snapshot_native_item(kind, type, payload)
      item = if kind == :string_list
               Item.from_string_list([]).tap { |v| v._set_snapshot_strings(payload) }
             elsif kind == :cover_art_list
               Item.from_cover_art_list(payload.map { |format, bytes| CoverArt.new(format, bytes) })
             else
               Item.public_send("from_#{kind}", payload)
             end
      item.set_atom_data_type(type)
      item
    end
  end

  class File
    alias tag_without_metadata_context tag
    private :tag_without_metadata_context

    # Bind read-only diagnostics to the File path without retaining the native File in a snapshot.
    def tag
      value = tag_without_metadata_context
      if value
        value.instance_variable_set(:@metadata_source_path, name.dup.freeze)
        value.instance_variable_set(:@metadata_file_valid, valid?)
        unless value.instance_variable_defined?(:@metadata_disk_item_types)
          value.instance_variable_set(:@metadata_disk_item_types,
                                      value.item_map.to_a.to_h { |key, item| [key, item.type] }.freeze)
        end
      end
      value
    end
  end
end
