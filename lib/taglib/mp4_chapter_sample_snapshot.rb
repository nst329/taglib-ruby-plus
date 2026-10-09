# frozen_string_literal: true

module TagLib::MP4
  # 保存済みtext chapterの全media sampleと時間写像を所有する読取専用の不変値。
  class ChapterSampleSnapshot
    attr_reader :track_id, :source_track_id, :media_timescale, :media_duration,
                :samples, :movie, :edit, :preservation_signature, :ffprobe_comparison

    # 例: capture(file).samples.first => {sample_index: 0, start_ticks: 0, duration_ticks: 50, ...}
    # private constructorへ完全読取済みのデータだけを渡す。
    def self.capture(file)
      reader = ChapterReader.new(file, samples: true)
      reader.require_complete!
      reader.sample_data && new(reader.sample_data)
    end

    # movie/edit変更を除き、track・media時計・全sampleの順序とpayloadの保持を比較する。
    def preserved_equal?(other)
      other.is_a?(self.class) && preservation_signature == other.preservation_signature
    end

    # 照合対象が全sampleを覆う単一identity写像の場合に限りFFprobe比較を許す。
    def require_ffprobe_comparable!
      return self if ffprobe_comparison[:status] == :complete

      raise ChapterSnapshotError.new(ffprobe_comparison[:reason], code: :unsupported, style: :quicktime)
    end

    private

    def initialize(data)
      copied = MetadataSnapshot.copy(data)
      copied.each { |key, value| instance_variable_set("@#{key}", value) }
      # 固定幅整数と固定長digestを連結する。物理offsetやmovie/edit時間は含めない。
      identity = [1, track_id, source_track_id, media_timescale, media_duration, samples.size].pack('Q>*')
      samples.each do |sample|
        identity << sample.values_at(:sample_index, :start_ticks, :duration_ticks, :payload_size).pack('Q>*')
        identity << [sample[:payload_sha256]].pack('H*')
      end
      @preservation_signature = Digest::SHA256.hexdigest(identity).freeze
      limit = edit ? edit[:segment_duration] : movie[:duration]
      complete = limit * media_timescale >= media_duration * movie[:timescale] &&
                 movie[:duration] * media_timescale >= media_duration * movie[:timescale]
      @ffprobe_comparison = MetadataSnapshot.copy(
        status: complete ? :complete : :clipped,
        reason: complete ? nil : 'movie or identity edit does not cover all media samples',
        mapping: :identity, origin_ticks: 0
      )
      freeze
    end
    private_class_method :new
  end

  class File
    # pending編集を反映せず、保存済みの全sampleを読む。不在はnil、不完全読取は例外。
    def chapter_sample_snapshot
      ChapterSampleSnapshot.capture(self)
    end
  end
end
