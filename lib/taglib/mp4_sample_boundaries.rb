# frozen_string_literal: true

module TagLib
  module Plus
    module MP4
      # HeaderReaderの境界indexとheader解釈を共有し、sample本文には触れない。
      class SampleBoundaryReader < HeaderReader
        MAX_TIME = (1 << 63) - 1
        UNSUPPORTED_BOXES = %w[moof mvex mfra cmov rmra uuid saio saiz senc sinf sgpd sbgp
                               subs sdtp stsh padb stdp cslg].freeze

        def initialize(path, generation, max_bytes, max_entries)
          super(path, generation)
          @max_bytes, @max_entries = max_bytes, max_entries
          @table_bytes = @entries = @bytes_read = @read_calls = 0
          @digest = Digest::SHA256.new
          @coverage, @issues, @data = [], [], {}
        end

        def report(track_id)
          @io_generation.check!
          begin
            with_io { inspect_track(track_id) }
            status = @issues.empty? ? :complete : :unsupported
          rescue Stop => error
            status = error.status
            @issues << { code: error.code, message: error.message }
          rescue ::TagLib::MP4::MdtaSaveError => error
            code = { 'MP4 atom count exceeds limit' => :atom_count,
                     'MP4 atom depth exceeds limit' => :atom_depth }[error.message]
            raise unless code
            status = :limit
            @issues << { code: code, message: error.message }
          ensure
            @io_generation.check!
          end
          DeepCopy.call(status: status, data: @data, issues: @issues, coverage: @coverage,
                        counts: { table_bytes: @table_bytes, table_entries: @entries,
                                  bytes_read: @bytes_read, read_calls: @read_calls },
                        tables_digest: @digest.hexdigest)
        end

        private

        class Stop < StandardError
          attr_reader :status, :code
          def initialize(status, code, message)
            @status, @code = status, code
            super(message)
          end
        end

        def stop!(status, code, message)
          raise Stop.new(status, code, message)
        end

        def fail!(message, code = :malformed)
          if %i[unsupported limit].include?(code)
            stop!(code, code, message)
          end
          raise Error.new(message, code: code, area: :sample_boundaries, phase: :read)
        end

        # 共通parserのheader読取も含む、実際に要求したread量。
        def read_mp4_bytes(io, offset, count)
          @bytes_read += count
          @read_calls += 1
          super
        end

        # headerは小範囲のみ。table本文は別の合計予算で取得する。
        def bytes(atom, offset, count)
          fail!("truncated #{atom[:type]}") if offset.negative? || count.negative? || offset + count > length(atom)
          fail!('header read exceeds limit', :limit) if count > LIMIT
          read_mp4_bytes(@io, atom[:payload_offset] + offset, count)
        end

        def one(rows, type, required: true)
          found = rows.select { |a| a[:type] == type }
          fail!("duplicate #{type}") if found.size > 1
          fail!("missing #{type}") if required && found.empty?
          found.first
        end

        def timing(atom)
          result = super
          minimum = atom[:type] == 'mvhd' ? (result[:version] == 1 ? 112 : 100) : (result[:version] == 1 ? 36 : 24)
          fail!("truncated #{atom[:type]} header") if length(atom) < minimum
          result
        end

        def table(atom, entries, prefix)
          size = length(atom)
          remaining = size - prefix.bytesize
          if @table_bytes + remaining > @max_bytes
            stop!(:limit, :max_table_bytes, "#{atom[:type]} exceeds aggregate table byte budget")
          end
          if @entries + entries > @max_entries
            stop!(:limit, :max_table_entries, "#{atom[:type]} exceeds aggregate table entry budget")
          end
          @entries += entries
          @table_bytes += remaining
          raw = prefix + (remaining.zero? ? ''.b : read_mp4_bytes(@io, atom[:payload_offset] + prefix.bytesize, remaining))
          @digest.update([atom[:offset]].pack('Q>')).update(atom[:type]).update(raw)
          raw
        end

        def box_header(atom, size, versions = [0])
          if @table_bytes + length(atom) > @max_bytes
            stop!(:limit, :max_table_bytes, "#{atom[:type]} exceeds aggregate table byte budget")
          end
          head = bytes(atom, 0, size)
          @table_bytes += size
          fail!("nonzero #{atom[:type]} flags") unless head.byteslice(1, 3) == "\0" * 3
          fail!("unsupported #{atom[:type]} version", :unsupported) unless versions.include?(head.getbyte(0))
          head
        end

        def rows(atom, width, versions = [0])
          head = box_header(atom, 8, versions)
          count = head.byteslice(4, 4).unpack1('N')
          fail!("#{atom[:type]} count/length mismatch") unless length(atom) == 8 + count * width
          [table(atom, count, head), count]
        end

        def descend(atom, *types)
          types.reduce(atom) { |parent, type| child(parent, type) }
        end

        def walk(rows, &block)
          rows.each { |a| block.call(a); walk(a[:children], &block) }
        end

        def inspect_track(id)
          root = atoms
          @file_size = @io.stat.size
          @coverage << { check: :atom_boundaries, status: :complete }
          moov = one(root, 'moov')
          [[root, %w[ftyp moov mdat free skip wide]],
           [moov[:children], %w[mvhd trak udta meta iods free skip mvex]]].each do |children, allowed|
            children.each do |a|
              unless allowed.include?(a[:type])
                @issues << { code: :container_extension, message: "unsupported container structure #{a[:type]}" }
              end
            end
          end
          tracks = moov[:children].select { |a| a[:type] == 'trak' }
          ids = tracks.map do |track|
            tkhd = child(track, 'tkhd')
            v = bytes(tkhd, 0, 1).getbyte(0)
            fail!('unsupported tkhd version', :unsupported) unless [0, 1].include?(v)
            fail!('truncated tkhd header') if length(tkhd) < (v == 1 ? 96 : 84)
            bytes(tkhd, v == 1 ? 20 : 12, 4).unpack1('N')
          end
          fail!('zero or duplicate track ID') if ids.include?(0) || ids.uniq.size != ids.size
          track = tracks[ids.index(id)] if ids.include?(id)
          raise ArgumentError, "track ID #{id} not found" unless track
          @data[:track_id] = id
          # Fragmentには通常tableがないため、境界index以外のcoverageを付けない。
          if root.any? { |a| %w[moof mfra].include?(a[:type]) } || moov[:children].any? { |a| a[:type] == 'mvex' }
            stop!(:unsupported, :fragmented, 'fragmented MP4 sample tables are not supported')
          end
          walk(root.reject { |a| a[:type] == 'moov' } + moov[:children].reject { |a| a[:type] == 'trak' } + [track]) do |a|
            if UNSUPPORTED_BOXES.include?(a[:type])
              @issues << { code: :unsupported_structure, message: "unsupported #{a[:type]}", atom_offset: a[:offset] }
            end
          end
          media = timing(descend(track, 'mdia', 'mdhd'))
          movie = timing(child(moov, 'mvhd'))
          @data.merge!(media_timescale: media[:timescale], media_duration: media[:duration_ticks],
                       movie_timescale: movie[:timescale], time_axis: :raw_media)
          hdlr = descend(track, 'mdia', 'hdlr')
          fail!('truncated hdlr header') if length(hdlr) < 24
          handler_header = bytes(hdlr, 0, 12)
          fail!('unsupported hdlr version', :unsupported) unless handler_header.getbyte(0).zero?
          fail!('nonzero hdlr flags') unless handler_header.byteslice(1, 3) == "\0" * 3
          handler = handler_header.byteslice(8, 4)
          @data[:handler] = handler
          stbl = descend(track, 'mdia', 'minf', 'stbl')
          [[track, %w[tkhd mdia edts udta tref free skip]],
           [child(track, 'mdia'), %w[mdhd hdlr minf elng free skip]],
           [descend(track, 'mdia', 'minf'), %w[smhd dinf stbl free skip]]].each do |parent, allowed|
            parent[:children].each do |a|
              unless allowed.include?(a[:type])
                @issues << { code: :track_extension, message: "unsupported track structure #{a[:type]}" }
              end
            end
          end
          stbl[:children].each do |a|
            unless (%w[stsd stts ctts stsc stsz stz2 stco co64 free skip] + UNSUPPORTED_BOXES).include?(a[:type])
              @issues << { code: :sample_table_extension, message: "unsupported sample table #{a[:type]}" }
            end
          end
          data_references(descend(track, 'mdia', 'minf', 'dinf', 'dref'))
          descriptions(child(stbl, 'stsd'), handler)
          edits(track)
          sizes, count, fixed, field = sizes(stbl)
          @data[:sample_count] = count
          stop!(:unsupported, :empty_track, 'track has no samples') if count.zero?
          timing_table(child(stbl, 'stts'), count)
          composition(child(stbl, 'ctts', required: false), count)
          chunks(stbl, root, sizes, count, fixed, field)
          @coverage.concat(%i[sample_counts decode_timing chunk_mapping sample_extents chunk_nonoverlap].map do |check|
            { check: check, status: :complete }
          end)
          @coverage << { check: :supported_structure, status: @issues.empty? ? :complete : :unsupported }
          @coverage << { check: :composition_timing, status: @data[:composition_offsets] == :nonzero ? :unsupported : :complete }
          @coverage << { check: :media_payload, status: :not_checked }
          @coverage << { check: :codec_configuration, status: :not_checked }
        end

        def data_references(atom)
          head = box_header(atom, 8)
          count = head.byteslice(4, 4).unpack1('N')
          raw = table(atom, count, head)
          @reference_count = count
          offset = 8
          count.times do
            fail!('truncated data reference') if offset + 12 > raw.bytesize
            size, type, flags = raw.byteslice(offset, 12).unpack('Na4N')
            fail!('invalid data reference extent') if size < 12 || offset + size > raw.bytesize
            unless count == 1 && type == 'url ' && flags == 1 && size == 12
              @issues << { code: :data_reference, message: 'only a single self-contained url data reference is supported' }
            end
            offset += size
          end
          fail!('dref count/length mismatch') if count.zero? || offset != raw.bytesize
          @coverage << { check: :data_references, status: @issues.any? { |i| i[:code] == :data_reference } ? :unsupported : :complete }
        end

        def descriptions(atom, handler)
          head = box_header(atom, 8)
          count = head.byteslice(4, 4).unpack1('N')
          raw = table(atom, count, head)
          # 予算内のraw entryから境界を検証し、本文を再readしない。
          offset, entries = 8, []
          count.times do
            fail!('truncated sample description') if offset + 16 > raw.bytesize
            size, fourcc = raw.byteslice(offset, 8).unpack('Na4')
            fail!('invalid sample description extent') if size < 16 || offset + size > raw.bytesize
            payload = raw.byteslice(offset + 8, size - 8)
            reference = payload.byteslice(6, 2).unpack1('n')
            fail!('sample description data reference outside dref') unless reference.between?(1, @reference_count)
            entry = { fourcc: fourcc, data_reference_index: reference, raw: raw.byteslice(offset, size) }
            if handler == 'soun' && fourcc == 'mp4a' && payload.bytesize >= 28
              version = payload.byteslice(8, 2).unpack1('n')
              entry.merge!(audio_version: version, channels: payload.byteslice(16, 2).unpack1('n'),
                           sample_rate_fixed: payload.byteslice(24, 4).unpack1('N'))
              @issues << { code: :audio_sample_entry_version, message: 'only audio sample entry version 0 is supported' } unless version.zero?
              # AAC設定はrawで提供。暗号化・未知拡張をcompleteにしない。
              p = 28
              while p < payload.bytesize
                fail!('truncated sample entry extension') if p + 8 > payload.bytesize
                n, type = payload.byteslice(p, 8).unpack('Na4')
                fail!('invalid sample entry extension') if n < 8 || p + n > payload.bytesize
                unless %w[esds btrt].include?(type)
                  @issues << { code: :sample_entry_extension, message: "unsupported sample entry extension #{type}" }
                end
                p += n
              end if version.zero?
            else
              @issues << { code: :sample_description, message: "unsupported #{handler}/#{fourcc} sample description" }
            end
            @issues << { code: :data_reference, message: 'external data reference is unsupported' } unless reference == 1
            entries << entry
            offset += size
          end
          fail!('stsd count/length mismatch') unless offset == raw.bytesize
          fail!('missing sample description') if count.zero?
          @issues << { code: :multiple_sample_descriptions, message: 'multiple sample descriptions are unsupported' } unless count == 1
          @description_count = count
          @data[:sample_descriptions] = entries
          # data_reference_index=1だけでは自己完結を証明できない。
          @coverage << { check: :sample_descriptions, status: @issues.empty? ? :complete : :unsupported }
        end

        def edits(track)
          edts = child(track, 'edts', required: false)
          if edts && edts[:children].any? { |a| !%w[elst free skip].include?(a[:type]) }
            @issues << { code: :edit_list, message: 'unknown edit structure' }
          end
          atom = edts && child(edts, 'elst', required: false)
          @data[:edits] = nil
          if atom
            head = box_header(atom, 8, [0, 1])
            v = head.getbyte(0)
            count = head.byteslice(4, 4).unpack1('N')
            fail!('elst count/length mismatch') unless length(atom) == 8 + count * (v == 1 ? 20 : 12)
            raw = table(atom, count, head)
            @data[:edits] = Array.new(count) do |i|
              values = raw.byteslice(8 + i * (v == 1 ? 20 : 12), v == 1 ? 20 : 12).unpack(v == 1 ? 'Q>q>s>s>' : 'Nl>s>s>')
              %i[segment_duration media_time rate_integer rate_fraction].zip(values).to_h
            end
            unless count == 1 && @data[:edits].all? { |e| e[:media_time] >= 0 && e[:rate_integer] == 1 && e[:rate_fraction].zero? }
              @issues << { code: :edit_list, message: 'only a single nonnegative rate-1 edit is supported' }
            end
          end
          @coverage << { check: :edit_mapping, status: @issues.any? { |i| i[:code] == :edit_list } ? :unsupported : :complete }
        end

        def sizes(stbl)
          atoms = stbl[:children].select { |a| %w[stsz stz2].include?(a[:type]) }
          fail!('expected exactly one size table') unless atoms.size == 1
          atom = atoms.first
          head = box_header(atom, 12)
          count = head.byteslice(8, 4).unpack1('N')
          fixed, field = atom[:type] == 'stsz' ? [head.byteslice(4, 4).unpack1('N'), 32] : [0, head.getbyte(7)]
          fail!('invalid stz2 reserved bits') if atom[:type] == 'stz2' && head.byteslice(4, 3) != "\0" * 3
          fail!('invalid stz2 field size') unless [4, 8, 16, 32].include?(field) && (atom[:type] == 'stsz' || field != 32)
          expected = fixed.positive? ? 12 : 12 + (count * field + 7) / 8
          fail!('size table count/length mismatch') unless length(atom) == expected
          [table(atom, fixed.positive? ? 1 : count, head), count, fixed, field]
        end

        def sample_size(raw, index, fixed, field)
          return fixed if fixed.positive?
          case field
          when 4 then (raw.getbyte(12 + index / 2) >> (index.even? ? 4 : 0)) & 15
          when 8 then raw.getbyte(12 + index)
          when 16 then raw.byteslice(12 + index * 2, 2).unpack1('n')
          when 32 then raw.byteslice(12 + index * 4, 4).unpack1('N')
          end
        end

        def checked_time(value)
          fail!('sample time overflow') unless value.between?(0, MAX_TIME)
          value
        end

        def timing_table(atom, count)
          raw, n = rows(atom, 8)
          @timing_raw = raw
          samples = total = 0
          first_duration = last_duration = nil
          n.times do |i|
            num, delta = raw.byteslice(8 + i * 8, 8).unpack('N2')
            fail!('zero stts count or duration') if num.zero? || delta.zero?
            first_duration ||= delta
            last_duration = delta
            samples += num
            total = checked_time(total + num * delta)
          end
          fail!('stts/sample count mismatch') unless samples == count
          if @data[:media_duration] && @data[:media_duration] != total
            fail!('mdhd duration/stts decode end mismatch')
          end
          @data.merge!(decode_end: total, first: { index: 0, dts: 0, pts: 0, duration: first_duration },
                       last: { index: count - 1, dts: total - last_duration, pts: total - last_duration, duration: last_duration })
        end

        def composition(atom, count)
          @data[:composition_offsets] = :absent
          return unless atom
          raw, n = rows(atom, 8, [0, 1])
          samples, nonzero = 0, false
          timing_row, timing_used, dts = 0, 0, 0
          n.times do |i|
            num, offset = raw.byteslice(8 + i * 8, 8).unpack(raw.getbyte(0) == 1 ? 'Nl>' : 'N2')
            fail!('zero ctts count') if num.zero?
            samples += num
            fail!('ctts/sample count mismatch') if samples > count
            nonzero ||= !offset.zero?
            # sttsとcttsの圧縮runを結合し、全sample配列なしでPTS範囲を検証。
            remaining = num
            while remaining.positive?
              run_count, delta = @timing_raw.byteslice(8 + timing_row * 8, 8).unpack('N2')
              take = [remaining, run_count - timing_used].min
              unless (dts + offset).between?(-MAX_TIME - 1, MAX_TIME) &&
                     (dts + take * delta + offset).between?(-MAX_TIME - 1, MAX_TIME)
                fail!('composition time overflow')
              end
              dts += take * delta
              remaining -= take
              timing_used += take
              if timing_used == run_count
                timing_row += 1
                timing_used = 0
              end
            end
          end
          fail!('ctts/sample count mismatch') unless samples == count
          @data[:composition_offsets] = nonzero ? :nonzero : :zero
          if nonzero
            @data[:first][:pts] = @data[:last][:pts] = nil
            @issues << { code: :composition_offsets, message: 'nonzero composition offsets are unsupported' }
          end
        end

        def chunks(stbl, root, sizes, count, fixed, field)
          mapping, n = rows(child(stbl, 'stsc'), 12)
          offsets = stbl[:children].select { |a| %w[stco co64].include?(a[:type]) }
          fail!('expected exactly one chunk offset table') unless offsets.size == 1
          width = offsets.first[:type] == 'stco' ? 4 : 8
          raw, chunks = rows(offsets.first, width)
          fail!('missing chunk mapping') if n.zero? || chunks.zero?
          previous = 0
          n.times do |i|
            start, num, desc = mapping.byteslice(8 + i * 12, 12).unpack('N3')
            fail!('invalid stsc row') if start <= previous || start > chunks || num.zero? || desc.zero? || desc > @description_count
            fail!('stsc must start at chunk 1') if i.zero? && start != 1
            previous = start
          end
          ranges = root.select { |a| a[:type] == 'mdat' }.map { |a| [a[:payload_offset], a[:end_offset]] }
          extents, sample, row = [], 0, 0
          chunks.times do |i|
            while row + 1 < n && mapping.byteslice(8 + (row + 1) * 12, 4).unpack1('N') <= i + 1
              row += 1
            end
            num = mapping.byteslice(12 + row * 12, 4).unpack1('N')
            fail!('chunk/sample count mismatch') if sample + num > count
            offset = raw.byteslice(8 + i * width, width).unpack1(width == 4 ? 'N' : 'Q>')
            size = if fixed.positive?
                     fixed * num
                   else
                     num.times.sum { |j| sample_size(sizes, sample + j, fixed, field) }
                   end
            finish = offset + size
            range_index = ranges.bsearch_index { |_, end_offset| end_offset > offset }
            range = range_index && ranges[range_index]
            fail!('chunk outside file/mdat') unless finish <= @file_size && range && offset >= range[0] && finish <= range[1]
            extents << [offset, finish] if size.positive?
            if sample.zero?
              @data[:first].merge!(offset: offset, size: sample_size(sizes, 0, fixed, field))
            end
            if sample + num == count
              last_size = sample_size(sizes, count - 1, fixed, field)
              @data[:last].merge!(offset: finish - last_size, size: last_size)
            end
            sample += num
          end
          fail!('chunk/sample count mismatch') unless sample == count
          extents.sort_by!(&:first)
          extents.each_cons(2) { |a, b| fail!('overlapping chunk extents') if a[1] > b[0] }
          @data[:last_is_max_raw_presentation_end] = @data[:composition_offsets] != :nonzero
        end
      end
      private_constant :SampleBoundaryReader
    end
  end
end
