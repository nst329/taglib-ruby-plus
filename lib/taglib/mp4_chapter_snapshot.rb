# frozen_string_literal: true

module TagLib::MP4
  # 不完全読取・非対応構造・復元入力の拒否理由を保存状態と区別して伝える。
  class ChapterSnapshotError < ArgumentError
    attr_reader :code, :phase, :style

    def initialize(message, code: :invalid_snapshot, phase: :capture, style: nil)
      @code, @phase, @style = code, phase, style
      super(message)
    end
  end

  # NeroとQuickTimeのミリ秒時刻・タイトルを別々に所有する不変の論理snapshot。
  class ChapterSnapshot
    attr_reader :nero, :quicktime
    STYLES = %i[nero quicktime].freeze

    def initialize(nero: [], quicktime: [])
      @nero = checked_chapters(nero, :nero)
      @quicktime = checked_chapters(quicktime, :quicktime)
      freeze
    end

    def logical_equal?(other)
      other.is_a?(self.class) && nero == other.nero && quicktime == other.quicktime
    end
    alias == logical_equal?

    # 形式別に件数・時刻・タイトル・順序を報告する。空差分と論理一致は同じ基準。
    # 例: [{ style: :nero, changes: [:title], before: [[0, '旧']], after: [[0, '新']] }]
    def diff(actual)
      raise ChapterSnapshotError, 'expected ChapterSnapshot' unless actual.is_a?(self.class)

      MetadataSnapshot.copy(STYLES.filter_map do |style|
        before = public_send(style).map { |c| [c.start_time, c.title] }
        after = actual.public_send(style).map { |c| [c.start_time, c.title] }
        next if before == after

        changes = []
        changes << :value_count unless before.size == after.size
        changes << :start_time unless before.map(&:first) == after.map(&:first)
        before_titles, after_titles = before.map(&:last), after.map(&:last)
        changes << :title unless before_titles == after_titles
        changes << :order if before_titles != after_titles && before_titles.sort == after_titles.sort
        { style: style, changes: changes, before: before, after: after }
      end)
    end

    private

    def checked_chapters(values, style)
      limit = style == :nero ? 255 : 100_000
      unless values.is_a?(Array) && values.size <= limit
        raise ChapterSnapshotError.new("invalid #{style} chapter list size", phase: :input, style: style)
      end
      previous = -1
      copied = values.map do |chapter|
        unless chapter.is_a?(Chapter) && chapter.start_time.is_a?(Integer) && chapter.start_time > previous && chapter.title.is_a?(String)
          raise ChapterSnapshotError.new('chapter times must be strictly increasing', phase: :input, style: style)
        end
        maximum = style == :nero ? 0x7fff_ffff_ffff_ffff / 10_000 : 0xffff_ffff
        if chapter.start_time > maximum || chapter.title.bytesize > (style == :nero ? 255 : 65_535)
          raise ChapterSnapshotError.new('chapter exceeds writer limits', phase: :input, style: style)
        end
        previous = chapter.start_time
        Chapter.new(start_time: chapter.start_time, title: chapter.title)
      rescue ArgumentError => error
        raise error if error.is_a?(ChapterSnapshotError)

        raise ChapterSnapshotError.new(error.message, phase: :input, style: style)
      end
      if style == :quicktime && copied.size > 1 && copied.first.start_time.zero? && copied.first.title.empty?
        raise ChapterSnapshotError.new('leading empty QuickTime chapter is reserved for timing padding',
                                       phase: :input, style: style)
      end
      copied.freeze
    end
  end

  class File
    # 読取完了状態と拒否理由を形式別に返す。pending変更があっても原本構造を検証する。
    def chapter_diagnostics
      ChapterReader.new(self).report
    end

    # 不完全な原本構造を拒否してから、両形式とpending変更を独立に退避する。
    def chapter_snapshot
      reader = ChapterReader.new(self)
      reader.require_complete!
      values = ChapterSnapshot::STYLES.to_h do |style|
        native = chapter_values_for(style)
        unless @chapter_changes.key?(style) || native == reader.values.fetch(style)
          raise ChapterSnapshotError.new('native chapter read differs from complete read',
                                         code: :unsupported, style: style)
        end
        [style, native]
      end
      ChapterSnapshot.new(**values)
    end

    # 選択形式を全置換する未保存操作。全候補の検証後に一度だけpending状態を変更する。
    def restore_chapter_snapshot(snapshot, styles: ChapterSnapshot::STYLES)
      unless snapshot.is_a?(ChapterSnapshot) && styles.is_a?(Array) &&
             styles.uniq == styles && (styles - ChapterSnapshot::STYLES).empty?
        raise ChapterSnapshotError.new('invalid chapter snapshot or styles', phase: :restore)
      end
      checked = ChapterSnapshot.new(nero: snapshot.nero, quicktime: snapshot.quicktime)
      chapter_snapshot
      candidates = styles.to_h do |style|
        chapters = checked.public_send(style)
        _validate_chapters(chapters)
        [style, chapters]
      end
      @chapter_changes = @chapter_changes.merge(candidates)
      self
    rescue ChapterSnapshotError => error
      raise ChapterSnapshotError.new(error.message, code: error.code, phase: :restore, style: error.style)
    rescue ArgumentError => error
      raise ChapterSnapshotError.new(error.message, phase: :restore)
    end
  end
end

require_relative 'mp4_chapter_reader'
