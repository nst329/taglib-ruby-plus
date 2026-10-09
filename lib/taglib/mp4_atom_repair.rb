# frozen_string_literal: true

module TagLib::MP4
  # 検証済みmoovの限定atom編集。offset補正と対象外bytesの保持は参照修復と共用する。
  class MP4AtomEditor < ChapterReferences
    attr_reader :result

    # 例: timing_track: 4。metadata_transformはraw meta bytesだけを受け取る内部処理。
    def initialize(file, timing_track: nil, metadata_transform: nil)
      @timing_track, @metadata_transform = timing_track, metadata_transform
      @atom_replacements = {}
      super(file, timing: !timing_track.nil?, ignore_metadata: !metadata_transform.nil?)
    end

    # 元境界と期待signatureだけを持つ不変計画を返す。
    def atom_plan
      return nil if @atom_replacements.empty?
      ChapterReferenceRepair.new(moov_start: @moov[:offset], moov_end: @moov[:end_offset],
        replacement: replacement, source_digest: source_digest, removed: [], retained_report: report,
        preservation_signature: preservation_signature)
    end

    private

    def prepare_atom_edits
      fail!('repair dangling references before other atom edits', :pending_changes) unless @report.none? { |r| r[:status] == :missing }
      if @metadata_transform
        metas = []
        walk(@moov[:children]) { |atom| metas << atom if atom[:type] == 'meta' }
        fail!('single moov/udta/meta required', :unsupported) unless metas.size == 1 &&
          @moov[:children].select { |a| a[:type] == 'udta' }.any? { |u| u[:children].include?(metas.first) }
        @atom_replacements[metas.first[:offset]] = @metadata_transform.call(bytes(metas.first))
      else
        prepare_timing_edit
      end
    end

    # 再現済みwriter profileの一致を確認し、movie単位の64bit durationだけを昇格する。
    def prepare_timing_edit
      info = @timing_report.find { |row| row[:track_id] == @timing_track }
      @result = MetadataSnapshot.copy(status: :not_applicable, reason: :profile_mismatch, track_id: @timing_track)
      return unless info
      return unless native_timing_profile?(info)
      movie, _media, header, edits = info.values_at(:movie, :media, :track_header, :edits)
      duration = movie[:duration]
      @file.chapter_snapshot
      candidates = @report.select { |r| r[:target_track_id] == @timing_track }
      fail!('single audio chapter reference required', :unsupported) unless candidates.size == 1 &&
        @moov[:children].select { |a| a[:type] == 'trak' }.any? { |t| id, handler, = track_info(t); id == candidates.first[:source_track_id] && handler == 'soun' }
      track = @moov[:children].find { |t| t[:type] == 'trak' && track_info(t).first == @timing_track }
      tkhd = child(track, 'tkhd')
      old = payload(tkhd)
      fail!('unsupported tkhd length', :unsupported) unless old.bytesize == 84
      promoted = [0x0100_0000 | (old.unpack1('N') & 0xffffff)].pack('N') +
        old.byteslice(4, 8).unpack('N2').pack('Q>2') + old.byteslice(12, 8) + [duration].pack('Q>') + old.byteslice(24..)
      elst = child(child(track, 'edts'), 'elst')
      @atom_replacements[tkhd[:offset]] = box(tkhd, promoted)
      @atom_replacements[elst[:offset]] = box(elst, [0x0100_0000, 1].pack('N2') + [duration, 0, 65_536].pack('Q>q>l>'))
      @result = MetadataSnapshot.copy(status: :planned, profile: :taglib_full_movie, track_id: @timing_track,
        before: { tkhd_duration: header[:duration], elst_duration: edits.first[:segment_duration] },
        after: { version: 1, tkhd_duration: duration, elst_duration: duration })
    end

    # 単位誤り・下位32bit切捨て・ms丸めが同時に一致する場合だけ補正候補とする。
    def native_timing_profile?(info)
      movie, media, header, edits = info.values_at(:movie, :media, :track_header, :edits)
      duration = movie[:duration]
      rounded_ms = (duration * 1000 + movie[:timescale] / 2) / movie[:timescale]
      movie[:version] == 1 && duration > 0xffff_ffff && duration < 0xffff_ffff_ffff_ffff &&
        media == { version: 0, duration: rounded_ms, timescale: 1000 } &&
        info[:stts][:duration] == media[:duration] && header == { version: 0, duration: media[:duration] } &&
        edits == [{ version: 0, segment_duration: duration & 0xffff_ffff, media_time: 0, media_rate: 65_536 }]
    end

    def preservation_value(atom)
      if @atom_replacements.key?(atom[:offset])
        data = @atom_replacements.fetch(atom[:offset]).byteslice(atom[:payload_offset] - atom[:offset]..)
        [data.bytesize, Digest::SHA256.hexdigest(data)]
      else
        super
      end
    end

    def render(atom, delta)
      return @atom_replacements.fetch(atom[:offset]) if @atom_replacements.key?(atom[:offset])
      return ''.b if @consumed_free&.include?(atom[:offset])
      super
    end

    # 直下freeを必要量だけ消費する。不足分だけmoovを拡張し、stco/co64を移動する。
    def replacement
      @consumed_free = []
      edited = render(@moov, 0)
      growth = edited.bytesize - length(@moov)
      if growth.positive?
        @moov[:children].select { |a| a[:type] == 'free' }.each do |atom|
          break unless growth.positive?
          @consumed_free << atom[:offset]
          growth -= length(atom)
        end
      end
      edited = render(@moov, 0)
      available = length(@moov) - edited.bytesize
      padding = if available >= 8
                  available
                elsif available.positive?
                  available + 8
                else
                  0
                end
      delta = edited.bytesize + padding - length(@moov)
      edited = render(@moov, delta)
      fail!('edited moov exceeds repair limit', :unsupported) if edited.bytesize + padding > MAX_MOOV_BYTES
      return edited.freeze if padding.zero?
      box(@moov, edited.byteslice(@moov[:payload_offset] - @moov[:offset]..) + [padding].pack('N') + 'free' + "\0".b * (padding - 8)).freeze
    end
  end
  private_constant :MP4AtomEditor

  class File
    # full-movie生成意図を明示した場合だけ、再現済みnative writerの時間幅・単位を修復する。
    def repair_native_chapter_timing(track_id:, profile:)
      raise ArgumentError, 'profile must be :taglib_full_movie' unless profile == :taglib_full_movie
      ensure_timing_repair_isolated!
      if @chapter_timing_repair
        raise ChapterReferenceError.new('timing repair already planned', code: :pending_changes)
      end
      editor = MP4AtomEditor.new(self, timing_track: Integer(track_id))
      @chapter_timing_repair = editor.atom_plan
      editor.result
    end

    private

    def ensure_timing_repair_isolated!
      if metadata_dirty? || @chapter_changes.any? || @chapter_reference_repair
        raise ChapterReferenceError.new('save tag, chapter and reference edits separately from timing repair', code: :pending_changes)
      end
    end

    # 参照修復と同じ原子的保存契約で、時間atomの期待bytesを別handleから検証する。
    def save_timing_repair
      save_reference_repair(@chapter_timing_repair, timing: true)
    end
  end
end
