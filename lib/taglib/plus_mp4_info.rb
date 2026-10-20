# frozen_string_literal: true

module TagLib
  module Plus
    module MP4
      # header観測とRuby構造診断の読取source。nativeや外部probeを開かない。
      class HeaderReader
        include ::TagLib::MP4::AtomParsing
        SECTIONS = %i[movie tracks chapters artwork].freeze
        LIMIT = 1024 * 1024
        attr_reader :name, :io_generation

        def initialize(path, generation)
          @name, @io_generation = path, generation
          @cache, @views, @track_tables = {}, {}, {}
        end

        # 形式別の完全chapter読取はRuby readerへ委譲し、native metadataを開かない。
        def chapter_diagnostics
          ::TagLib::MP4.const_get(:ChapterReader, false).read(self).report
        end

        def chapter_reference_diagnostics
          ::TagLib::MP4::ChapterReferences.new(self, capture_raw: false, capture_signature: false).report
        end

        def chapter_timing_diagnostics
          ::TagLib::MP4::ChapterReferences.new(self, timing: true, capture_raw: false, capture_signature: false).timing_report
        end

        def color_metadata_diagnostics
          ::TagLib::MP4.const_get(:ColorMetadataReader, false).new(self).read
        end

        def chapter_sample_snapshot
          ::TagLib::MP4::ChapterSampleSnapshot.capture(self)
        end

        # 選択領域だけを遅延し、別の選択でも同じ不変sectionを再利用する。
        def snapshot(sections)
          unless sections.is_a?(Array) && (sections - SECTIONS).empty? && sections.uniq == sections
            raise ArgumentError, 'sections must be unique movie/tracks/chapters/artwork symbols'
          end
          key = sections.dup.freeze
          return @views[key] if @views.key?(key)
          @io_generation.check!
          value = with_io { sections.to_h { |section| [section, section_value(section)] }.freeze }
          @io_generation.check!
          @views[key] = value
        end

        # 保存の構造検証にも同じRuby parserを渡し、旧Tag/画像のnative読込を避ける。
        def structure
          with_io { atoms }
        end

        # 旧ilstを読まずに、native変換用の空contextをhandlerから作る。
        def metadata_template(context, handler)
          with_io do
            children = parse_mp4_atoms(@io, context.fetch(:offset) + 12, context.fetch(:end_offset))
            hdlr = one(children, 'hdlr')
            raw = bytes(hdlr, 0, length(hdlr))
            fail!('truncated metadata handler') if raw.bytesize < 12
            raw[8, 4] = handler
            helper = ::TagLib::MP4.const_get(:PurlSnapshot, false)
            parts = helper.box('hdlr', raw)
            parts += helper.box('keys', [0, 0].pack('N2')) if handler == 'mdta'
            helper.box('meta', [0].pack('N') + parts + helper.box('ilst', ''.b))
          end
        end

        # 置換対象の旧meta/画像を取得せず、udta内の保持対象だけを組み直す。
        def metadata_container(mdir, mdta, replace_nero: false, nero: nil)
          with_io do
            helper = ::TagLib::MP4.const_get(:PurlSnapshot, false)
            udta = child(movie_atom, 'udta')
            inserted = false
            children = udta[:children].flat_map do |atom|
              if atom[:type] == 'meta'
                next [] if inserted
                inserted = true
                [mdir, mdta].compact
              elsif replace_nero && atom[:type] == 'chpl'
                []
              elsif %w[free skip].include?(atom[:type])
                []
              else
                [read_mp4_bytes(@io, atom[:offset], atom[:end_offset] - atom[:offset])]
              end
            end
            children << nero if replace_nero && nero
            helper.box('udta', children.join.b)
          end
        end

        private

        def with_io
          return yield if @io
          ::File.open(@name, 'rb') do |io|
            @io = io
            @remaining_bytes = 8 * 1024 * 1024
            begin
              yield
            ensure
              @io = nil
            end
          end
        end

        def atoms
          @atoms ||= parse_mp4_atoms(@io, 0, @io.stat.size)
        end

        def movie_atom
          one(atoms, 'moov')
        end

        def section_value(section)
          @cache[section] ||= DeepCopy.call(send("read_#{section}"))
        end

        def fail!(message, code = :malformed)
          raise Error.new(message, code: code, area: :info, phase: :read)
        end

        def one(rows, type, required: true)
          found = rows.select { |row| row[:type] == type }
          fail!("duplicate #{type} header", :unsupported) if found.size > 1
          fail!("missing #{type} header") if required && found.empty?
          found.first
        end

        def child(atom, type, required: true)
          one(atom[:children], type, required: required)
        end

        def length(atom)
          atom[:end_offset] - atom[:payload_offset]
        end

        def bytes(atom, offset, count)
          fail!('header read exceeds limit', :limit) if count > LIMIT
          @remaining_bytes -= count
          fail!('header snapshot exceeds read limit', :limit) if @remaining_bytes.negative?
          fail!("truncated #{atom[:type]} header") if offset.negative? || count.negative? || offset + count > length(atom)
          read_mp4_bytes(@io, atom[:payload_offset] + offset, count)
        end

        def full_payload(atom)
          bytes(atom, 0, length(atom))
        end

        def timestamp(raw)
          { raw: raw, epoch: '1904-01-01T00:00:00Z', unit: :seconds,
            status: raw.zero? ? :unset : :declared }
        end

        # v0/v1の整数時間軸を保持し、all-onesのunknownをゼロへ変換しない。
        def timing(atom)
          version = bytes(atom, 0, 1).getbyte(0)
          fail!("unsupported #{atom[:type]} version", :unsupported) unless [0, 1].include?(version)
          data = bytes(atom, 0, version == 1 ? 32 : 20)
          created, modified, scale, duration = if version == 1
                                                data.byteslice(4, 28).unpack('Q>Q>NQ>')
                                              else
                                                data.byteslice(4, 16).unpack('N4')
                                              end
          fail!('zero timescale') if scale.zero?
          { version: version, timescale: scale, raw_duration: duration,
            duration_ticks: duration == (1 << (version == 1 ? 64 : 32)) - 1 ? nil : duration,
            creation_time: timestamp(created), modification_time: timestamp(modified) }
        end

        # mvhdの宣言を返し、fragmentの実timelineを集計済みと扱わない。
        def read_movie
          result = timing(child(movie_atom, 'mvhd'))
          result.merge(status: atoms.any? { |a| %w[moof mvex].include?(a[:type]) } ||
            movie_atom[:children].any? { |a| a[:type] == 'mvex' } ? :fragmented : :declared)
        end

        def duration(ticks, scale, source)
          { ticks: ticks, timescale: scale, source: source, status: ticks.nil? ? :unknown : :declared }
        end

        def language(atom, version)
          raw = bytes(atom, version == 1 ? 32 : 20, 2).unpack1('n')
          letters = [raw >> 10 & 31, raw >> 5 & 31, raw & 31]
          code = letters.all? { |v| v.between?(1, 26) } ? letters.map { |v| (v + 96).chr }.join : nil
          { raw: raw, code: code, status: code ? :declared : :unknown }
        end

        def handler(atom)
          data = full_payload(atom)
          fail!('truncated hdlr') if data.bytesize < 24
          fail!('unsupported hdlr version', :unsupported) unless data.getbyte(0).zero?
          text = data.byteslice(24..).delete_suffix("\0").force_encoding(Encoding::UTF_8)
          iso_name = data.byteslice(4, 4) == "\0".b * 4
          { fourcc: data.byteslice(8, 4), name: iso_name && text.valid_encoding? && !text.include?("\0") ? text : nil,
            raw_name: data.byteslice(24..) }
        end

        # track IDで参照関係を結び、外部stream indexから独立した役割を判定する。
        def read_tracks
          scale = section_value(:movie)[:timescale]
          tracks = movie_atom[:children].select { |a| a[:type] == 'trak' }.map { |track| read_track(track, scale) }
          fail!('duplicate track IDs') unless tracks.map { |t| t[:id] }.uniq.size == tracks.size
          tracks.each do |track|
            sources = tracks.select { |source| source[:chapter_target_ids].include?(track[:id]) }.map { |source| source[:id] }
            track[:chapter_source_ids] = sources
            track[:role] = role(track, sources)
          end
          tracks
        end

        # movie/media/editの時間軸と、表示用headerの生値を分離して取得する。
        def read_track(track, movie_scale)
          tkhd = child(track, 'tkhd')
          version = bytes(tkhd, 0, 1).getbyte(0)
          fail!('unsupported tkhd version', :unsupported) unless [0, 1].include?(version)
          data = bytes(tkhd, 0, version == 1 ? 96 : 84)
          created, modified, id, _reserved, raw_duration = version == 1 ?
            data.byteslice(4, 32).unpack('Q>Q>NNQ>') : data.byteslice(4, 20).unpack('N5')
          fail!('zero track ID') if id.zero?
          ticks = raw_duration == (1 << (version == 1 ? 64 : 32)) - 1 ? nil : raw_duration
          mdia = child(track, 'mdia')
          mdhd = child(mdia, 'mdhd')
          media = timing(mdhd)
          hdlr = handler(child(mdia, 'hdlr'))
          stbl = child(child(mdia, 'minf'), 'stbl')
          @track_tables[id] = stbl
          edits = edit_list(track)
          presentation = if edits.nil?
                           duration(ticks, movie_scale, :tkhd)
                         elsif edits.all? { |e| e[:rate_integer] == 1 && e[:rate_fraction].zero? }
                           duration(edits.sum { |e| e[:segment_duration] }, movie_scale, :edit_list)
                         else
                           { ticks: nil, timescale: movie_scale, source: :edit_list, status: :unsupported }
                         end
          refs = track[:children].select { |a| a[:type] == 'tref' }.flat_map do |tref|
            tref[:children].select { |a| a[:type] == 'chap' }.flat_map do |chap|
              raw = full_payload(chap)
              fail!('invalid chap references') unless (raw.bytesize % 4).zero?
              raw.unpack('N*')
            end
          end
          matrix_offset = version == 1 ? 52 : 40
          matrix = data.byteslice(matrix_offset, 36).unpack('l>9')
          rotation = { [65536, 0, 0, 65536] => 0, [0, 65536, -65536, 0] => 90,
            [-65536, 0, 0, -65536] => 180, [0, -65536, 65536, 0] => 270 }[matrix.values_at(0, 1, 3, 4)]
          rotation = nil unless matrix.values_at(2, 5, 8) == [0, 0, 1 << 30]
          dimensions = data.byteslice(matrix_offset + 36, 8).unpack('N2')
          udta = child(track, 'udta', required: false)
          name = udta && child(udta, 'name', required: false)
          raw_name = name && full_payload(name)
          decoded_name = raw_name&.dup&.force_encoding(Encoding::UTF_8)
          decoded_name = nil if decoded_name && (!decoded_name.valid_encoding? || decoded_name.include?("\0"))
          { id: id, handler: hdlr[:fourcc], handler_name: hdlr[:name], handler_name_raw: hdlr[:raw_name],
            name: decoded_name, track_name: name ? { raw: raw_name, source: :udta_name,
              status: decoded_name ? :utf8 : :unsupported_encoding } : nil,
            enabled: (data.unpack1('N') & 1) != 0, language: language(mdhd, media[:version]),
            creation_time: timestamp(created), modification_time: timestamp(modified),
            media_creation_time: media[:creation_time], media_modification_time: media[:modification_time],
            header_duration: duration(ticks, movie_scale, :tkhd), raw_header_duration: raw_duration,
            media_duration: duration(media[:duration_ticks], media[:timescale], :mdhd), raw_media_duration: media[:raw_duration],
            presentation_duration: presentation, edits: edits, chapter_target_ids: refs,
            sample_entries: sample_entries(child(stbl, 'stsd'), hdlr[:fourcc]),
            width: hdlr[:fourcc] == 'vide' && dimensions[0].positive? ? Rational(dimensions[0], 65536) : nil,
            height: hdlr[:fourcc] == 'vide' && dimensions[1].positive? ? Rational(dimensions[1], 65536) : nil,
            raw_width_fixed: dimensions[0], raw_height_fixed: dimensions[1], matrix: matrix,
            rotation_degrees: hdlr[:fourcc] == 'vide' ? rotation : nil,
            rotation_status: hdlr[:fourcc] == 'vide' ? (rotation ? :canonical : :unknown) : :not_applicable }
        end

        def role(track, sources)
          base = { 'vide' => :video, 'soun' => :audio, 'sbtl' => :subtitle, 'subt' => :subtitle, 'clcp' => :subtitle }[track[:handler]]
          if sources.any?
            return { status: :ambiguous, value: nil, evidence: [:chapter_reference, :conflicting_handler] } unless track[:handler] == 'text'
            return { status: :resolved, value: :chapter, evidence: [:chapter_reference, :text_handler] }
          end
          return { status: :resolved, value: base, evidence: [:handler] } if base
          { status: :unknown, value: nil, evidence: [track[:handler] == 'text' ? :unreferenced_text : :unknown_handler] }
        end

        def edit_list(track)
          edts = child(track, 'edts', required: false)
          elst = edts && child(edts, 'elst', required: false)
          return nil unless elst
          header = bytes(elst, 0, 8)
          version = header.getbyte(0)
          fail!('unsupported elst version', :unsupported) unless [0, 1].include?(version)
          count = header.byteslice(4, 4).unpack1('N')
          width = version == 1 ? 20 : 12
          fail!('elst count mismatch') unless length(elst) == 8 + count * width
          data = bytes(elst, 8, count * width)
          Array.new(count) do |i|
            values = data.byteslice(i * width, width).unpack(version == 1 ? 'Q>q>s>s>' : 'Nl>s>s>')
            %i[segment_duration media_time rate_integer rate_fraction].zip(values).to_h
          end
        end

        # codec名や実stream状態を推定せず、sample entryの共通headerだけを返す。
        def sample_entries(stsd, track_handler)
          header = bytes(stsd, 0, 8)
          entries = parse_mp4_atoms(@io, stsd[:payload_offset] + 8, stsd[:end_offset])
          fail!('stsd count mismatch') unless entries.size == header.byteslice(4, 4).unpack1('N')
          entries.map do |entry|
            result = { fourcc: entry[:type], data_reference_index: bytes(entry, 6, 2).unpack1('n') }
            if track_handler == 'soun'
              version = length(entry) >= 10 ? bytes(entry, 8, 2).unpack1('n') : nil
              result.merge!(audio_version: version, sample_rate: nil, channels: nil, audio_status: :unsupported)
              if [0, 1].include?(version) && length(entry) >= 28
                rate = bytes(entry, 24, 4).unpack1('N')
                channels = bytes(entry, 16, 2).unpack1('n')
                result.merge!(sample_rate: rate.positive? ? Rational(rate, 65536) : nil,
                  channels: channels.positive? ? channels : nil, audio_status: :declared,
                  raw_sample_rate_fixed: rate, raw_channels: channels)
              end
            elsif track_handler == 'vide'
              dimensions = length(entry) >= 28 ? bytes(entry, 24, 4).unpack('n2') : [nil, nil]
              result.merge!(width: dimensions[0]&.positive? ? dimensions[0] : nil,
                height: dimensions[1]&.positive? ? dimensions[1] : nil)
            end
            result
          end
        end

        def sample_count(stbl)
          table = child(stbl, 'stsz', required: false) || child(stbl, 'stz2', required: false)
          table ? bytes(table, 8, 4).unpack1('N') : nil
        end

        # sample本文を読まず、既存の完全診断と区別した件数宣言だけを返す。
        def read_chapters
          tracks = section_value(:tracks)
          udta = child(movie_atom, 'udta', required: false)
          chpl = udta && child(udta, 'chpl', required: false)
          nero = if chpl
                   version = bytes(chpl, 0, 1).getbyte(0)
                   [0, 1].include?(version) ? { present: true, count: bytes(chpl, version == 1 ? 8 : 4, 1).getbyte(0), status: :declared } :
                     { present: true, count: nil, status: :unsupported }
                 else
                   { present: false, count: 0, status: :absent }
                 end
          targets = tracks.flat_map { |t| t[:chapter_target_ids] }.uniq
          target = targets.size == 1 && tracks.find { |t| t[:id] == targets.first }
          quicktime = if targets.empty?
                        { present: false, count: 0, status: :absent }
                      elsif target && target[:role][:value] == :chapter
                        count = sample_count(@track_tables.fetch(target[:id]))
                        { present: true, count: count, status: count ? :declared : :unknown }
                      else
                        { present: true, count: nil, status: :ambiguous }
                      end
          { nero: nero, quicktime: quicktime }
        end

        # covrのdata headerだけを読み、画像bytesを取得・hash・複製しない。
        def read_artwork
          udta = child(movie_atom, 'udta', required: false)
          return [] unless udta
          udta[:children].select { |a| a[:type] == 'meta' }.flat_map do |meta|
            children = parse_mp4_atoms(@io, meta[:payload_offset] + 4, meta[:end_offset])
            ilst = one(children, 'ilst', required: false)
            next [] unless ilst
            entries = parse_mp4_atoms(@io, ilst[:payload_offset], ilst[:end_offset])
            entries.select { |a| a[:type] == 'covr' }.flat_map do |cover|
              parse_mp4_atoms(@io, cover[:payload_offset], cover[:end_offset]).map do |data|
                fail!('unsupported covr child', :unsupported) unless data[:type] == 'data'
                type, locale = bytes(data, 0, 8).unpack('N2')
                { source: :covr, data_type: type, locale: locale, bytesize: length(data) - 8,
                  format: { 13 => :jpeg, 14 => :png, 27 => :bmp }[type] }
              end
            end
          end
        end
      end
      private_constant :HeaderReader
    end
  end
end
