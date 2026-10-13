# frozen_string_literal: true

module TagLib::MP4
  # 色構造の読取不能を理由付きで通知する。復元値の推定は行わない。
  class ColorMetadataError < StandardError
    attr_reader :code

    def initialize(message, code: :malformed)
      @code = code
      super(message)
    end
  end

  # stsdとvisual sample entryの固定ヘッダを越えたcolrだけを境界内で読む。
  class ColorMetadataReader
    VISUAL_TYPES = %w[avc1 avc2 avc3 avc4 hvc1 hev1 mp4v encv jpeg mjpa mjpb apch apcn apcs apco ap4h ap4x vp08 vp09 av01].freeze
    MAX_READ_BYTES = 32 * 1024 * 1024
    MAX_COLR_BYTES = 1024 * 1024

    def initialize(file)
      @file = file
      @budget = [50_000]
      @read_budget = [MAX_READ_BYTES]
    end

    # 共通atom parserでmediaをskipし、複数track/entry/colrの位置を独立して返す。
    def read
      ::File.open(@file.name, 'rb') do |io|
        @io = io
        roots = atoms(0, io.stat.size)
        moovs = roots.select { |atom| atom[:type] == 'moov' }
        fail!('single moov required') unless moovs.size == 1
        entries = moovs.first[:children].select { |atom| atom[:type] == 'trak' }.each_with_index.flat_map do |track, track_index|
          read_track(track, track_index)
        end
        MetadataSnapshot.copy(status: :complete, entries: entries)
      end
    rescue MdtaSaveError, IOError, SystemCallError => error
      raise ColorMetadataError.new(error.message, code: error.message.include?('exceeds limit') ? :limit : :malformed), cause: error
    ensure
      @io = nil
    end

    private

    def fail!(message, code = :malformed)
      raise ColorMetadataError.new(message, code: code)
    end

    def atoms(start, finish)
      @file.send(:parse_mp4_atoms, @io, start, finish, 0, @budget, @read_budget)
    end

    def child(atom, type)
      rows = atom[:children].select { |row| row[:type] == type }
      fail!("single #{type} required at #{atom[:offset]}") unless rows.size == 1
      rows.first
    end

    def bytes(atom, relative, length)
      fail!("truncated #{atom[:type]} at #{atom[:offset]}") if relative + length > atom[:end_offset] - atom[:payload_offset]
      consume(length)
      @file.send(:read_mp4_bytes, @io, atom[:payload_offset] + relative, length)
    end

    def consume(length)
      @read_budget[0] -= length
      fail!('color metadata read limit exceeded', :limit) if @read_budget[0].negative?
    end

    def read_track(track, track_index)
      tkhd = child(track, 'tkhd')
      version = bytes(tkhd, 0, 1).unpack1('C')
      fail!('unsupported tkhd version', :unsupported) unless [0, 1].include?(version)
      id = bytes(tkhd, version == 1 ? 20 : 12, 4).unpack1('N')
      mdia = child(track, 'mdia')
      handler = bytes(child(mdia, 'hdlr'), 8, 4)
      stsd = child(child(child(mdia, 'minf'), 'stbl'), 'stsd')
      flags, count = bytes(stsd, 0, 8).unpack('N2')
      fail!('unsupported stsd version/flags', :unsupported) unless flags.zero?
      descriptions = atoms(stsd[:payload_offset] + 8, stsd[:end_offset])
      fail!('stsd entry count mismatch') unless descriptions.size == count
      descriptions.each_with_index.map do |entry, index|
        base = { track_id: id, track_index: track_index, handler: handler, stsd_offset: stsd[:offset],
                 sample_entry_index: index, sample_entry_number: index + 1, sample_entry_type: entry[:type],
                 sample_entry_offset: entry[:offset], sample_entry_end: entry[:end_offset] }
        unless handler == 'vide' && VISUAL_TYPES.include?(entry[:type])
          next base.merge(status: :unsupported, unsupported_reason: :unsupported_sample_entry_layout, colr: [])
        end
        bytes(entry, 0, 78)
        children = atoms(entry[:payload_offset] + 78, entry[:end_offset])
        colors = children.select { |atom| atom[:type] == 'colr' }.each_with_index.map { |atom, number| read_colr(atom, entry, number) }
        base.merge(status: :complete, unsupported_reason: nil, colr: colors)
      end
    end

    # 部分フィールドを独立して観測する。短いnclxのrangeはnilのまま返す。
    def read_colr(atom, parent, index)
      length = atom[:end_offset] - atom[:payload_offset]
      fail!('colr payload exceeds limit', :limit) if length > MAX_COLR_BYTES
      data = bytes(atom, 0, length)
      header_size = atom[:payload_offset] - atom[:offset]
      consume(header_size)
      header = @file.send(:read_mp4_bytes, @io, atom[:offset], header_size)
      declared = header.unpack1('N')
      declared = header.byteslice(8, 8).unpack1('Q>') if declared == 1
      type = data.bytesize >= 4 ? data.byteslice(0, 4) : nil
      supported = %w[nclx nclc].include?(type)
      expected = type == 'nclx' ? 11 : 10
      issues = []
      issues << :truncated_color_type if type.nil?
      issues << :short_color_payload if supported && length < expected
      issues << :trailing_color_bytes if supported && length > expected
      range_present = type == 'nclx' && length >= 11
      range = range_present ? data.getbyte(10) : nil
      issues << :nonzero_reserved_range_bits if range && (range & 0x7f) != 0
      { colr_index: index, atom_type: 'colr', offset: atom[:offset], end_offset: atom[:end_offset],
        header_size: header_size, declared_size: declared, payload_length: length,
        parent_offset: parent[:offset], parent_payload_offset: parent[:payload_offset], parent_end: parent[:end_offset],
        color_type: type, color_primaries: supported && length >= 6 ? data.byteslice(4, 2).unpack1('n') : nil,
        transfer_characteristics: supported && length >= 8 ? data.byteslice(6, 2).unpack1('n') : nil,
        matrix_coefficients: supported && length >= 10 ? data.byteslice(8, 2).unpack1('n') : nil,
        range_field_present: range_present, range_byte: range, full_range: range.nil? ? nil : (range & 0x80) != 0,
        raw_digest: Digest::SHA256.hexdigest(header + data), issues: issues,
        status: type.nil? ? :malformed : (supported ? (issues.empty? ? :complete : :malformed) : :unsupported),
        unsupported_reason: supported ? nil : :unsupported_color_type }
    end
  end
  private_constant :ColorMetadataReader

  class File
    # 保存済み原本の色構造を読み取り専用で診断する。未保存編集やcodec観測値は使わない。
    def color_metadata_diagnostics
      ColorMetadataReader.new(self).read
    end
  end
end
