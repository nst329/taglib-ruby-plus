# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tempfile'

# 前案Document/Update/SavePlanの保存境界を試すadapter。後続の編集用File案や製品APIではない。
module PlusAPIDesignProbe
  Legacy = TagLib::MP4

  # 計画前の世代不一致と、保存途中の失敗を区別する。
  class SourceChangedError < StandardError; end
  class ClosedError < StandardError; end
  class PlanError < StandardError; end

  # 既存出力を保持した失敗か、公開後の失敗かをテストから判定する。
  class SaveError < StandardError
    attr_reader :phase, :committed, :output_path, :temporary_path

    def initialize(message, phase:, committed: false, output_path: nil, temporary_path: nil)
      @phase, @committed, @output_path, @temporary_path = phase, committed, output_path, temporary_path
      super(message)
    end
  end

  # 次期factoryを既存の型付きsnapshotに接続し、更新の副作用と競合を検証する。
  class MetadataUpdate
    PROPERTY_NAMES = {
      title: 'title', artist: 'artist', album: 'album', genre: 'genre', comment: 'comment',
      copyright: 'copyright', description: 'description', long_description: 'longdesc',
      grouping: 'grouping', tv_show: 'TVShowName', tv_episode: 'TVEpisode', keyword: 'keyword',
      podcast_url: 'podcastURL', year: 'year', purchase_date: 'purchaseDate', content_rating: 'contentRating'
    }.freeze

    # 通常propertyの設定・削除を同じ実効atom/mdta対象へ解決する。
    def self.properties(set: {}, remove: [])
      names = set.keys + remove
      raise ArgumentError, 'duplicate property' unless names.uniq.size == names.size
      names.each { |name| PROPERTY_NAMES.fetch(name) { raise ArgumentError, 'unknown property' } }
      update = Legacy::MetadataUpdate.properties(set.to_h { |key, value| [PROPERTY_NAMES.fetch(key), value] })
      targets = remove.map { |name| Legacy::MetadataUpdate.targets(PROPERTY_NAMES.fetch(name)) }
      new(items: update.items, remove_items: targets.map { |target| target.fetch(:atom) },
          clear_mdta: update.remove_mdta + targets.flat_map { |target| target.fetch(:remove_mdta) })
    end

    # probeではmdta値の型として既存の名前付きHashを使用する。新MdtaValueは未実装。
    def self.mdta(set: {}, clear: [])
      raise ArgumentError, 'conflicting mdta request' unless (set.keys & clear).empty? && clear.uniq == clear
      normalized = set.to_h do |key, values|
        raise ArgumentError, 'empty mdta set' unless values.is_a?(Array) && !values.empty?
        [key, values.map { |value| value.values_at(:data_type, :locale, :data) }]
      end
      # 既存の純値検証を再利用する。writerが扱えることの証明ではない。
      Legacy::MetadataSnapshot.new(items: [], mdta: normalized.map { |key, rows| [key, 1, rows] })
      new(mdta: normalized, clear_mdta: clear)
    end

    def self.replace(snapshot)
      raise ArgumentError, 'expected snapshot' unless snapshot.is_a?(Legacy::MetadataSnapshot)
      new(replacement: snapshot)
    end

    # 配列の形式は既存codec境界に限定する。例: items=[['©nam', :string_list, 255, ['題名']]]。
    def initialize(items: [], remove_items: [], mdta: {}, clear_mdta: [], replacement: nil)
      @items, @remove_items, @mdta, @clear_mdta = Legacy::MetadataSnapshot.copy([items, remove_items, mdta, clear_mdta])
      @replacement = replacement
      freeze
    end
    private_class_method :new

    # 原本もbackendも変更せず、clear後の空キーを含む期待値を作る。
    def apply(snapshot)
      return @replacement if @replacement
      changed = snapshot.without(items: @remove_items).with(items: @items, mdta: @mdta)
      empty = @clear_mdta.select { |key| !changed.mdta_values(key).nil? }.to_h { |key| [key, []] }
      changed.with(mdta: empty)
    end

    # 正規化によるmdta除去も含めて競合を判定し、後勝ちにはしない。
    def merge(other)
      raise ArgumentError, 'expected update' unless other.is_a?(self.class)
      if @replacement || other.replacement ||
         !(item_targets & other.item_targets).empty? || !(mdta_targets & other.mdta_targets).empty?
        raise PlanError, 'conflicting metadata updates'
      end
      self.class.send(:new, items: @items + other.items, remove_items: @remove_items + other.remove_items,
        mdta: @mdta.merge(other.mdta), clear_mdta: @clear_mdta + other.clear_mdta)
    end

    protected

    attr_reader :items, :remove_items, :mdta, :clear_mdta, :replacement

    def item_targets
      @items.map(&:first) + @remove_items
    end

    def mdta_targets
      @mdta.keys + @clear_mdta
    end
  end

  # 省略と空配列を分けるchapter更新要求。既存Chapter値をそのまま使用する。
  class ChapterUpdate
    attr_reader :formats

    def initialize(**formats)
      raise ArgumentError, 'unknown chapter format' unless (formats.keys - %i[nero quicktime]).empty?
      checked = Legacy::ChapterSnapshot.new(**formats)
      @formats = formats.to_h { |key, _| [key, checked.public_send(key)] }.freeze
      freeze
    end

    # 指定した形式だけを置き換え、未指定形式は保持する。
    def apply(snapshot)
      Legacy::ChapterSnapshot.new(nero: @formats.fetch(:nero, snapshot.nero),
                                 quicktime: @formats.fetch(:quicktime, snapshot.quicktime))
    end
  end

  # 保存済み世代だけを読む。読み直しや計画作成でも元世代の一致を確認する。
  class Document
    def initialize(path)
      @path = ::File.realpath(path).freeze
      @digest = Digest::SHA256.file(@path).hexdigest.freeze
      @closed = false
    end

    def metadata
      read(&:metadata_snapshot)
    end

    def chapters
      read(&:chapter_snapshot)
    end

    # 通常更新だけを既存writerへ接続する。修復・raw/context専用経路はprobeの対象外。
    def plan(metadata: nil, chapters: nil)
      raise ArgumentError, 'update required' unless metadata || chapters
      raise ArgumentError, 'expected metadata update' if metadata && !metadata.is_a?(MetadataUpdate)
      raise ArgumentError, 'expected chapter update' if chapters && !chapters.is_a?(ChapterUpdate)
      read do |file|
        before_metadata, before_chapters = file.metadata_snapshot, file.chapter_snapshot
        SavePlan.new(path: @path, digest: @digest, before_metadata: before_metadata,
          metadata: metadata ? metadata.apply(before_metadata) : before_metadata,
          before_chapters: before_chapters,
          chapters: chapters ? chapters.apply(before_chapters) : before_chapters,
          chapter_update: chapters)
      end
    end

    def close
      @closed = true
      nil
    end

    private

    # cacheを返す設計に変えても、世代検査を省略できないことを表す境界。
    def read
      raise ClosedError, 'document is closed' if @closed
      ensure_generation!
      result = Legacy::Internal::File.open(@path, false) { |file| yield file }
      ensure_generation!
      result
    end

    def ensure_generation!
      raise SourceChangedError, 'source changed' unless Digest::SHA256.file(@path).hexdigest == @digest
    end
  end

  # Document/native/IOを保持せず、実fixtureの候補作成・再読込・公開を検証する。
  class SavePlan
    attr_reader :preview

    def initialize(path:, digest:, before_metadata:, metadata:, before_chapters:, chapters:, chapter_update:)
      @path, @digest = path, digest
      @metadata, @chapters, @chapter_update = metadata, chapters, chapter_update
      @allowed_empty = (before_metadata.mdta.map(&:first) - metadata.mdta.map(&:first)).freeze
      @preview = Legacy::MetadataSnapshot.copy(changed: before_metadata != metadata || before_chapters != chapters,
                                               source: path, writer: :existing_native_probe)
      freeze
    end

    # 元世代の原本だけを検証済み候補で置換する。
    def commit!
      save(@path, replace: true)
    end

    # 原本と既存出力を維持し、新しい出力pathへだけ公開する。
    def write_to!(path)
      save(::File.expand_path(path), replace: false)
    end

    private

    # 原本の再検査と公開を分け、競合・検証失敗時に候補だけを破棄する。
    def save(output, replace:)
      ensure_generation!
      raise SaveError.new('output exists', phase: :prepare) if !replace && (::File.exist?(output) || ::File.symlink?(output))
      return result(output, @digest, changed: false) if replace && !preview.fetch(:changed)
      temporary = Tempfile.new(['plus-design-', '.mp4'], ::File.dirname(output))
      temporary.close
      phase, committed = :write, false
      begin
        ::FileUtils.cp(@path, temporary.path)
        write_candidate(temporary.path) if preview.fetch(:changed)
        phase = :verify
        verify_candidate(temporary.path)
        digest = Digest::SHA256.file(temporary.path).hexdigest
        ensure_generation!
        phase = :publish
        publish(temporary.path, output, replace: replace)
        committed = true
        result(output, digest, changed: preview.fetch(:changed))
      rescue StandardError => error
        raise SaveError.new(error.message, phase: phase, committed: committed, output_path: output), cause: error
      ensure
        failure = $!
        begin
          cleanup_candidate(temporary)
        rescue IOError, SystemCallError => error
          raise SaveError.new("cleanup failed: #{error.message}", phase: :cleanup, committed: committed,
                              output_path: output, temporary_path: temporary.path), cause: failure || error
        end
      end
    end

    def ensure_generation!
      raise SourceChangedError, 'source changed' unless Digest::SHA256.file(@path).hexdigest == @digest
    end

    # 既存保存処理を再利用するためのadapter。特殊writerの選択は実装しない。
    def write_candidate(path)
      Legacy::Internal::File.open(path, false) do |file|
        file.restore_metadata_snapshot(@metadata)
        @chapter_update&.formats&.each { |format, values| file.set_chapters(values, style: format) }
        raise IOError, 'backend save failed' unless file.save
      end
    end

    # 独立handleの値とmedia署名を照合する。probeはmdatを変えないNero更新だけを実行する。
    def verify_candidate(path)
      Legacy::Internal::File.open(path, false) do |file|
        actual = file.metadata_snapshot
        removable = actual.mdta.filter_map { |key, _index, values| key if @allowed_empty.include?(key) && values.empty? }
        raise IOError, 'metadata mismatch' unless @metadata == actual.without(mdta: removable)
        raise IOError, 'chapters mismatch' unless @chapters == file.chapter_snapshot
        raise IOError, 'media mismatch' unless file.send(:mdat_payload_signature, @path) == file.send(:mdat_payload_signature, path)
      end
    end

    # linkは既存pathを置換しない。公開直前に競合出力が出現しても原本と競合側を保持する。
    def publish(temporary, output, replace:)
      replace ? ::File.rename(temporary, output) : ::File.link(temporary, output)
    end

    def cleanup_candidate(temporary)
      temporary.unlink
    end

    def result(path, digest, changed:)
      Legacy::MetadataSnapshot.copy(output_path: path, source_digest: @digest, output_digest: digest,
                                   changed: changed, verification: :probe_values_and_mdat)
    end
  end

  # ブロック終了時はcloseだけを行い、自動commitしない。
  def self.open(path)
    document = Document.new(path)
    return document unless block_given?
    begin
      yield document
    ensure
      document.close
    end
  end
end
