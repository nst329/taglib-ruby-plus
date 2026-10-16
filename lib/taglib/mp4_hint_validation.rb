# frozen_string_literal: true

module TagLib::MP4
  # RTP hintの位置依存性を限定し、chap編集で参照先sampleの意味が変わらないことを検証する。
  class HintValidator
    MAX_HINT_SAMPLES = 1_000_000
    MAX_HINT_BYTES = 64 * 1024 * 1024

    # 解析中の読取専用IOにだけ接続し、章参照の編集状態や保存計画は受け取らない。
    def initialize(file:, io:)
      @file, @io = file, io
    end

    # SDPは位置情報として解釈せず保持する。movie側rtp/sdpとtrack側sdpだけを認める。
    def validate_information(atom)
      entries = @file.send(:parse_mp4_atoms, @io, atom[:payload_offset], atom[:end_offset])
      fail!('unsupported hnti entries', :unsupported) unless entries.size == 1 && ['sdp ', 'rtp '].include?(entries.first[:type])
      entry = entries.first
      data = payload(entry)
      if entry[:type] == 'rtp '
        fail!('unsupported hnti protocol', :unsupported) unless data.byteslice(0, 4) == 'sdp '
        data = data.byteslice(4..)
      end
      fail!('invalid hnti SDP text') unless data.bytes.all? { |byte| [9, 10, 13].include?(byte) || (32..126).cover?(byte) }
    end

    # hmhdだけを許可せず、hintの形式・参照表・全sampleを保存前後で検証する。
    # tracksは[id, handler, trak atom]の配列。例: [[201, 'vide', video_atom]]。
    def validate_tracks(tracks:, offset_tables:, mdat_ranges:)
      @offset_tables, @mdat_ranges = offset_tables, mdat_ranges
      hints = tracks.select do |_id, handler, track|
        minf = child(child(track, 'mdia'), 'minf')
        header = child(minf, 'hmhd', required: false)
        fail!('hmhd outside hint track', :unsupported) if header && handler != 'hint'
        handler == 'hint'
      end
      return if hints.empty?

      layouts = hint_track_layouts(tracks)
      remaining = MAX_HINT_BYTES
      hints.each do |id, _handler, track|
        validate_hint_media_header(track)
        target = hint_target_layout(id, track, layouts)
        remaining = validate_hint_samples(layouts.fetch(id), target, remaining)
      end
    end

    private

    def fail!(message, code = :malformed)
      raise ChapterReferenceError.new(message, code: code)
    end

    def child(atom, type, required: true)
      selected = atom[:children].select { |entry| entry[:type] == type }
      fail!("duplicate #{type} atom", :unsupported) if selected.size > 1
      fail!("missing #{type} atom") if selected.empty? && required
      selected.first
    end

    def payload(atom)
      @file.send(:read_mp4_bytes, @io, atom[:payload_offset], atom[:end_offset] - atom[:payload_offset])
    end

    # 全トラックで共有するsample上限を、解析呼出し内の値として管理する。
    def hint_track_layouts(tracks)
      remaining = MAX_HINT_SAMPLES
      # track ID => {sizes: sampleサイズ配列, offsets: sample絶対位置配列}。例: 201 => {sizes: [32], offsets: [4096]}。
      tracks.to_h do |id, _handler, track|
        layout = hint_sample_layout(track, remaining)
        remaining -= layout[:sizes].size
        [id, layout]
      end
    end

    # hint専用headerとsample記述の組を検証し、他media形式との混在を拒否する。
    def validate_hint_media_header(track)
      minf = child(child(track, 'mdia'), 'minf')
      header = payload(child(minf, 'hmhd'))
      fail!('invalid hmhd size') unless header.bytesize == 20
      fail!('unsupported hmhd version or flags', :unsupported) unless header.byteslice(0, 4) == [0].pack('N')
      fail!('unsupported hmhd reserved field', :unsupported) unless header.byteslice(16, 4) == [0].pack('N')
      fail!('conflicting hint media headers', :unsupported) if minf[:children].any? { |a| %w[vmhd smhd gmhd nmhd].include?(a[:type]) }
      validate_hint_description(child(minf, 'stbl'))
    end

    # ref index=0の参照先を一意にする。複数trefを統合した解釈は行わない。
    def hint_target_layout(id, track, layouts)
      references = track[:children].select { |a| a[:type] == 'tref' }.flat_map do |tref|
        atom = child(tref, 'hint', required: false)
        next [] unless atom
        data = payload(atom)
        fail!('invalid hint reference payload') unless data.bytesize == 4
        data.unpack('N*')
      end
      fail!('unsupported hint track references', :unsupported) unless references.size == 1 && layouts.key?(references.first) && references.first != id
      layouts.fetch(references.first)
    end

    # 読込前に共有bytes上限を適用し、検証後の残量を次のhintへ引き継ぐ。
    def validate_hint_samples(layout, target, remaining)
      layout[:sizes].each_with_index do |size, index|
        remaining -= size
        fail!('hint sample bytes exceed limit', :unsupported) if remaining.negative?
        data = @file.send(:read_mp4_bytes, @io, layout[:offsets].fetch(index), size)
        validate_hint_sample(data, target)
      end
      remaining
    end

    # 一つの自己完結RTP v1記述だけを認め、未知の拡張をopaque許可しない。
    def validate_hint_description(stbl)
      stsd = child(stbl, 'stsd')
      data = payload(stsd)
      fail!('invalid hint stsd') unless data.bytesize >= 32 && data.byteslice(0, 8) == [0, 1].pack('N2') &&
        data.byteslice(8, 4).unpack1('N') == data.bytesize - 8
      fail!('unsupported hint sample entry', :unsupported) unless data.byteslice(12, 4) == 'rtp '
      fail!('invalid hint sample entry') unless data.byteslice(16, 6) == "\0".b * 6 && data.byteslice(22, 2).unpack1('n') == 1
      fail!('unsupported hint version', :unsupported) unless data.byteslice(24, 4) == [1, 1].pack('n2')
      extensions = @file.send(:parse_mp4_atoms, @io, stsd[:payload_offset] + 32, stsd[:end_offset])
      fail!('missing or duplicate hint tims') unless extensions.count { |a| a[:type] == 'tims' } == 1
      fail!('duplicate hint extension') unless extensions.map { |a| a[:type] }.uniq.size == extensions.size
      extensions.each do |atom|
        fail!("unsupported hint extension #{atom[:type]}", :unsupported) unless %w[tims tsro snro].include?(atom[:type])
        value = payload(atom)
        fail!('invalid hint extension size') unless value.bytesize == 4
        fail!('zero hint timescale') if atom[:type] == 'tims' && value.unpack1('N').zero?
      end
    end

    def hint_table(stbl, type, width)
      data = payload(child(stbl, type))
      fail!("invalid hint #{type} header") unless data.bytesize >= 8 && data.byteslice(0, 4) == [0].pack('N')
      count = data.byteslice(4, 4).unpack1('N')
      fail!("hint #{type} exceeds limit", :unsupported) if count > MAX_HINT_SAMPLES
      fail!("hint #{type} count mismatch") unless data.bytesize == 8 + count * width
      data.byteslice(8..).unpack('N*').each_slice(width / 4).to_a
    end

    # 固定サイズstszでも、配列を生成する前に残りのsample上限を確認する。
    def hint_sample_sizes(stbl, remaining)
      data = payload(child(stbl, 'stsz'))
      fail!('invalid hint-related stsz') unless data.bytesize >= 12 && data.byteslice(0, 4) == [0].pack('N')
      fixed, count = data.byteslice(4, 8).unpack('N2')
      fail!('hint-related sample count exceeds limit', :unsupported) if count > remaining
      fail!('hint-related stsz count mismatch') unless data.bytesize == 12 + (fixed.zero? ? count * 4 : 0)
      fixed.zero? ? data.byteslice(12..).unpack('N*') : Array.new(count, fixed)
    end

    # 宣言数とchunk割当を照合し、参照先にも使えるsample配置を組み立てる。
    def hint_sample_layout(track, remaining)
      stbl = child(child(child(track, 'mdia'), 'minf'), 'stbl')
      fail!('unsupported hint-related stz2', :unsupported) if child(stbl, 'stz2', required: false)
      sizes = hint_sample_sizes(stbl, remaining)
      table = stbl[:children].find { |a| %w[stco co64].include?(a[:type]) }
      chunks = @offset_tables.fetch(table[:offset])[1]
      mapping = hint_table(stbl, 'stsc', 12)
      times = hint_table(stbl, 'stts', 8)
      fail!('hint-related stts count mismatch') unless times.sum(&:first) == sizes.size && times.all? { |n, _delta| n.positive? }
      return { sizes: [], offsets: [] } if sizes.empty? && chunks.empty? && mapping.empty?
      fail!('invalid hint-related stsc') unless mapping.first&.first == 1 &&
        mapping.each_cons(2).all? { |a, b| a.first < b.first } &&
        mapping.all? { |first, n, desc| first <= chunks.size && n.positive? && desc == 1 }
      { sizes: sizes, offsets: hint_sample_offsets(chunks, mapping, sizes) }
    end

    # stcoの先頭位置だけでなく、全sampleが一つのmdat内に収まることを確認する。
    def hint_sample_offsets(chunks, mapping, sizes)
      offsets, index, entry = [], 0, 0
      chunks.each_with_index do |offset, chunk|
        entry += 1 while entry + 1 < mapping.size && mapping[entry + 1][0] <= chunk + 1
        mapping[entry][1].times do
          fail!('hint-related stsc sample count mismatch') unless index < sizes.size
          size = sizes.fetch(index)
          fail!('hint-related sample outside mdat') unless size.positive? && @mdat_ranges.any? { |first, last| offset >= first && offset + size <= last }
          offsets << offset
          offset += size
          index += 1
        end
      end
      fail!('hint-related stsc sample count mismatch') unless index == sizes.size
      offsets
    end

    # 対応するconstructorは即値と単一mediaのsample相対参照。sample/descriptionの書換はしない。
    def validate_hint_sample(data, target)
      fail!('truncated hint sample') if data.bytesize < 4
      packets, reserved = data.unpack('n2')
      fail!('invalid hint sample reserved') unless reserved.zero?
      position = 4
      packets.times do
        fail!('truncated hint packet') if position + 12 > data.bytesize
        flags, count = data.byteslice(position + 8, 4).unpack('n2')
        fail!('unsupported hint packet flags', :unsupported) unless (flags & ~7).zero?
        position += 12
        position = validate_hint_extra(data, position) unless (flags & 4).zero?
        count.times do
          fail!('truncated hint constructor') if position + 16 > data.bytesize
          validate_hint_constructor(data.byteslice(position, 16), target)
          position += 16
        end
      end
      # Additional dataは即値/sample内参照と異なる領域。現対応では利用しない。
      fail!('unsupported hint additional data', :unsupported) unless position == data.bytesize
    end

    def validate_hint_constructor(data, target)
      case data.getbyte(0)
      when 0 # no-op
      when 1
        fail!('invalid hint immediate length') if data.getbyte(1) > 14
      when 2
        ref, length, sample, offset, bytes, samples = data.byteslice(1..).unpack('CnNNnn')
        fail!('unsupported hint sample reference', :unsupported) unless ref.zero? && bytes <= 1 && samples <= 1
        fail!('hint sample reference outside target') unless sample.positive? && sample <= target[:sizes].size && offset + length <= target[:sizes].fetch(sample - 1)
      else
        fail!("unsupported hint constructor #{data.getbyte(0)}", :unsupported)
      end
    end

    # rtpoは時刻補正だけを持つ。未知TLVには位置依存情報があり得るため拒否する。
    def validate_hint_extra(data, position)
      fail!('truncated hint extra size') if position + 4 > data.bytesize
      size = data.byteslice(position, 4).unpack1('N')
      boundary = position + size
      fail!('invalid hint extra boundary') unless size >= 4 && boundary <= data.bytesize
      position += 4
      while position < boundary
        fail!('truncated hint TLV') if position + 8 > boundary
        length, type = data.byteslice(position, 8).unpack('Na4')
        fail!('invalid hint TLV boundary') unless length >= 8 && position + length <= boundary
        fail!("unsupported hint TLV #{type}", :unsupported) unless type == 'rtpo' && length == 12
        position += length
      end
      position
    end
  end
  private_constant :HintValidator
end
