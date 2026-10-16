# frozen_string_literal: true

module TagLib
  module Plus
    module MP4
      # MP4の物理構造を読み取り専用で集計する。保存・修復用のparserとは分離する。
      class StructureDiagnostics
        CONTAINERS = %w[moov trak mdia minf stbl tref udta edts dinf].freeze
        MAX_ATOMS = 50_000
        MAX_DEPTH = 16
        MAX_TABLE_BYTES = 64 * 1024 * 1024
        MAX_TABLE_ENTRIES = 4_000_000
        UNSUPPORTED = %w[moof mvex mfra cmov rmra uuid saio saiz senc iloc].freeze

        def initialize(path, generation)
          @path = path
          @generation = generation
          @issues = []
          @coverage = []
          @table_bytes = 0
          @table_entries = 0
          @atom_count = 0
          @sample_size_cache = {}
          @chunk_mapping_cache = {}
        end

        def report
          @generation.check!
          ::File.open(@path, 'rb') do |io|
            @io = io
            @file_size = io.stat.size
            atoms = parse_atoms(0, @file_size, nil, 0)
            walk(atoms) do |atom|
              next unless UNSUPPORTED.include?(atom[:type])

              add_issue(:unsupported_structure, "unsupported #{atom[:type]} structure", atom[:offset],
                        atom_type: atom[:type])
            end
            mdat_ranges = atoms.select { |atom| atom[:type] == 'mdat' }
                             .map { |atom| { start: atom[:payload_offset], end: atom[:end_offset] } }
            moov = atoms.find { |atom| atom[:type] == 'moov' }
            add_issue(:required_atom_missing, 'missing moov atom', 'root') unless moov
            add_issue(:required_atom_missing, 'missing mdat atom', 'root') if mdat_ranges.empty?
            tracks = moov ? diagnose_tracks(moov, mdat_ranges) : []
            @coverage << { check: :atom_boundaries, status: :complete } if @issues.none? { |i| i[:code].to_s.start_with?('atom_') }
            @coverage << { check: :chunk_offsets, status: :complete } if @coverage.none? { |c| c[:check] == :chunk_offsets }
            data = {
              file_size: @file_size,
              mdat_ranges: mdat_ranges,
              tracks: tracks,
              coverage: @coverage
            }
            status = if @issues.empty?
                       :complete
                     elsif @issues.any? { |issue| issue[:code] == :diagnostic_limit }
                       :limit
                     elsif @issues.all? { |issue| issue[:code] == :unsupported_structure }
                       :unsupported
                     else
                       :malformed
                     end
            result = { status: status, data: data, issues: @issues }
            @generation.check!
            DeepCopy.call(result)
          ensure
            @io = nil
          end
        end

        private

        def parse_atoms(start_offset, end_offset, parent, depth)
          return [] if start_offset >= end_offset
          if depth > MAX_DEPTH
            add_issue(:atom_depth_exceeded, 'MP4 atom depth exceeds limit', start_offset,
                      parent: parent, depth: depth)
            return []
          end

          atoms = []
          offset = start_offset
          while offset < end_offset
            if @atom_count >= MAX_ATOMS
              add_issue(:diagnostic_limit, 'MP4 atom count exceeds limit', offset,
                        limit: MAX_ATOMS, observed: @atom_count)
              break
            end
            @atom_count += 1
            remaining = end_offset - offset
            if remaining < 8
              add_issue(:atom_header_truncated, 'truncated MP4 atom header', offset,
                        expected: 8, observed: remaining, parent: parent)
              break
            end
            header = read_bytes(offset, 8)
            size32 = header.unpack1('N')
            type = header.byteslice(4, 4)
            header_size = 8
            size = size32
            if size32 == 1
              if end_offset - offset < 16
                add_issue(:atom_header_truncated, 'truncated extended MP4 atom header', offset,
                          expected: 16, observed: end_offset - offset, parent: parent)
                break
              end
              size = read_bytes(offset + 8, 8).unpack1('Q>')
              header_size = 16
            elsif size32.zero?
              size = end_offset - offset
            end
            if size < header_size
              add_issue(:atom_size_invalid, 'MP4 atom size is smaller than its header', offset,
                        type: type, declared_size: size, header_size: header_size, parent: parent)
              break
            end
            if size > end_offset - offset
              add_issue(:atom_outside_parent, 'MP4 atom exceeds its parent boundary', offset,
                        type: type, declared_size: size, available: end_offset - offset, parent: parent)
              break
            end

            atom = { type: type, offset: offset, payload_offset: offset + header_size,
                     end_offset: offset + size, children: [] }
            if CONTAINERS.include?(type)
              child_start = atom[:payload_offset]
              child_start += 4 if type == 'meta'
              if child_start <= atom[:end_offset]
                atom[:children] = parse_atoms(child_start, atom[:end_offset], type, depth + 1)
              end
            end
            atoms << atom
            offset += size
          end
          atoms
        end

        def walk(atoms, &block)
          atoms.each do |atom|
            block.call(atom)
            walk(atom[:children], &block) unless atom[:children].empty?
          end
        end

        def diagnose_tracks(moov, mdat_ranges)
          tracks = moov[:children].select { |atom| atom[:type] == 'trak' }
          rows = tracks.each_with_index.map do |track, track_index|
            track_id = read_track_id(track)
            handler = read_handler(track)
            tables = diagnose_tables(track, mdat_ranges, track_id, handler, track_index)
            { track_id: track_id, handler: handler, track_index: track_index, tables: tables }
          end
          rows.group_by { |row| row[:track_id] }.each do |track_id, duplicate_rows|
            next if track_id.nil? || duplicate_rows.size < 2

            add_issue(:duplicate_track_id, 'duplicate track ID', 'moov',
                      track_id: track_id, track_indexes: duplicate_rows.map { |row| row[:track_index] })
          end
          rows
        end

        def diagnose_tables(track, mdat_ranges, track_id, handler, track_index)
          stbl = descendant(track, %w[mdia minf stbl])
          unless stbl
            add_issue(:required_atom_missing, 'missing stbl atom', track[:offset],
                      track_id: track_id, handler: handler, track_index: track_index)
            return []
          end
          tables = stbl[:children].select { |atom| %w[stco co64].include?(atom[:type]) }
          if tables.empty?
            add_issue(:required_atom_missing, 'missing chunk offset table', stbl[:offset],
                      track_id: track_id, handler: handler, track_index: track_index)
            return []
          end
          if tables.size > 1
            add_issue(:ambiguous_chunk_offset_tables, 'multiple chunk offset tables', stbl[:offset],
                      track_id: track_id, handler: handler, track_index: track_index,
                      tables: tables.map { |table| table[:type] })
          end
          tables.map { |table| diagnose_table(table, stbl, mdat_ranges, track_id, handler, track_index) }
        end

        def diagnose_table(table, stbl, mdat_ranges, track_id, handler, track_index)
          base = nil
          width = table[:type] == 'stco' ? 4 : 8
          table_size = table[:end_offset] - table[:payload_offset]
          if table_size > MAX_TABLE_BYTES
            add_issue(:diagnostic_limit, 'chunk offset table exceeds diagnostic limit', table[:offset],
                      track_id: track_id, handler: handler, track_index: track_index,
                      table_type: table[:type], observed_bytes: table_size)
            return {
              type: table[:type], atom_offset: table[:offset], declared_count: nil,
              scanned_count: 0, invalid_count: 0, first_invalid: nil, last_invalid: nil,
              extent_invalid_count: 0, first_invalid_extent: nil, last_invalid_extent: nil,
              max_offset: nil, max_referenced_end: nil, complete: false
            }
          end
          bytes = payload(table)
          declared_count = bytes.bytesize >= 8 ? bytes.byteslice(4, 4).unpack1('N') : nil
          base = {
            type: table[:type], atom_offset: table[:offset], declared_count: declared_count,
            scanned_count: 0, invalid_count: 0, first_invalid: nil, last_invalid: nil,
            extent_invalid_count: 0, first_invalid_extent: nil, last_invalid_extent: nil,
            max_offset: nil, max_referenced_end: nil, complete: false
          }
          unless bytes.bytesize >= 8 && bytes.byteslice(0, 4) == "\0".b * 4
            add_issue(:table_header_invalid, 'invalid chunk offset table header', table[:offset],
                      track_id: track_id, handler: handler, track_index: track_index, table_type: table[:type])
            return base
          end
          expected = 8 + declared_count * width
          if bytes.bytesize != expected
            add_issue(:table_count_mismatch, 'chunk offset count does not match table size', table[:offset],
                      track_id: track_id, handler: handler, track_index: track_index,
                      table_type: table[:type], declared_count: declared_count,
                      expected_bytes: expected, observed_bytes: bytes.bytesize)
          end
          if declared_count > MAX_TABLE_ENTRIES || expected > MAX_TABLE_BYTES
            add_issue(:diagnostic_limit, 'chunk offset table exceeds diagnostic limit', table[:offset],
                      track_id: track_id, handler: handler, track_index: track_index,
                      table_type: table[:type], declared_count: declared_count)
            return base
          end
          available = [declared_count, [0, (bytes.bytesize - 8) / width].max].min
          offsets = bytes.byteslice(8, available * width).unpack(width == 4 ? 'N*' : 'Q>*')
          sizes = sample_sizes(stbl)
          mapping = chunk_mapping(stbl)
          sample_index = 0
          max_end = nil
          offsets.each_with_index do |offset, index|
            base[:scanned_count] += 1
            base[:max_offset] = offset if base[:max_offset].nil? || offset > base[:max_offset]
            range = mdat_ranges.find { |row| offset >= row[:start] && offset < row[:end] }
            unless range
              base[:invalid_count] += 1
              entry = { index: index, offset: offset }
              base[:first_invalid] ||= entry
              base[:last_invalid] = entry
            end
            count = samples_per_chunk(mapping, index + 1)
            if count && sizes
              extent = sizes[sample_index, count]
              if extent && extent.length == count
                end_offset = offset + extent.sum
                max_end = end_offset if max_end.nil? || end_offset > max_end
                if range.nil? || end_offset > range[:end]
                  base[:extent_invalid_count] += 1
                  entry = { index: index, offset: offset, end: end_offset }
                  base[:first_invalid_extent] ||= entry
                  base[:last_invalid_extent] = entry
                end
                sample_index += count
              end
            end
          end
          base[:max_referenced_end] = max_end
          base[:complete] = base[:scanned_count] == declared_count
          if base[:invalid_count].positive?
            add_issue(:chunk_offset_outside_mdat, 'chunk offset outside mdat', "track/#{track_index}/#{table[:type]}",
                      tracks: [{
                        track_id: track_id,
                        handler: handler,
                        tables: [{
                          type: table[:type],
                          declared_count: declared_count,
                          invalid_count: base[:invalid_count],
                          first_invalid: base[:first_invalid],
                          last_invalid: base[:last_invalid],
                          max_offset: base[:max_offset],
                          max_referenced_end: base[:max_referenced_end]
                        }]
                      }],
                      file_size: @file_size, mdat_ranges: mdat_ranges)
          end
          if base[:extent_invalid_count].positive?
            add_issue(:chunk_extent_outside_mdat, 'chunk sample extent outside mdat', "track/#{track_index}/#{table[:type]}",
                      tracks: [{
                        track_id: track_id,
                        handler: handler,
                        tables: [{
                          type: table[:type],
                          declared_count: declared_count,
                          invalid_count: base[:extent_invalid_count],
                          first_invalid: base[:first_invalid_extent],
                          last_invalid: base[:last_invalid_extent],
                          max_offset: base[:max_offset],
                          max_referenced_end: base[:max_referenced_end]
                        }]
                      }],
                      file_size: @file_size, mdat_ranges: mdat_ranges)
          end
          base
        rescue StandardError => error
          add_issue(:table_parse_error, error.message, table[:offset],
                    track_id: track_id, handler: handler, track_index: track_index,
                    table_type: table[:type])
          base || {
            type: table[:type], atom_offset: table[:offset], declared_count: nil,
            scanned_count: 0, invalid_count: 0, first_invalid: nil, last_invalid: nil,
            extent_invalid_count: 0, first_invalid_extent: nil, last_invalid_extent: nil,
            max_offset: nil, max_referenced_end: nil, complete: false
          }
        end

        def sample_sizes(stbl)
          atom = stbl[:children].find { |child| child[:type] == 'stsz' }
          return nil unless atom
          return @sample_size_cache[atom[:offset]] if @sample_size_cache.key?(atom[:offset])
          return nil if atom[:end_offset] - atom[:payload_offset] > MAX_TABLE_BYTES
          data = payload(atom)
          unless data.bytesize >= 12 && data.byteslice(0, 4) == "\0".b * 4
            return @sample_size_cache[atom[:offset]] = nil
          end
          fixed, count = data.byteslice(4, 8).unpack('N2')
          return @sample_size_cache[atom[:offset]] = nil if count > MAX_TABLE_ENTRIES
          return @sample_size_cache[atom[:offset]] = Array.new(count, fixed) unless fixed.zero?
          return @sample_size_cache[atom[:offset]] = nil unless data.bytesize == 12 + count * 4
          @sample_size_cache[atom[:offset]] = data.byteslice(12, count * 4).unpack('N*')
        end

        def chunk_mapping(stbl)
          atom = stbl[:children].find { |child| child[:type] == 'stsc' }
          return nil unless atom
          return @chunk_mapping_cache[atom[:offset]] if @chunk_mapping_cache.key?(atom[:offset])
          return nil if atom[:end_offset] - atom[:payload_offset] > MAX_TABLE_BYTES
          data = payload(atom)
          unless data.bytesize >= 8 && data.byteslice(0, 4) == "\0".b * 4
            return @chunk_mapping_cache[atom[:offset]] = nil
          end
          count = data.byteslice(4, 4).unpack1('N')
          return @chunk_mapping_cache[atom[:offset]] = nil if count > MAX_TABLE_ENTRIES || data.bytesize != 8 + count * 12
          @chunk_mapping_cache[atom[:offset]] = data.byteslice(8, count * 12).unpack('N*').each_slice(3).to_a
        end

        def samples_per_chunk(mapping, chunk_number)
          return nil unless mapping && !mapping.empty?
          row = mapping.reverse.find { |entry| entry[0] <= chunk_number }
          row && row[1]
        end

        def read_track_id(track)
          atom = track[:children].find { |child| child[:type] == 'tkhd' }
          return nil unless atom
          data = payload(atom)
          version = data.getbyte(0)
          offset = version == 1 ? 20 : 12
          data.bytesize >= offset + 4 ? data.byteslice(offset, 4).unpack1('N') : nil
        end

        def read_handler(track)
          atom = descendant(track, %w[mdia hdlr])
          return nil unless atom
          data = payload(atom)
          data.bytesize >= 12 ? data.byteslice(8, 4) : nil
        end

        def descendant(atom, path)
          path.reduce(atom) { |current, type| current && current[:children].find { |child| child[:type] == type } }
        end

        def payload(atom)
          read_bytes(atom[:payload_offset], atom[:end_offset] - atom[:payload_offset])
        end

        def read_bytes(offset, length)
          @io.seek(offset)
          value = @io.read(length)
          raise IOError, 'truncated MP4 data' unless value && value.bytesize == length

          value
        end

        def add_issue(code, message, location, details = {})
          @issues << { code: code, message: message, location: location, details: details }
        end
      end
    end
  end
end
