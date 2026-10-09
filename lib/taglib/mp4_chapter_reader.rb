# frozen_string_literal: true

module TagLib::MP4
  # nativeの部分読取を成功扱いしないため、chapterの宣言数・参照・bytesを全件検証する。
  class ChapterReader
    MAX_BYTES = 32 * 1024 * 1024
    MAX_VALUES = 100_000
    attr_reader :report, :values

    def initialize(file)
      @file, @report, @values = file, {}, {}
      ::File.open(file.name, 'rb') do |io|
        @io = io
        @atoms = file.send(:parse_mp4_atoms, io, 0, io.stat.size)
        reject!('fragmented MP4 chapters are unsupported', :unsupported) if @atoms.any? { |a| a[:type] == 'moof' }
        @moov = one(@atoms, 'moov')
        ChapterSnapshot::STYLES.each { |style| capture(style) }
      end
    rescue ChapterSnapshotError, MdtaSaveError, SystemCallError, IOError => error
      ChapterSnapshot::STYLES.each { |style| failed(style, error) }
    ensure
      @report = MetadataSnapshot.copy(@report)
      @values.freeze
    end

    # 全形式が完全または不在の場合だけsnapshot生成と復元を許す。
    def require_complete!
      report.each do |style, result|
        next if %i[complete absent].include?(result[:status])

        raise ChapterSnapshotError.new(result[:reason], code: result[:status], style: style)
      end
    end

    private

    def capture(style)
      chapters = style == :nero ? nero : quicktime
      @values[style] = chapters || [].freeze
      @report[style] = { status: chapters ? :complete : :absent, reason: nil }
    rescue ChapterSnapshotError, MdtaSaveError => error
      failed(style, error)
    end

    def failed(style, error)
      status = error.is_a?(ChapterSnapshotError) && error.code == :unsupported ? :unsupported : :malformed
      @report[style] = { status: status, reason: error.message }
    end

    def reject!(reason, code = :malformed)
      raise ChapterSnapshotError.new(reason, code: code)
    end

    def one(atoms, type, required: true)
      selected = atoms.select { |a| a[:type] == type }
      reject!("duplicate #{type} atom", :unsupported) if selected.size > 1
      reject!("missing #{type} atom") if required && selected.empty?
      selected.first
    end

    def child(atom, type, required: true)
      one(atom[:children], type, required: required)
    end

    def payload(atom)
      size = atom[:end_offset] - atom[:payload_offset]
      reject!('chapter payload exceeds limit', :unsupported) if size > MAX_BYTES
      @file.send(:read_mp4_bytes, @io, atom[:payload_offset], size)
    end

    def utf8(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      reject!('invalid chapter UTF-8 or NUL') unless text.valid_encoding? && !text.include?("\0")
      text
    end

    def nero
      udta = child(@moov, 'udta', required: false)
      return nil unless udta
      chpl = child(udta, 'chpl', required: false)
      return nil unless chpl
      bytes = payload(chpl)
      reject!('truncated chpl header') if bytes.size < 5
      version = bytes.getbyte(0)
      reject!('unsupported chpl version', :unsupported) unless [0, 1].include?(version)
      reject!('unsupported chpl flags', :unsupported) unless bytes.byteslice(1, 3) == "\0".b * 3
      offset = version == 1 ? 8 : 4
      reject!('truncated chpl count') unless bytes.size > offset
      if version == 1 && bytes.byteslice(4, 4) != "\0".b * 4
        reject!('unsupported chpl reserved fields', :unsupported)
      end
      count = bytes.getbyte(offset)
      offset += 1
      chapters = Array.new(count) do
        reject!('truncated chpl entry') if offset + 9 > bytes.size
        time = bytes.byteslice(offset, 8).unpack1('q>')
        size = bytes.getbyte(offset + 8)
        offset += 9
        reject!('truncated chpl title') if offset + size > bytes.size
        reject!('submillisecond Nero chapter time', :unsupported) unless (time % 10_000).zero?
        title = utf8(bytes.byteslice(offset, size))
        offset += size
        Chapter.new(time / 10_000, title)
      end
      reject!('chpl count or payload mismatch') unless offset == bytes.size
      ChapterSnapshot.new(nero: chapters).nero
    rescue ArgumentError => error
      raise error if error.is_a?(ChapterSnapshotError)
      reject!(error.message)
    end

    # native writerが扱う単一音声参照・text/stco/stsz構造を厳密に読む。
    def quicktime
      tracks = @moov[:children].select { |a| a[:type] == 'trak' }
      references = tracks.filter_map do |track|
        tref = child(track, 'tref', required: false)
        chap = tref && child(tref, 'chap', required: false)
        next unless chap
        reject!('chapter reference outside audio track', :unsupported) unless handler(track) == 'soun'
        bytes = payload(chap)
        reject!('multiple or empty chapter track references', :unsupported) unless bytes.size == 4
        bytes.unpack1('N')
      end
      return nil if references.empty?
      reject!('multiple chapter references', :unsupported) unless references.size == 1
      ids = tracks.map { |t| identifier(t) }
      reject!('duplicate track identifiers', :unsupported) unless ids.uniq == ids
      matches = tracks.select { |t| identifier(t) == references.first }
      reject!('missing or duplicate chapter track') unless matches.size == 1
      track = matches.first
      reject!('unsupported chapter track handler', :unsupported) unless handler(track) == 'text'
      mdia = child(track, 'mdia')
      mdhd = payload(child(mdia, 'mdhd'))
      reject!('unsupported chapter mdhd', :unsupported) unless mdhd.size == 24 && mdhd.byteslice(0, 4) == "\0".b * 4
      scale = mdhd.byteslice(12, 4).unpack1('N')
      reject!('zero chapter timescale') if scale.zero?
      validate_edit_list(track)
      minf = child(mdia, 'minf')
      validate_data_reference(minf)
      stbl = child(minf, 'stbl')
      reject!('unsupported chapter timing or size table', :unsupported) if stbl[:children].any? { |a| %w[ctts stz2 co64].include?(a[:type]) }
      validate_description(stbl)
      sizes = sample_sizes(stbl)
      reject!('chapter sample bytes exceed limit', :unsupported) if sizes.sum > MAX_BYTES
      times = sample_times(stbl, scale, sizes.size)
      offsets = sample_offsets(stbl, sizes)
      ranges = @atoms.select { |a| a[:type] == 'mdat' }.map { |a| [a[:payload_offset], a[:end_offset]] }
      chapters = sizes.each_with_index.map do |size, i|
        offset = offsets.fetch(i)
        reject!('chapter sample is outside mdat') unless @file.send(:media_range?, offset, size, ranges)
        reject!('chapter sample exceeds limit', :unsupported) if size > MAX_BYTES
        bytes = @file.send(:read_mp4_bytes, @io, offset, size)
        reject!('truncated chapter text length') if bytes.size < 2
        length = bytes.unpack1('n')
        reject!('truncated chapter text') if length + 2 > size
        suffix = bytes.byteslice(length + 2..)
        unless suffix.empty? || suffix == [12].pack('N') + 'encd' + [0, 0x0100].pack('n2')
          reject!('unsupported chapter text modifiers', :unsupported)
        end
        Chapter.new(times.fetch(i), utf8(bytes.byteslice(2, length)))
      end
      # nativeの非ゼロ開始時刻を表すpadding規約と同じ扱いにする。
      chapters.shift if chapters.size > 1 && chapters.first.start_time.zero? && chapters.first.title.empty?
      ChapterSnapshot.new(quicktime: chapters).quicktime
    end

    def handler(track)
      bytes = payload(child(child(track, 'mdia'), 'hdlr'))
      reject!('truncated track handler') if bytes.size < 24
      bytes.byteslice(8, 4)
    end

    def identifier(track)
      bytes = payload(child(track, 'tkhd'))
      version = bytes.getbyte(0)
      reject!('unsupported track header', :unsupported) unless [0, 1].include?(version)
      reject!('truncated track header') if bytes.size < (version == 1 ? 96 : 84)
      id = bytes.byteslice(version == 1 ? 20 : 12, 4).unpack1('N')
      reject!('zero track identifier') if id.zero?
      id
    end

    def validate_data_reference(minf)
      dinf = child(minf, 'dinf')
      bytes = payload(child(dinf, 'dref'))
      unless bytes == [0, 1, 12].pack('N3') + 'url ' + [1].pack('N')
        reject!('unsupported external or multiple chapter data references', :unsupported)
      end
    end

    def table(stbl, type, width)
      bytes = payload(child(stbl, type))
      reject!("invalid #{type} header") unless bytes.size >= 8 && bytes.byteslice(0, 4) == "\0".b * 4
      count = bytes.byteslice(4, 4).unpack1('N')
      reject!("#{type} exceeds entry limit", :unsupported) if count > MAX_VALUES
      reject!("#{type} count mismatch") unless bytes.size == 8 + count * width
      bytes.byteslice(8..).unpack('N*').each_slice(width / 4).to_a
    end

    def sample_sizes(stbl)
      bytes = payload(child(stbl, 'stsz'))
      reject!('invalid stsz header') unless bytes.size >= 12 && bytes.byteslice(0, 4) == "\0".b * 4
      size, count = bytes.byteslice(4, 8).unpack('N2')
      reject!('stsz exceeds sample limit', :unsupported) if count > MAX_VALUES
      reject!('stsz count mismatch') unless bytes.size == 12 + (size.zero? ? count * 4 : 0)
      size.zero? ? bytes.byteslice(12..).unpack('N*') : Array.new(count, size)
    end

    def sample_times(stbl, scale, count)
      entries = table(stbl, 'stts', 8)
      reject!('stts sample count mismatch') unless entries.sum(&:first) == count
      time = 0
      entries.flat_map do |number, delta|
        Array.new(number) do
          reject!('submillisecond QuickTime chapter time', :unsupported) unless (time * 1000 % scale).zero?
          result = time * 1000 / scale
          reject!('chapter time exceeds writer width', :unsupported) if result > 0xffff_ffff
          time += delta
          result
        end
      end
    end

    def sample_offsets(stbl, sizes)
      chunks = table(stbl, 'stco', 4).flatten
      mapping = table(stbl, 'stsc', 12)
      if sizes.empty? && chunks.empty? && mapping.empty?
        return []
      end
      reject!('invalid stsc mapping') unless mapping.first&.first == 1 &&
        mapping.each_cons(2).all? { |a, b| a.first < b.first } &&
        mapping.all? { |first, count, desc| first <= chunks.size && count.positive? && desc == 1 }
      offsets, index, entry = [], 0, 0
      chunks.each_with_index do |offset, chunk|
        entry += 1 while entry + 1 < mapping.size && mapping[entry + 1][0] <= chunk + 1
        mapping[entry][1].times do
          reject!('stsc sample count mismatch') unless index < sizes.size
          reject!('chapter offset exceeds native width', :unsupported) if offset > 0xffff_ffff
          reject!('overlapping or unordered chapter samples', :unsupported) if offsets.any? && offset < offsets.last + sizes[index - 1]
          offsets << offset
          offset += sizes[index]
          index += 1
        end
      end
      reject!('stsc sample count mismatch') unless index == sizes.size
      offsets
    end

    def validate_description(stbl)
      bytes = payload(child(stbl, 'stsd'))
      reject!('unsupported chapter sample description', :unsupported) unless bytes.size >= 24 &&
        bytes.byteslice(0, 8) == [0, 1].pack('N2') && bytes.byteslice(12, 4) == 'text' &&
        bytes.byteslice(8, 4).unpack1('N') == bytes.size - 8 && bytes.byteslice(22, 2).unpack1('n') == 1
    end

    def validate_edit_list(track)
      edts = child(track, 'edts', required: false)
      return unless edts
      bytes = payload(child(edts, 'elst'))
      reject!('unsupported chapter edit list', :unsupported) unless bytes.size == 20 &&
        bytes.byteslice(0, 8) == [0, 1].pack('N2') && bytes.byteslice(12, 8) == [0, 0x0001_0000].pack('N2')
    end
  end
  private_constant :ChapterReader
end
