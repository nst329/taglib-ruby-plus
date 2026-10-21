# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tempfile'
require_relative 'plus_mp4_io'
require_relative 'plus_mp4_publication'
require_relative 'plus_mp4_info'
require_relative 'mp4_sample_boundaries'
require_relative 'mp4_structure_diagnostics'

module TagLib
  module Plus
    # taglib-ruby-plus専用のMP4編集API。native Fileは各操作の間だけ開く。
    module MP4
      PROPERTY_NAMES = {
        title: 'title', artist: 'artist', album: 'album', genre: 'genre', comment: 'comment',
        copyright: 'copyright', description: 'description', long_description: 'longdesc',
        grouping: 'grouping', tv_show: 'TVShowName', tv_episode: 'TVEpisode', keyword: 'keyword',
        podcast_url: 'podcastURL', year: 'year', purchase_date: 'purchaseDate', content_rating: 'contentRating'
      }.freeze
      STRUCTURE_ERRORS = [::TagLib::MP4::MetadataSnapshotError, ::TagLib::MP4::ChapterSnapshotError,
                          ::TagLib::MP4::ChapterReferenceError, ::TagLib::MP4::ColorMetadataError].freeze
      private_constant :STRUCTURE_ERRORS
      DIAGNOSTIC_OPERATIONS = {
        metadata: :metadata_diagnostics, chapters: :chapter_diagnostics,
        chapter_references: :chapter_reference_diagnostics,
        chapter_timing: :chapter_timing_diagnostics, color: :color_metadata_diagnostics,
        structure: nil
      }.freeze
      private_constant :DIAGNOSTIC_OPERATIONS
      # 公開APIではcover artのwire整数を扱わせず、形式名を固定する。
      class Artwork
        FORMATS = { jpeg: 13, png: 14, bmp: 27 }.freeze
        BY_NATIVE_FORMAT = FORMATS.invert.freeze
        SIGNATURES = {
          jpeg: "\xFF\xD8\xFF".b,
          png: "\x89PNG\r\n\x1A\n".b,
          bmp: 'BM'.b
        }.freeze
        attr_reader :format, :data

        def initialize(format:, data:)
          @format = format.to_sym if format.respond_to?(:to_sym)
          unless FORMATS.key?(@format)
            raise Error.new("unsupported artwork format: #{format.inspect}", code: :unsupported_artwork,
                            phase: :validate, issues: [{ code: :unsupported_artwork, path: 'artwork/format',
                                                         format: format.inspect }])
          end
          unless data.instance_of?(::String)
            raise Error.new('artwork data must be a String', code: :unsupported_artwork,
                            phase: :validate, issues: [{ code: :invalid_artwork, path: 'artwork/data' }])
          end
          @data = ::TagLib::MP4::MetadataSnapshot.binary(data)
          unless @data.start_with?(SIGNATURES.fetch(@format))
            raise Error.new("artwork data does not match #{@format} format", code: :unsupported_artwork,
                            phase: :validate, issues: [{ code: :invalid_artwork, path: 'artwork/data',
                                                         format: @format }])
          end
          @data.freeze
          freeze
        end

        def native_format
          FORMATS.fetch(format)
        end
        private :native_format

        def ==(other)
          other.is_a?(self.class) && [format, data] == [other.format, other.data]
        end
        alias eql? ==

        def hash
          [format, data].hash
        end
      end
      ContentRating = ::TagLib::MP4::ContentRating

      class Error < StandardError
        attr_reader :code, :area, :phase, :committed, :publication_status, :output_path, :temporary_path, :issues

        def initialize(message, code: nil, area: nil, phase: nil, committed: false,
                       publication_status: nil, output_path: nil, temporary_path: nil, issues: [])
          publication_status ||= if committed.nil?
                                  :unknown
                                elsif committed
                                  :committed
                                else
                                  :not_committed
                                end
          unless Publication::State::STATUSES.include?(publication_status)
            raise ArgumentError, "invalid publication_status: #{publication_status.inspect}"
          end
          @code, @area, @phase = code, area, phase
          @publication_status = publication_status
          @committed = publication_status == :committed ? true : (publication_status == :unknown ? nil : false)
          @output_path, @temporary_path = output_path, temporary_path
          @issues = DeepCopy.call(issues)
          super(message)
        end
      end

      module DeepCopy
        module_function

        def call(value)
          copied = case value
                   when Hash then value.to_h { |key, item| [call(key), call(item)] }
                   when Array then value.map { |item| call(item) }
                   when String then value.instance_of?(String) && value.frozen? ? value : value.dup
                   else value
                   end
          copied.freeze
        end
      end

      # mdtaの型・locale・bytesをnativeから切り離した不変値。
      class MdtaValue
        attr_reader :data_type, :locale, :data

        def initialize(data_type:, locale:, data:)
          unless data_type.is_a?(Integer) && data_type.between?(0, 0xffff_ffff)
            raise ArgumentError, 'data_type must be an unsigned 32-bit Integer'
          end
          unless locale.is_a?(Integer) && locale.between?(0, 0xffff_ffff)
            raise ArgumentError, 'locale must be an unsigned 32-bit Integer'
          end
          raise ArgumentError, 'data must be a String' unless data.instance_of?(::String)

          @data_type, @locale = data_type, locale
          @data = ::TagLib::MP4::MetadataSnapshot.binary(data)
          freeze
        end

        def ==(other)
          other.is_a?(self.class) && [data_type, locale, data] == [other.data_type, other.locale, other.data]
        end
        alias eql? ==

        def hash
          [data_type, locale, data].hash
        end
      end

      # 通常MP4 itemの型付きsnapshot。保存時だけlegacy itemへ変換する。
      class MetadataItem
        attr_reader :key, :kind, :atom_data_type, :value

        def initialize(key:, kind:, atom_data_type:, value:)
          raise ArgumentError, 'item key must be a String' unless key.instance_of?(::String) && key.index("\0").nil?
          unless ::TagLib::MP4::MetadataSnapshot::KINDS.include?(kind) && atom_data_type.is_a?(Integer) && atom_data_type.between?(0, 0xffff_ffff)
            raise ArgumentError, 'invalid metadata item type'
          end
          ::TagLib::MP4::MetadataSnapshot.new(items: [[key, kind, atom_data_type, value]], mdta: [])

          @key, @kind, @atom_data_type = key.dup.freeze, kind, atom_data_type
          @value = DeepCopy.call(value)
          freeze
        end

        def ==(other)
          other.is_a?(self.class) && [key, kind, atom_data_type, value] ==
            [other.key, other.kind, other.atom_data_type, other.value]
        end
        alias eql? ==

        def hash
          [key, kind, atom_data_type, value].hash
        end
      end

      # MetadataSnapshotはlegacy snapshotを値として包み、公開APIの名前をsnake_caseに揃える。
      class MetadataSnapshot
        attr_reader :items, :mdta

        def self.from_legacy(snapshot, previous: nil)
          allocate.tap { |value| value.__send__(:initialize_legacy, snapshot, previous: previous) }
        end
        private_class_method :from_legacy

        # nativeを開かず、型付きitemとmdta値から復元用snapshotを構築する。
        def initialize(items: [], mdta: {}, artworks: nil)
          raise ArgumentError, 'items must be an Array of MetadataItem' unless items.is_a?(Array) && items.all? { |item| item.is_a?(MetadataItem) }
          raise ArgumentError, 'mdta must be a Hash' unless mdta.is_a?(Hash)

          @mdta = {}.freeze
          rows = items.map { |item| [item.key, item.kind, item.atom_data_type, item.value] }
          rows += artwork_rows(artworks, items.map(&:key)) unless artworks.nil?
          groups = normalize_mdta(mdta, keep_empty: true).each_with_index.map { |(key, values), index| [key, index + 1, values] }
          initialize_legacy(::TagLib::MP4::MetadataSnapshot.new(items: rows, mdta: groups))
        end

        def initialize_legacy(snapshot, previous: nil)
          unless snapshot.is_a?(::TagLib::MP4::MetadataSnapshot)
            raise ArgumentError, 'expected TagLib::MP4::MetadataSnapshot'
          end
          @legacy = snapshot
          previous_items = previous ? previous.items.to_h { |item| [item.key, item] } : {}
          @items = snapshot.items.map do |key, kind, type, value|
            old = previous_items[key]
            old && [old.kind, old.atom_data_type, old.value] == [kind, type, value] ? old :
              MetadataItem.new(key: key, kind: kind, atom_data_type: type, value: value)
          end.freeze
          @mdta = snapshot.mdta.to_h do |key, _index, values|
            [key, values.map { |type, locale, data| MdtaValue.new(data_type: type, locale: locale, data: data) }.freeze]
          end.freeze
          freeze
        end
        private :initialize_legacy

        def to_legacy
          @legacy
        end
        private :to_legacy

        def item(key)
          items.find { |item| item.key == key.to_s }
        end

        def properties
          DeepCopy.call(PROPERTY_NAMES.to_h do |public_name, native_name|
            item = item(::TagLib::MP4::Tag::PROPERTY_ATOMS.fetch(native_name))
            [public_name, item ? property_values(native_name, item) : mdta_property_values(native_name)]
          end)
        end

        def artworks
          item = item('covr')
          return [].freeze unless item

          item.value.map do |format, data|
            public_format = Artwork::BY_NATIVE_FORMAT[format]
            unless public_format
              raise Error.new("unsupported artwork format: #{format.inspect}", code: :unsupported_artwork,
                              phase: :validate, issues: [{ path: 'metadata/items/covr', code: :unsupported_artwork,
                                                           format: format }])
            end
            begin
              Artwork.new(format: public_format, data: data)
            rescue ArgumentError => error
              raise Error.new(error.message, code: :unsupported_artwork, phase: :validate,
                              issues: [{ path: 'metadata/items/covr', code: :invalid_artwork,
                                         message: error.message }]), cause: error
            end
          end.freeze
        end

        # 指定した領域だけを全入力検証して置換し、元snapshotは変更しない。
        def with(properties: {}, items: {}, mdta: {}, artworks: nil)
          validate_hash!(properties, 'properties')
          validate_hash!(items, 'items')
          validate_hash!(mdta, 'mdta')
          rows = @legacy
          unless artworks.nil?
            images = artwork_rows(artworks, items.keys.map(&:to_s))
            rows = rows.without(items: ['covr'])
            rows = rows.with(items: images) unless images.empty?
          end
          normalized_properties = normalize_properties(properties)
          normalized_items = normalize_items(items)
          normalized_mdta = normalize_mdta(mdta)
          normalized_properties.each { |name, value| rows = ::TagLib::MP4::MetadataUpdate.properties(PROPERTY_NAMES.fetch(name) => value).apply(rows) }
          rows = rows.with(items: normalized_items.values) unless normalized_items.empty?
          rows = rows.with(mdta: normalized_mdta) unless normalized_mdta.empty?
          self.class.__send__(:from_legacy, rows, previous: self)
        end

        # propertyまたは通常itemを削除し、対応mdtaの値も明示的にclearする。
        def without(properties: [], items: [])
          unless properties.is_a?(Array) && items.is_a?(Array)
            raise ArgumentError, 'properties and items must be Arrays'
          end
          names = properties.map { |name| normalize_property_name(name) }
          item_keys = items.map { |key| validate_key(key) }
          rows = @legacy
          names.each do |name|
            target = ::TagLib::MP4::MetadataUpdate.targets(PROPERTY_NAMES.fetch(name))
            rows = rows.without(items: [target.fetch(:atom)])
            existing = target.fetch(:remove_mdta).select { |key| !rows.mdta_values(key).nil? }
            rows = rows.with(mdta: existing.to_h { |key| [key, []] }) unless existing.empty?
          end
          rows = rows.without(items: item_keys) unless item_keys.empty?
          self.class.__send__(:from_legacy, rows, previous: self)
        end

        def ==(other)
          other.is_a?(self.class) && @legacy == other.__send__(:to_legacy)
        end
        alias eql? ==

        def hash
          @legacy.hash
        end

        private

        # constructorと部分編集で同じ画像検証・covr表現を使う。
        def artwork_rows(artworks, item_keys)
          raise ArgumentError, 'artworks must be an Array' unless artworks.is_a?(Array)
          raise ArgumentError, 'items and artworks cannot both contain covr' if item_keys.include?('covr')
          unless artworks.all? { |art| art.is_a?(Artwork) }
            raise ArgumentError, 'artworks must contain Artwork values'
          end
          return [] if artworks.empty?

          [['covr', :cover_art_list, 255,
            artworks.map { |art| [art.__send__(:native_format), art.data] }]]
        end

        def property_values(native_name, item)
          values = item.value
          return values.map { |value| ::TagLib::MP4::ContentRating.parse(value) } if native_name == 'contentRating'

          values
        end

        def mdta_property_values(native_name)
          key = ::TagLib::MP4::Tag::MDTA_PROPERTY_KEYS[native_name]
          return nil unless key && @mdta.key?(key)

          values = @mdta.fetch(key).filter_map do |value|
            next unless value.data_type == 1
            text = value.data.dup.force_encoding(Encoding::UTF_8)
            text if text.valid_encoding?
          end
          values.empty? ? nil : values
        end

        def normalize_properties(values)
          values.to_h do |name, value|
            public_name = normalize_property_name(name)
            raise ArgumentError, "#{public_name} must not be nil" if value.nil?
            [public_name, value]
          end
        end

        def normalize_items(values)
          values.to_h do |key, value|
            unless value.is_a?(MetadataItem)
              raise ArgumentError, 'items values must be MetadataItem'
            end
            raise ArgumentError, 'item key does not match' unless key.to_s == value.key
            [value.key, [value.key, value.kind, value.atom_data_type, value.value]]
          end
        end

        def normalize_mdta(values, keep_empty: false)
          values.each_with_object({}) do |(key, list), result|
            key = validate_key(key)
            raise ArgumentError, 'mdta values must be an Array' unless list.is_a?(Array)
            normalized = list.map do |value|
              value = if value.is_a?(MdtaValue)
                        value
                      elsif value.is_a?(Hash)
                        MdtaValue.new(**value.transform_keys(&:to_sym))
                      else
                        raise ArgumentError, 'mdta values must be MdtaValue'
                      end
              [value.data_type, value.locale, value.data]
            end
            next if normalized.empty? && !keep_empty && !@mdta.key?(key)
            result[key] = normalized
          end
        end

        def normalize_property_name(name)
          name = name.to_sym if name.respond_to?(:to_sym)
          raise ArgumentError, "unknown property: #{name.inspect}" unless PROPERTY_NAMES.key?(name)

          name
        end

        def validate_key(key)
          raise ArgumentError, 'metadata key must be a String' unless key.instance_of?(::String)
          raise ArgumentError, 'metadata key must not contain NUL bytes' if key.index("\0")

          key
        end

        def validate_hash!(value, name)
          raise ArgumentError, "#{name} must be a Hash" unless value.is_a?(Hash)
        end
      end

      # ms単位の論理chapter値。legacy Chapterとは別の不変値。
      class Chapter
        attr_reader :start_ms, :title

        def initialize(start_ms:, title:)
          raise ArgumentError, 'start_ms must be a non-negative Integer' unless start_ms.is_a?(Integer) && start_ms >= 0
          raise ArgumentError, 'title must be a UTF-8 String' unless title.instance_of?(::String) && title.encoding == Encoding::UTF_8 && title.valid_encoding?

          raise ArgumentError, 'title must not contain NUL bytes' if title.include?("\0")
          @start_ms, @title = start_ms, title.dup.freeze
          freeze
        end

        def ==(other)
          other.is_a?(self.class) && [start_ms, title] == [other.start_ms, other.title]
        end
        alias eql? ==

        def hash
          [start_ms, title].hash
        end

        def to_legacy
          ::TagLib::MP4::Chapter.new(start_time: start_ms, title: title)
        end
        private :to_legacy
      end

      class ChapterSnapshot
        attr_reader :nero, :quicktime
        UNSET = Object.new.freeze

        def self.from_legacy(snapshot)
          new(nero: snapshot.nero, quicktime: snapshot.quicktime)
        end
        private_class_method :from_legacy

        def initialize(nero: [], quicktime: [])
          @nero = normalize(nero, :nero)
          @quicktime = normalize(quicktime, :quicktime)
          freeze
        end

        # 省略した形式は維持し、空配列だけをその形式の削除として扱う。
        def with(nero: UNSET, quicktime: UNSET)
          self.class.new(nero: nero.equal?(UNSET) ? @nero : nero,
                         quicktime: quicktime.equal?(UNSET) ? @quicktime : quicktime)
        end

        def to_legacy
          ::TagLib::MP4::ChapterSnapshot.new(nero: nero.map { |value| value.__send__(:to_legacy) },
                                           quicktime: quicktime.map { |value| value.__send__(:to_legacy) })
        end
        private :to_legacy

        def ==(other)
          other.is_a?(self.class) && nero == other.nero && quicktime == other.quicktime
        end
        alias eql? ==

        def hash
          [nero, quicktime].hash
        end

        private

        def normalize(values, style)
          raise ArgumentError, "#{style} must be an Array" unless values.is_a?(Array)
          previous = -1
          result = values.map do |chapter|
            chapter = chapter.is_a?(Chapter) ? chapter : Chapter.new(start_ms: chapter.start_time, title: chapter.title)
            raise ArgumentError, "#{style} chapters must be strictly increasing" unless chapter.start_ms > previous
            previous = chapter.start_ms
            chapter
          end
          result.freeze
        end
      end

      # QuickTime限定除去の判定と、同一原本世代へ結び付いた編集計画。
      # `status: :removable`だけがremove_quicktime_chaptersへ渡せる。
      class QuickTimeChapterRemovalPlan
        attr_reader :status, :reason, :reason_code, :message, :operation, :issues, :references, :target_track_id,
                    :nero, :nero_status, :nero_chpl_sha256

        def initialize(status:, reason:, reason_code:, references:, target_track_id:, nero:, nero_status:,
                       nero_chpl_sha256:, source_path:, generation_token:, repair: nil, message: nil, operation: nil, issues: [])
          @status, @reason, @reason_code = status, reason, reason_code
          @message = (message || reason.to_s).dup.freeze
          @operation = operation
          @issues = DeepCopy.call(issues)
          @references = DeepCopy.call(references)
          @target_track_id = target_track_id
          @nero = DeepCopy.call(nero)
          @nero_status = nero_status
          @nero_chpl_sha256 = nero_chpl_sha256&.dup&.freeze
          @source_path = source_path.dup.freeze
          @generation_token = DeepCopy.call(generation_token)
          @repair = repair
          freeze
        end

        def removable?
          status == :removable
        end

        private

        attr_reader :source_path, :generation_token, :repair
      end

      # 欠落targetのchap参照だけを解除する、track削除を含まない計画。
      class DanglingChapterReferenceRemovalPlan
        attr_reader :status, :reason, :reason_code, :message, :references, :issues

        def initialize(status:, reason:, reason_code:, message:, references:, issues:, source_path:, generation_token:, repair: nil)
          @status, @reason, @reason_code = status, reason, reason_code
          @message = message.dup.freeze
          @references = DeepCopy.call(references)
          @issues = DeepCopy.call(issues)
          @source_path = source_path.dup.freeze
          @generation_token = DeepCopy.call(generation_token)
          @repair = repair
          freeze
        end

        def repairable?
          status == :repairable
        end

        private

        attr_reader :source_path, :generation_token, :repair
      end

      # 原本世代と編集候補だけを所有する。native handleは操作ごとに破棄する。
      class File
        attr_reader :path

        def initialize(path, verification: :stat)
          raise ArgumentError, 'verification must be :stat or :sha256' unless %i[stat sha256].include?(verification)
          @path = stable_path(path).freeze
          @verification = verification
          @generation = Generation.new(@path, verification)
          @digest = @generation.digest
          @diagnostics = {}
          @closed = false
          @metadata_baseline = @metadata_candidate = nil
          @chapters_baseline = @chapters_candidate = nil
          @repair_plan = nil
          @repair_kind = nil
          @quicktime_removal_plan = nil
          @issued_dangling_plan = nil
        rescue SystemCallError => error
          raise Error.new(error.message, code: :open, phase: :read), cause: error
        end

        # 通常ファイルは原表記を保持し、symlinkだけtarget実体を確認してcanonical化する。
        def stable_path(path)
          expanded = ::File.expand_path(path)
          entry = ::File.lstat(expanded)
          return expanded unless entry.symlink?

          resolved = ::File.realpath(expanded)
          unless ::File.identical?(expanded, resolved)
            raise Error.new('path resolves to a different file', code: :path_conflict,
                            area: :source, phase: :read,
                            issues: [{ code: :path_conflict, message: 'symlink target identity differs',
                                       location: 'source/path', details: { requested: expanded, resolved: resolved } }])
          end
          resolved
        end
        private :stable_path

        def metadata
          ensure_current!
          ensure_no_repair!
          load_metadata
          @metadata_candidate
        end

        # 原本の選択したheader宣言だけを返し、sample解析や外部probeを起動しない。
        def info(sections: [:movie, :tracks])
          ensure_current!
          header_reader.snapshot(sections)
        rescue ::TagLib::MP4::MdtaSaveError => error
          raise Error.new(error.message, code: :malformed, area: :info, phase: :read), cause: error
        rescue IOError, SystemCallError => error
          raise Error.new(error.message, code: :io, area: :info, phase: :read), cause: error
        end

        # 保存済み原本のraw media sample境界。編集候補・ffmpeg時刻を反映しない。
        def sample_boundaries(track_id:, max_table_bytes: 8 * 1024 * 1024, max_table_entries: 1_000_000)
          [track_id, max_table_bytes, max_table_entries].each do |value|
            raise ArgumentError, 'track ID and table budgets must be positive Integers' unless value.is_a?(Integer) && value.positive?
          end
          ensure_current!
          SampleBoundaryReader.new(@path, @generation, max_table_bytes, max_table_entries).report(track_id)
        rescue ::TagLib::MP4::MdtaSaveError => error
          raise Error.new(error.message, code: :malformed, area: :sample_boundaries, phase: :read), cause: error
        rescue IOError, SystemCallError => error
          raise Error.new(error.message, code: :io, area: :sample_boundaries, phase: :read), cause: error
        end

        # metadata全体を検証済みsnapshotとして現在の編集候補へ置き換える。
        def metadata=(value)
          ensure_current!
          ensure_no_repair!
          raise ArgumentError, 'metadata must be TagLib::Plus::MP4::MetadataSnapshot' unless value.is_a?(MetadataSnapshot)
          validate_metadata_candidate!(value)
          @metadata_candidate = value
        end

        # chapterの完全読取を遅延し、候補は形式別に保持する。
        def chapters
          ensure_current!
          ensure_no_repair!
          load_chapters
          @chapters_candidate
        end

        # 指定形式だけを完全読取し、併存する別形式の異常で値を失わせない。
        # 不在はnil、存在する空chapterは凍結した空配列、異常はErrorで返す。
        def read_chapters(style:)
          style = style.to_sym if style.respond_to?(:to_sym)
          raise ArgumentError, 'style must be :nero or :quicktime' unless %i[nero quicktime].include?(style)

          ensure_current!
          ensure_no_repair!
          reader = @generation.cached_chapter_reader(false) || read_structure do |native|
            ::TagLib::MP4.send(:const_get, :ChapterReader, false).read(native)
          end
          result = reader.report.fetch(style)
          unless %i[complete absent].include?(result[:status])
            raise Error.new(result[:reason], code: result[:status], area: :chapters, phase: :read,
                            issues: [{ code: result[:reason_code] || result[:status],
                                       message: result[:reason], location: "chapters/#{style}",
                                       details: { format: style } }])
          end
          return nil if result[:status] == :absent

          public_chapters(reader.values.fetch(style))
        end

        # 指定形式だけを含む不変ChapterSnapshotを保存候補にする。
        def chapters=(value)
          ensure_current!
          ensure_no_repair!
          raise ArgumentError, 'chapters must be TagLib::Plus::MP4::ChapterSnapshot' unless value.is_a?(ChapterSnapshot)
          load_chapters
          @chapters_candidate = value
        end

        # 壊れたQuickTimeだけを削除できるか、保存前に不変計画として判定する。
        def plan_quicktime_chapter_removal
          ensure_current!
          ensure_repair_slot!
          plan = read_structure { |native| build_quicktime_removal_plan(native) }
          plan
        end

        # 欠落targetのchapだけを選び、通常字幕・media・実在targetを保持する計画を作る。
        def plan_dangling_chapter_reference_removal
          ensure_current!
          ensure_repair_slot!
          analysis = read_structure { |native| ::TagLib::MP4::ChapterReferences.new(native, removal: :missing) }
          references = analysis.removed
          issues = references.map do |row|
            { code: :missing_reference, message: 'chapter reference target is missing',
              location: 'moov/trak/tref/chap',
              details: row.slice(:source_track_id, :source_handler, :target_track_id,
                                 :target_exists, :tref_index, :reference_index) }
          end
          status = references.empty? ? :unchanged : :repairable
          reason = references.empty? ? :no_dangling_references : :missing_reference
          message = references.empty? ? 'no dangling chapter references' : 'chapter reference target is missing'
          issue_dangling_reference_plan(
            status: status, reason: reason, message: message,
            references: references, issues: issues, repair: analysis.repair_plan
          )
        rescue ::TagLib::MP4::ChapterReferenceError, Error => error
          raise if error.is_a?(Error) && error.phase != :read
          raise if error.respond_to?(:code) && %i[source_changed io open].include?(error.code)
          issue_dangling_reference_plan(
            status: :blocked, reason: error.code, message: error.message,
            issues: repair_error_issues(error, location: 'chapter_references', details: {})
          )
        end

        # 同じFile世代で発行した欠落参照計画だけを保存候補へ登録する。
        def remove_dangling_chapter_references(plan:)
          ensure_current!
          ensure_repair_slot!
          unless plan.is_a?(DanglingChapterReferenceRemovalPlan)
            raise ArgumentError, 'plan must be DanglingChapterReferenceRemovalPlan'
          end
          unless plan.__send__(:source_path) == @path && plan.__send__(:generation_token) == @generation.__send__(:token) &&
                 plan.equal?(@issued_dangling_plan)
            raise Error.new('dangling reference plan is stale', code: :source_changed, area: :chapter_references, phase: :prepare)
          end
          unless plan.repairable?
            raise Error.new("dangling chapter reference removal is blocked: #{plan.message}",
                            code: plan.reason_code, area: :chapter_references, phase: :prepare, issues: plan.issues)
          end
          @repair_plan = plan.__send__(:repair)
          @repair_kind = :chapter_references
          DeepCopy.call(plan.references)
        end

        # 同じFile世代から作られたremovable計画だけを編集へ登録する。
        def remove_quicktime_chapters(plan:)
          ensure_current!
          ensure_repair_slot!
          unless plan.is_a?(QuickTimeChapterRemovalPlan)
            raise ArgumentError, 'plan must be QuickTimeChapterRemovalPlan'
          end
          unless plan.removable?
            raise Error.new("QuickTime chapter removal is blocked: #{plan.message}", code: plan.reason,
                            area: :chapter_references, phase: :prepare,
                            issues: plan.issues.empty? ? [{ code: plan.reason_code, message: plan.message,
                                                            location: 'chapters/quicktime', details: {} }] : plan.issues)
          end
          unless plan.__send__(:repair).is_a?(::TagLib::MP4::ChapterReferenceRepair)
            raise Error.new('QuickTime chapter removal plan is incomplete', code: :invalid_plan,
                            area: :chapter_references, phase: :prepare)
          end
          unless plan.__send__(:source_path) == @path && plan.__send__(:generation_token) == @generation.__send__(:token)
            raise Error.new('chapter removal plan is stale', code: :source_changed,
                            area: :chapter_references, phase: :prepare)
          end

          @repair_plan = plan.__send__(:repair)
          @repair_kind = :quicktime_chapter_removal
          @quicktime_removal_plan = plan
          DeepCopy.call(plan.references)
        end

        # 原本と候補の差分を保存可能性とは分けて表示する。
        def changes
          ensure_current!
          metadata_changed = metadata_changed?
          chapters_changed = chapters_changed?
          DeepCopy.call(metadata: metadata_changed ? [{ area: :metadata }] : [],
                        chapters: chapters_changed ? [{ area: :chapters }] : [],
                        repair: @repair_kind,
                        changed: !!@repair_plan || metadata_changed || chapters_changed)
        end

        # 保存済み原本の一領域だけを固定schemaで診断する。
        def diagnose(area)
          ensure_current!
          raise ArgumentError, "unknown diagnostic area: #{area.inspect}" unless DIAGNOSTIC_OPERATIONS.key?(area)

          return @diagnostics[area] if @diagnostics.key?(area)
          if area == :chapters && (reader = @generation.cached_chapter_reader(false))
            return @diagnostics[area] = diagnostic_report(area, reader.report)
          end
          if area == :structure
            return @diagnostics[area] = ::TagLib::Plus::MP4::StructureDiagnostics.new(@path, @generation).report
          end
          operation = area == :metadata ? method(:read_native) : method(:read_structure)
          @diagnostics[area] = operation.call do |native|
            begin
              diagnostic_report(area, native.public_send(DIAGNOSTIC_OPERATIONS.fetch(area)))
            rescue *STRUCTURE_ERRORS => error
              raise if error.respond_to?(:code) && error.code == :source_changed

              diagnostic_failure(area, error)
            end
          end
        end

        def chapter_samples
          ensure_current!
          ensure_no_repair!
          raise Error.new('chapter samples are unavailable while chapters are edited', code: :pending_changes, area: :chapters) if chapters_changed?
          return @chapter_samples if @chapter_samples_loaded

          snapshot = read_structure { |native| native.chapter_sample_snapshot }
          fields = %i[track_id source_track_id media_timescale media_duration samples movie edit
                      preservation_signature ffprobe_comparison source_references signature_version]
          @chapter_samples = snapshot && DeepCopy.call(fields.to_h { |field| [field, snapshot.public_send(field)] })
          @chapter_samples_loaded = true
          @chapter_samples
        end

        # 診断行を再検証し、指定したchapter参照の解除だけを保留する。
        def detach_chapter_references(references:)
          ensure_current!
          ensure_repair_slot!
          raise ArgumentError, 'references must be an Array' unless references.is_a?(Array)
          plan, removed = read_structure do |native|
            analysis = ::TagLib::MP4::ChapterReferences.new(native, removal: references)
            [analysis.repair_plan, analysis.removed]
          end
          @repair_plan, @repair_kind = plan, :chapter_references if plan
          DeepCopy.call(removed)
        rescue ::TagLib::MP4::ChapterReferenceError => error
          raise Error.new(error.message, code: error.code, area: :chapter_references, phase: :prepare), cause: error
        rescue Error, ArgumentError
          raise
        rescue StandardError => error
          raise Error.new(error.message, code: :repair, area: :chapter_references, phase: :prepare), cause: error
        end

        # 既知profileに一致するchapter時間修復を保存待ちにする。
        def repair_chapter_timing(track_id:, profile:)
          ensure_current!
          ensure_repair_slot!
          raise ArgumentError, 'profile must be :taglib_full_movie' unless profile == :taglib_full_movie
          result, plan = read_native do |native|
            result = native.repair_native_chapter_timing(track_id: Integer(track_id), profile: profile)
            [result, native.instance_variable_get(:@chapter_timing_repair)]
          end
          if plan.nil? && result[:status] != :planned
            raise Error.new('chapter timing profile does not match', code: :profile_mismatch,
                            area: :chapter_timing, phase: :prepare)
          end
          @repair_plan, @repair_kind = plan, :chapter_timing if plan
          DeepCopy.call(result)
        rescue ::TagLib::MP4::ChapterReferenceError => error
          raise Error.new(error.message, code: error.code, area: :chapter_timing, phase: :prepare), cause: error
        rescue Error, ArgumentError
          raise
        rescue StandardError => error
          raise Error.new(error.message, code: :repair, area: :chapter_timing, phase: :prepare), cause: error
        end

        # 候補の検証・別handle再読込・media保持を終えてから一度だけ公開する。
        def save!(to: nil, snapshots: [])
          ensure_current!
          unless snapshots.is_a?(Array) && snapshots.uniq == snapshots && (snapshots - %i[metadata chapters]).empty?
            raise ArgumentError, 'snapshots must contain unique metadata/chapters symbols'
          end
          output = to.nil? ? @path : ::File.expand_path(to)
          replace_source = output == @path
          validate_output!(output, replace_source)
          if @repair_kind == :limited_repairs && replace_source
            raise Error.new('limited repair requires a separate output', code: :separate_output_required, phase: :prepare)
          end
          changed = changed?
          if !changed && replace_source
            actual = {}
            missing = snapshots.reject do |field|
              baseline = field == :metadata ? @metadata_baseline : @chapters_baseline
              actual[field] = baseline if baseline
            end
            actual.merge!(read_native { |native| capture_snapshots(native, missing) }) unless missing.empty?
            adopt_snapshots!(actual)
            return result(output, @digest, changed: false, snapshots: actual)
          end

          publication = Publication::State.new
          phase = :write
          source_digest = @digest
          temporary = nil
          temporary_path = nil
          temporary_identity = nil
          output_generation = nil
          begin
            @requested_snapshots = snapshots
            @publication_state = publication
            # cleanup失敗で残すpathをGCが後からunlinkしないよう、明示管理のFileを使う。
            temporary = Tempfile.create(['taglib-plus-', '.mp4'], ::File.dirname(output))
            temporary_path = temporary.path
            temporary.close
            temporary_identity = path_identity(temporary_path)
            @temporary_cleanup_identity = temporary_identity
            load_metadata if changed && @repair_kind != :limited_repairs
            @source_scan = nil
            prepare_candidate(temporary_path, changed: changed)
            source_digest = @source_scan.fetch(:digest)
            phase = :verify
            output_generation = Generation.new(temporary_path, :stat)
            @candidate_generation = output_generation
            @output_scan = Stream.scan(temporary_path)
            output_digest = @output_scan.fetch(:digest)
            baseline = if changed
                         verify_candidate(temporary_path)
                       elsif snapshots.any?
                         ::TagLib::MP4::Internal::File.open(temporary_path, false) do |native|
                           native.io_generation = output_generation
                           capture_snapshots(native, snapshots)
                         end
                       end
            raise IOError, 'copy verification failed' if !changed && output_digest != source_digest
            output_generation.check!
            ensure_generation!
            phase = :publish
            publish_candidate(temporary_path, output, replace_source: replace_source)
            phase = :adopt
            if replace_source && changed
              output_generation.__send__(:expect_publication_digest, output_digest)
              output_generation.publish_to(@path)
              @verified_generation = output_generation
              adopt_baseline!(baseline, output_digest)
            end
            phase = :result
            result(output, output_digest, changed: changed, source_digest: source_digest, snapshots: baseline || {})
          rescue StandardError => error
            publication_status = publication.status
            mark_publication_failure!(publication_status)
            raise Error.new(error.message, code: error.is_a?(Error) ? error.code : :save,
                            area: error.is_a?(Error) ? error.area : nil,
                            issues: save_error_issues(error, phase, publication),
                            phase: phase, committed: publication.committed,
                            publication_status: publication_status,
                            output_path: output, temporary_path: temporary_path), cause: error
          ensure
            failure = $!
            begin
              output_generation&.close unless output_generation.equal?(@generation)
              @verified_generation = nil
              @source_scan = @output_scan = @source_tracks = nil
              @rendered_nero = nil
              @requested_snapshots = nil
              @candidate_generation = nil
              @publication_state = nil
              cleanup_candidate(temporary) if temporary && publication.status != :unknown
            rescue StandardError => error
              mark_publication_failure!(publication.status)
              raise Error.new("temporary cleanup failed: #{error.message}", code: :cleanup,
                              phase: :cleanup, committed: publication.committed,
                              publication_status: publication.status, output_path: output,
                              temporary_path: temporary_path,
                              issues: [{ code: :cleanup_failed, message: error.message,
                                         details: { class: error.class.name } }]), cause: (failure || error)
            ensure
              @temporary_cleanup_identity = nil
            end
          end
        end

        def close
          @closed = true
          @generation&.close
          nil
        end

        private

        # 公開が確定または判定不能になった後は、同じセッションの再利用を止める。
        def mark_publication_failure!(status)
          return unless %i[committed unknown].include?(status)

          @unusable = true
          @publication_status = status
        end

        # publish phaseだけ、元例外を短い診断issueへ変換する。
        def save_error_issues(error, phase, publication)
          return error.issues if error.is_a?(Error)
          return [] unless phase == :publish

          [{ code: :publication_failed, message: error.message,
             details: { publication_method: publication.publication_method,
                        errno: error.respond_to?(:errno) ? error.errno : nil } }]
        end

        def public_chapters(values)
          values.map { |chapter| Chapter.new(start_ms: chapter.start_time, title: chapter.title) }.freeze
        end

        # 成功・拒否のどちらも同じ発行境界で原本世代と所有セッションへ結び付ける。
        def issue_dangling_reference_plan(status:, reason:, message:, references: [], issues: [], repair: nil)
          @issued_dangling_plan = DanglingChapterReferenceRemovalPlan.new(
            status: status, reason: reason, reason_code: reason, message: message,
            references: references, issues: issues, repair: repair,
            source_path: @path, generation_token: @generation.__send__(:token)
          )
        end

        def build_quicktime_removal_plan(native)
          reader = ::TagLib::MP4.send(:const_get, :ChapterReader, false).read(native)
          @diagnostics[:chapters] ||= diagnostic_report(:chapters, reader.report)
          nero = reader.report.fetch(:nero)
          quicktime = reader.report.fetch(:quicktime)
          nero_values = nero[:status] == :complete ? public_chapters(reader.values.fetch(:nero)) : [].freeze
          common = { references: [], target_track_id: nil, nero: nero_values, nero_status: nero[:status],
                     nero_chpl_sha256: reader.nero_payload_sha256,
                     source_path: @path, generation_token: @generation.__send__(:token) }

          unless %i[complete absent].include?(nero[:status])
            return QuickTimeChapterRemovalPlan.new(**common, status: :blocked, reason: :nero_unreadable,
              reason_code: nero[:reason_code] || nero[:status], message: nero[:reason] || 'Nero chapter read is incomplete',
              issues: [{ code: nero[:reason_code] || nero[:status], message: nero[:reason] || 'Nero chapter read is incomplete',
                         location: 'chapters/nero', details: {} }])
          end
          return QuickTimeChapterRemovalPlan.new(**common, status: :absent, reason: :quicktime_absent,
            reason_code: :quicktime_absent) if quicktime[:status] == :absent
          begin
            analysis = ::TagLib::MP4::QuickTimeChapterRemovalReferences.new(native, chapter_report: reader.report)
            cache_reference_diagnostics(analysis)
            timing_broken = quicktime[:status] == :complete && analysis.timing_report.any? { |row| row[:observations].any? }
            QuickTimeChapterRemovalPlan.new(
              **common.merge(references: analysis.removed, target_track_id: analysis.target_track_id),
              status: :removable, reason: timing_broken ? :quicktime_time_mismatch : :quicktime_broken,
              reason_code: timing_broken ? :quicktime_time_mismatch : (quicktime[:reason_code] || quicktime[:status]),
              repair: analysis.repair_plan
            )
          rescue ::TagLib::MP4::ChapterReferenceError => error
            if error.code == :quicktime_complete
              return QuickTimeChapterRemovalPlan.new(**common, status: :complete, reason: :quicktime_complete,
                reason_code: :quicktime_complete)
            end
            QuickTimeChapterRemovalPlan.new(**common, status: :blocked, reason: error.code,
              reason_code: error.code, message: error.message,
              issues: repair_error_issues(error, location: 'chapters/quicktime', details: {}))
          end
        end

        # 修復計画のために解析済みの原本観測を、同一世代の診断でも共有する。
        def cache_reference_diagnostics(analysis)
          @diagnostics[:chapter_references] ||= diagnostic_report(:chapter_references, analysis.report)
          @diagnostics[:chapter_timing] ||= diagnostic_report(:chapter_timing, analysis.timing_report)
        end

        def header_reader
          @header_reader ||= HeaderReader.new(@path, @generation)
        end

        # 世代確認と例外契約を、native値読取とRuby構造読取で共用する。
        def read_checked
          ensure_generation!
          value = yield
          ensure_generation!
          value
        rescue *STRUCTURE_ERRORS => error
          raise Error.new(error.message, code: error.code, phase: :read,
                          issues: error.respond_to?(:issues) ? error.issues : []), cause: error
        rescue IOError, SystemCallError => error
          raise Error.new(error.message, code: :io, phase: :read), cause: error
        end

        def read_native
          read_checked do
            ::TagLib::MP4::Internal::File.open(@path, false) do |native|
              native.io_generation = @generation
              yield native
            end
          end
        end

        # raw構造だけで完結する操作で、nativeによるmetadata・画像読込を避ける。
        def read_structure
          read_checked { yield header_reader }
        end

        def ensure_generation!
          @generation.check!
        end

        # 全公開操作に共通するセッション状態と原本世代の検査。
        def ensure_current!
          raise Error.new('file is closed', code: :closed) if @closed
          if @unusable
            status = @publication_status || :committed
            code = status == :unknown ? :publication_unknown : :committed_failure
            raise Error.new('file is unusable after publication failure', code: code,
                            committed: status == :committed ? true : nil,
                            publication_status: status)
          end
          ensure_generation!
        end

        def ensure_no_repair!
          return unless @repair_plan

          raise Error.new('repair and snapshot edits cannot be mixed', code: :pending_changes)
        end

        def ensure_repair_slot!
          raise Error.new('repair and snapshot edits cannot be mixed', code: :pending_changes) if changed?
        end

        def load_chapters
          return if @chapters_baseline

          @chapters_baseline = ChapterSnapshot.__send__(:from_legacy, read_native(&:chapter_snapshot))
          @chapters_candidate = @chapters_baseline
        end

        def load_metadata
          return if @metadata_candidate

          @metadata_baseline = MetadataSnapshot.__send__(:from_legacy, read_native(&:metadata_snapshot))
          @metadata_candidate = @metadata_baseline
        end

        def changed?
          !!@repair_plan || metadata_changed? || chapters_changed?
        end

        def metadata_changed?
          @metadata_candidate != @metadata_baseline
        end

        def chapters_changed?
          @chapters_candidate != @chapters_baseline
        end

        def nero_changed?
          chapters_changed? && @chapters_candidate.nero != @chapters_baseline.nero
        end

        def quicktime_changed?
          chapters_changed? && @chapters_candidate.quicktime != @chapters_baseline.quicktime
        end

        # 公開前の作業候補だけを編集する。原子的公開は外側のsave!が担当する。
        def write_candidate(path)
          ::TagLib::MP4::Internal::File.open(path, false) do |native|
            if metadata_changed? && !generic_metadata_restore?
              native.restore_metadata_snapshot(@metadata_candidate.__send__(:to_legacy))
              raise IOError, 'native save failed' unless native.send(:save_without_chapter_state)
            end
            if chapters_changed?
              styles = @nero_in_candidate ? [:quicktime] : %i[nero quicktime]
              native.restore_chapter_snapshot(@chapters_candidate.__send__(:to_legacy), styles: styles)
              native.send(:apply_chapter_state_to, native)
              raise IOError, 'native chapter save failed' unless native.send(:_save_chapters)
            end
          end
        end

        # 候補全体の出力を一回に絞り、原本のSHAとmdat署名をその読取で取得する。
        def prepare_candidate(path, changed:)
          @nero_in_candidate = false
          if quicktime_changed?
            @source_tracks = read_native { |native| native.send(:chapter_media_signature, @path) }
          end
          if @repair_plan
            @repair_plan.write_copy(@path, path) do |source, destination, replacement|
              @source_scan = Stream.scan(source, destination: destination, replacement: replacement)
            end
          elsif changed && generic_metadata_restore?
            write_generic_metadata_copy(path)
          else
            @source_scan = Stream.scan(@path, destination: path)
          end
          ::File.chmod(::File.stat(@path).mode & 0o777, path)
          needs_native = !generic_metadata_restore? || (chapters_changed? && (!@nero_in_candidate || quicktime_changed?))
          write_candidate(path) if changed && !@repair_plan && needs_native
          ensure_generation!
        end

        def verify_candidate(path)
          ::TagLib::MP4::Internal::File.open(path, false) do |native|
            native.io_generation = @candidate_generation
            return verify_limited_repair(native) if @repair_kind == :limited_repairs
            actual = MetadataSnapshot.__send__(:from_legacy, native.metadata_snapshot)
            expected = metadata_verification_snapshot
            matches = actual == expected
            matches ||= actual.__send__(:to_legacy).same_values?(expected.__send__(:to_legacy)) if expected != @metadata_candidate
            raise IOError, 'metadata verification failed' unless matches
            raw_expected = expected.__send__(:to_legacy).purl_raw_digests
            unless raw_expected.empty? || actual.__send__(:to_legacy).purl_raw_digests == raw_expected
              raise IOError, 'purl raw verification failed'
            end
            if chapters_changed? || @requested_snapshots.include?(:chapters)
              chapters = ChapterSnapshot.__send__(:from_legacy, native.chapter_snapshot)
              raise IOError, 'chapter verification failed' if @chapters_candidate && chapters != @chapters_candidate
            end
            preserved = if quicktime_changed?
                          actual_tracks = native.send(:chapter_media_signature, path)
                          native.send(:media_tracks_preserved?, @source_tracks, actual_tracks)
                        else
                          @source_scan.fetch(:media) == @output_scan.fetch(:media)
                        end
            raise IOError, 'media verification failed' unless preserved
            if @repair_plan
              checked = ::TagLib::MP4::ChapterReferences.new(native)
              unless checked.report == @repair_plan.retained_report &&
                     checked.preservation_signature == @repair_plan.preservation_signature
                raise IOError, 'repair structure preservation verification failed'
              end
              verify_quicktime_removal(native, checked: checked) if @repair_kind == :quicktime_chapter_removal
              native.chapter_snapshot if @repair_kind == :chapter_timing
            end
            captured = { metadata: actual }
            captured[:chapters] = chapters if chapters
            captured
          end
        end

        # 除去後にQuickTime不在、Nero payload一致、対象track不在を独立再読込で確認する。
        def verify_quicktime_removal(native, checked:)
          reader = ::TagLib::MP4.send(:const_get, :ChapterReader, false).read(native)
          nero = reader.report.fetch(:nero)
          quicktime = reader.report.fetch(:quicktime)
          expected = @quicktime_removal_plan
          if expected.nero_status == :absent
            raise IOError, 'Nero absence verification failed' unless nero[:status] == :absent && reader.nero_payload_sha256.nil?
          else
            raise IOError, 'Nero verification failed' unless nero[:status] == :complete &&
              public_chapters(reader.values.fetch(:nero)) == expected.nero
            raise IOError, 'Nero chpl payload verification failed' unless reader.nero_payload_sha256 == expected.nero_chpl_sha256
          end
          raise IOError, 'QuickTime chapter verification failed' unless quicktime[:status] == :absent
          raise IOError, 'QuickTime track verification failed' if checked.track_ids.include?(expected.target_track_id)
        end

        # 呼出側が選択した値だけを実ファイルから取得し、期待値を返却結果へ混ぜない。
        def capture_snapshots(native, fields)
          fields.to_h do |field|
            value = field == :metadata ? MetadataSnapshot.__send__(:from_legacy, native.metadata_snapshot) :
              ChapterSnapshot.__send__(:from_legacy, native.chapter_snapshot)
            [field, value]
          end
        end

        # mdta contextではApple系通常itemが数値keyへ移るため、保存先の既存keyを
        # 保持した期待値を組み立てて検証する。対応表にないitemは正規化しない。
        def metadata_verification_snapshot
          if generic_metadata_restore?
            helper = ::TagLib::MP4.send(:const_get, :PurlSnapshot, false)
            return generic_expected_snapshot(@metadata_candidate, helper)
          end
          return @metadata_candidate unless @metadata_baseline

          candidate = @metadata_candidate.__send__(:to_legacy)
          baseline = @metadata_baseline.__send__(:to_legacy)

          helper = ::TagLib::MP4.send(:const_get, :PurlSnapshot, false)
          entries = helper.mdta_migration_items(candidate)
          return @metadata_candidate if entries.empty?

          contexts = baseline.source_structure[:contexts] || []
          mdta = contexts.find { |context| context[:handler] == 'mdta' }
          return @metadata_candidate unless contexts.size == 1 && mdta

          expected = if candidate.mdta.empty? && entries.length == candidate.items.length
                       helper.expected_mdta_snapshot(baseline, candidate, { keys: mdta[:keys] }, entries)
                     else
                       staged = helper.mdta_candidate_snapshot(candidate, baseline, entries: entries)
                       helper.expected_native_mdta_snapshot(staged, entries)
                     end
          MetadataSnapshot.__send__(:from_legacy, expected)
        end

        # 完全snapshot復元では保存先のmdtaをnativeの部分更新へ渡さず、contextを再構成する。
        def generic_metadata_restore?
          return false unless metadata_changed? && @metadata_candidate
          contexts = metadata_destination.fetch(:contexts)
          contexts.any? && contexts.all? { |context| %w[mdir mdta].include?(context[:handler]) }
        end

        # 完全置換に必要な構造だけを検査し、旧値・画像のhashやnative変換を行わない。
        def metadata_destination
          return @metadata_destination if @metadata_destination
          ensure_generation!
          helper = ::TagLib::MP4.const_get(:PurlSnapshot, false)
          target = helper.destination(@path, digest_items: false)
          unless target[:writable] || (target[:contexts].empty? && target[:issues].empty?)
            raise Error.new('destination metadata structure is unsupported', code: target[:code] || :metadata_context_unsupported,
              phase: :prepare, issues: target[:issues])
          end
          ensure_generation!
          @metadata_destination = DeepCopy.call(target)
        end

        # mdta保存先へ通常itemとmdtaを別contextとして一括配置する。
        def write_generic_metadata_copy(path)
          helper = ::TagLib::MP4.send(:const_get, :PurlSnapshot, false)
          target = metadata_destination
          context = target.fetch(:contexts).find { |row| %w[mdir mdta].include?(row[:handler]) }
          raise Error.new('destination metadata context is unsupported', code: :metadata_context_unsupported,
                          phase: :prepare) unless context
          mdta_raw = header_reader.metadata_template(context, 'mdta')
          mdir_items = metadata_items_for_mdir(@metadata_candidate)
          mdta_groups = metadata_groups_for_restore(@metadata_candidate, helper)
          staged_mdir = build_mdir_metadata(mdir_items, @metadata_candidate, path) if mdir_items.any? || nero_changed?
          desired_mdir = staged_mdir if mdir_items.any?
          desired_mdta = if mdta_groups.empty?
                           nil
                         else
                           render_mdta_snapshot(mdta_raw, mdta_groups)
                         end
          desired_mdir ||= empty_mdir_metadata(mdta_raw) if desired_mdta.nil?
          replacement = header_reader.metadata_container(desired_mdir, desired_mdta,
            replace_nero: @nero_in_candidate, nero: @rendered_nero)
          write_metadata_atoms(path, container_replacement: replacement, capture_raw: false)
        rescue ::TagLib::MP4::MetadataSnapshotError => error
          raise Error.new(error.message, code: error.code, phase: :prepare,
                          issues: error.respond_to?(:issues) ? error.issues : []), cause: error
        rescue ::TagLib::MP4::ChapterReferenceError => error
          raise Error.new(error.message, code: error.code, phase: :prepare,
                          issues: repair_error_issues(error, path: 'movie')), cause: error
        end

        # mdta保存先を一時的にmdirへ変換し、nativeの型変換を利用して通常itemを生成する。
        def build_mdir_metadata(items, snapshot, path)
          helper = ::TagLib::MP4.send(:const_get, :PurlSnapshot, false)
          target = metadata_destination
          context = target.fetch(:contexts).find { |row| row[:handler] == 'mdir' } || target.fetch(:contexts).first
          template = header_reader.metadata_template(context, 'mdir')
          helper.metadata_only(template, directory: ::File.dirname(path)) do |staging|
            ::TagLib::MP4::Internal::File.open(staging, false) do |native|
              source_legacy = snapshot.__send__(:to_legacy)
              legacy = ::TagLib::MP4::MetadataSnapshot.new(items: items.map { |item|
                [item.key, item.kind, item.atom_data_type, item.value]
              }, mdta: [], source_structure: source_legacy.source_structure,
                 format_version: source_legacy.format_version)
              native.restore_metadata_snapshot(legacy)
              raise IOError, 'native mdir staging save failed' unless native.send(:save_without_chapter_state)
            end
            if nero_changed?
              ::TagLib::MP4::Internal::File.open(staging, false) do |native|
                native.set_chapters(@chapters_candidate.nero.map { |chapter| chapter.__send__(:to_legacy) }, style: :nero)
                native.send(:apply_chapter_state_to, native)
                raise IOError, 'native Nero staging save failed' unless native.send(:_save_chapters)
              end
              root = helper.boxes(::File.binread(staging))
              movie = root.find { |type, _| type == 'moov' }.last
              udta = helper.boxes(movie, 8).find { |type, _| type == 'udta' }.last
              @rendered_nero = helper.boxes(udta, 8).find { |type, _| type == 'chpl' }&.last
              @nero_in_candidate = true
            end
            staged = helper.destination(staging, digest_items: false)
            mdir = staged.fetch(:contexts).find { |row| row[:handler] == 'mdir' }
            raw = helper.read_meta(staging, mdir)
            purl = snapshot.__send__(:to_legacy).source_structure[:purl_raw]&.first
            raw = helper.replace_raw(raw, purl.fetch(:raw)) if purl && items.any? { |item| item.key == 'purl' }
            raw
          end
        rescue ::TagLib::MP4::MetadataSnapshotError
          raise
        rescue StandardError => error
          raise Error.new("cannot build mdir metadata: #{error.class}: #{error.message}", code: :metadata_context_unsupported,
                          phase: :prepare), cause: error
        end

        # 原本を短時間だけ開き、検証済みatom計画を作業コピーへ適用する。
        def write_metadata_atoms(destination, **transforms)
          editor_class = ::TagLib::MP4.send(:const_get, :MP4AtomEditor, false)
          editor = editor_class.new(header_reader, **transforms)
          editor.atom_plan.write_copy(@path, destination) do |source, output, replacement|
            @source_scan = Stream.scan(source, destination: output, replacement: replacement)
          end
        end

        # purlはlocaleを保持するためmdta側へ配置し、その他の通常itemをmdirへ残す。
        def metadata_items_for_mdir(snapshot)
          restore_purl_to_mdta? ? snapshot.items.reject { |item| item.key == 'purl' } : snapshot.items
        end

        # mdir単独の復元ではraw purlをそのまま保持し、mdta経路だけ型付き値へ移す。
        def restore_purl_to_mdta?
          contexts = metadata_destination.fetch(:contexts)
          @metadata_candidate.mdta.any? || contexts.any? { |context| context[:handler] == 'mdta' }
        end

        def metadata_groups_for_restore(snapshot, helper)
          groups = snapshot.mdta.transform_values(&:dup)
          purl = snapshot.items.find { |item| item.key == 'purl' }
          return groups unless purl && restore_purl_to_mdta?

          if groups.key?('purl')
            raise Error.new('ordinary and mdta purl cannot be merged safely', code: :metadata_context_conflict,
                            phase: :prepare,
                            issues: [{ code: :metadata_context_conflict, path: 'metadata/purl',
                                       message: 'snapshot contains both ordinary and mdta purl' }])
          end

          raw = snapshot.__send__(:to_legacy).source_structure[:purl_raw]&.first&.fetch(:raw)
          raise Error.new('purl raw bytes are required for mdta restoration', code: :purl_raw_missing,
                          phase: :prepare,
                          issues: [{ code: :purl_raw_missing, path: 'metadata/items/purl',
                                     message: 'snapshot does not contain raw purl bytes' }]) unless raw
          values = helper.value_rows(raw).map { |type, locale, data| MdtaValue.new(data_type: type, locale: locale, data: data) }
          groups['purl'] = values
          groups
        end

        # 保存構造上のpurl移動だけを反映した、独立再読込との比較用snapshotを作る。
        def generic_expected_snapshot(snapshot, helper)
          purl = snapshot.items.find { |item| item.key == 'purl' }
          return snapshot unless purl && restore_purl_to_mdta?
          groups = metadata_groups_for_restore(snapshot, helper)
          rows = snapshot.items.reject { |item| item.key == 'purl' }.map do |item|
            [item.key, item.kind, item.atom_data_type, item.value]
          end
          mdta = groups.map.with_index { |(key, values), index| [key, index + 1, values.map { |v| [v.data_type, v.locale, v.data] }] }
          legacy = ::TagLib::MP4::MetadataSnapshot.new(items: rows, mdta: mdta,
            source_structure: snapshot.__send__(:to_legacy).source_structure)
          MetadataSnapshot.__send__(:from_legacy, legacy)
        end

        # mdtaの既存atomをnative staging用の空mdir contextへ変換する。
        def convert_mdta_to_mdir(raw, helper)
          children = helper.boxes(raw, 12).reject { |type, _bytes| type == 'keys' }
          children = children.map do |type, bytes|
            if type == 'hdlr'
              bytes = bytes.dup
              bytes[16, 4] = 'mdir'
            elsif type == 'ilst'
              bytes = helper.box('ilst', ''.b)
            end
            [type, bytes]
          end
          helper.box('meta', raw.byteslice(8, 4) + children.map(&:last).join.b)
        end

        # keysとilstを同じ候補値から再構成し、空keyはkeysだけ保持する。
        def render_mdta_snapshot(raw, groups)
          helper = ::TagLib::MP4.send(:const_get, :PurlSnapshot, false)
          children = helper.boxes(raw, 12)
          groups = groups.map.with_index { |(key, values), index| [key, index + 1, values.map { |v| [v.data_type, v.locale, v.data] }] }
          keys = groups.map(&:first)
          keys_bytes = keys.map { |key| helper.box('mdta', key.encode(Encoding::UTF_8).b) }.join.b
          keys_atom = helper.box('keys', [0, keys.length].pack('N2') + keys_bytes)
          ilst = groups.each_with_index.filter_map do |(_key, _index, values), index|
            next if values.empty?
            data = values.map { |type, locale, bytes| helper.box('data', [type, locale].pack('N2') + bytes.b) }.join.b
            helper.box([index + 1].pack('N'), data)
          end.join.b
          ilst_atom = helper.box('ilst', ilst)
          payload = children.map do |type, bytes|
            type == 'keys' ? keys_atom : type == 'ilst' ? ilst_atom : bytes
          end.join.b
          helper.box('meta', raw.byteslice(8, 4) + payload)
        rescue StandardError => error
          raise Error.new("cannot render mdta metadata: #{error.message}", code: :metadata_context_unsupported,
                          phase: :prepare), cause: error
        end

        def empty_mdir_metadata(raw)
          convert_mdta_to_mdir(raw, ::TagLib::MP4.send(:const_get, :PurlSnapshot, false))
        end

        # 保存前に構造を再解析し、native保存へ原因が潰れる前に公開Errorへ変換する。
        def validate_metadata_candidate!(value)
          helper = ::TagLib::MP4.send(:const_get, :PurlSnapshot, false)
          legacy = value.__send__(:to_legacy)
          if legacy.items.assoc('purl') && (legacy.source_structure[:purl_raw] || []).empty?
            raise Error.new('purl raw bytes are required for restoration', code: :purl_raw_missing,
                            phase: :prepare,
                            issues: [{ code: :purl_raw_missing, path: 'metadata/items/purl',
                                       message: 'snapshot does not contain raw purl bytes' }])
          end
          helper.validate_raw!(legacy)
          metadata_destination
          ::TagLib::MP4::ChapterReferences.new(header_reader, ignore_metadata: true, capture_raw: false)
        rescue ::TagLib::MP4::MetadataSnapshotError => error
          raise Error.new(error.message, code: error.code, phase: :prepare,
                          issues: error.respond_to?(:issues) ? error.issues : []), cause: error
        rescue Error => error
          raise Error.new(error.message, code: error.code, area: error.area, phase: error.phase,
                          committed: error.committed,
                          issues: repair_error_issues(error, path: 'movie')), cause: error
        rescue ::TagLib::MP4::ChapterReferenceError => error
          raise Error.new(error.message, code: error.code, phase: :prepare,
                          issues: repair_error_issues(error, path: 'movie')), cause: error
        end

        # 別出力はlinkを優先し、非対応時だけ同じ候補を排他的renameする。
        def publish_candidate(temporary_path, output, replace_source:,
                             publication: (@publication_state || Publication::State.new))
          return publish_replacement(temporary_path, output, publication) if replace_source

          publish_separate_output(temporary_path, output, publication)
        end

        # 原本置換は通常renameだけを使い、成功が確認できるまで状態を確定しない。
        def publish_replacement(temporary_path, output, publication)
          publication.mark_method!(:replace)
          publication.unknown!
          ::File.rename(temporary_path, output)
          publication.committed!
        rescue SystemCallError => error
          publication.not_committed! if Publication::ExclusiveRename.definitive_error?(error)
          raise
        end

        # 別出力の候補を追加コピーせず、link非対応時だけ排他的renameへ切り替える。
        def publish_separate_output(temporary_path, output, publication)
          publication.unknown!
          publication.mark_method!(:link)
          link_candidate(temporary_path, output)
          publication.committed!
        rescue SystemCallError => error
          publication.not_committed! if Publication::ExclusiveRename.definitive_error?(error)
          raise unless Publication::ExclusiveRename.unsupported_link_error?(error)

          publication.not_committed!
          publication.mark_method!(:exclusive_rename)
          exclusive_rename_candidate(temporary_path, output, publication: publication, link_error: error)
        end

        def link_candidate(temporary_path, output)
          ::File.link(temporary_path, output)
        end

        def exclusive_rename_candidate(temporary_path, output, publication:, link_error:)
          Publication::ExclusiveRename.call(temporary_path, output, state: publication)
        rescue Publication::ExclusiveRename::Unsupported => error
          raise Error.new('exclusive rename is unavailable', code: :exclusive_publish_unsupported,
                          phase: :publish,
                          issues: [{ code: :exclusive_publish_unsupported, message: error.message,
                                     details: { publication_method: :exclusive_rename,
                                                link_error: link_error.class.name,
                                                link_errno: link_error.respond_to?(:errno) ? link_error.errno : nil,
                                                link_message: link_error.message } }]),
                cause: error
        end

        def cleanup_candidate(temporary)
          identity = @temporary_cleanup_identity
          unless identity
            raise Error.new('temporary candidate identity unavailable', code: :cleanup_collision,
                            area: :output, phase: :cleanup,
                            issues: [{ code: :cleanup_collision, message: 'temporary candidate identity unavailable',
                                       location: 'output/temporary' }])
          end
          current = path_identity(temporary.path)
          if current != identity
            raise Error.new('temporary candidate identity changed', code: :cleanup_collision,
                            area: :output, phase: :cleanup,
                            issues: [{ code: :cleanup_collision, message: 'temporary candidate identity changed',
                                       location: 'output/temporary', details: { expected: identity, actual: current } }])
          end
          ::File.unlink(temporary.path)
        rescue Errno::ENOENT
          # 原本へのrenameが成功した場合は、一時pathが既にない。
          nil
        end

        def validate_output!(output, replace_source)
          return if replace_source
          begin
            ::File.lstat(output)
          rescue Errno::ENOENT
            return
          rescue SystemCallError => error
            raise Error.new(error.message, code: :io, area: :output, phase: :prepare), cause: error
          end

          raise Error.new('output exists', code: :output_exists, output_path: output)
        end

        # cleanup対象の文字列表記を変換せず、作成時の実体だけを識別する。
        def path_identity(path)
          stat = ::File.lstat(path)
          [stat.dev, stat.ino]
        end

        # 公開前に独立再読込した値を採用し、公開後のnative読取を不要にする。
        def adopt_baseline!(baseline, output_digest)
          adopt_snapshots!(baseline)
          @chapters_baseline = @chapters_candidate = nil unless baseline.key?(:chapters)
          @repair_plan = @repair_kind = nil
          @quicktime_removal_plan = nil
          @limited_repair_plan = nil
          @issued_limited_plan = nil
          previous = @generation
          @generation = @verified_generation
          previous.close
          @digest = output_digest
          # 厳密モードの新世代は検証済み出力SHAを採用し、再走査を避ける。
          @generation.__send__(:adopt_digest, output_digest) if @verification == :sha256
          @diagnostics.clear
          @header_reader = nil
          @metadata_destination = nil
          @chapter_samples = nil
          @chapter_samples_loaded = false
        end

        # 実ファイルから取得した領域だけをgetterのcacheへ採用する。
        def adopt_snapshots!(baseline)
          @metadata_baseline = @metadata_candidate = baseline[:metadata] if baseline.key?(:metadata)
          @chapters_baseline = @chapters_candidate = baseline[:chapters] if baseline.key?(:chapters)
        end

        def result(output, output_digest, changed:, source_digest: @digest, snapshots: {})
          value = { output_path: output, changed: changed, source_digest: source_digest,
                    output_digest: output_digest, snapshots: snapshots,
                    verification: (!changed && output == @path ? @verification : :independent_reopen) }
          if @limited_repair_plan
            value.merge!(operations: @limited_repair_plan.required_operations,
              removed: { metadata: @limited_repair_plan.metadata[:removed] || [],
                         quicktime: @limited_repair_plan.quicktime }, committed: true)
          end
          DeepCopy.call(value)
        end

        # 領域固有の観測値と共通の拒否理由を分離し、旧診断オブジェクトを公開しない。
        def diagnostic_report(area, value)
          issues = []
          data = case area
                 when :metadata
                   issues = value.issues.map { |row| diagnostic_issue(row[:code], row[:message], row[:path], row.reject { |key, _| %i[code message path].include?(key) }) }
                   { structure: value.structure, capabilities: value.capabilities }
                 when :chapters
                   value.each do |style, row|
                     next if %i[complete absent].include?(row.fetch(:status))
                     issues << diagnostic_issue(row[:reason_code] || row[:status], row[:reason], "chapters/#{style}",
                                                format: style, status: row[:status])
                   end
                   { formats: value }
                 when :chapter_references then { references: value }
                 when :chapter_timing then { tracks: value }
                 when :color
                   entries = value.fetch(:entries)
                   issues = color_diagnostic_issues(entries)
                   { entries: entries }
                 end
          DeepCopy.call(status: diagnostic_status(issues), data: data, issues: issues)
        end

        # sample entryとcolrそれぞれの非対応・破損理由を、元の順序で公開issueへ変換する。
        def color_diagnostic_issues(entries)
          entries.each_with_object([]) do |entry, issues|
            if entry[:handler] == 'vide' && entry[:status] == :unsupported
              issues << diagnostic_issue(:unsupported, entry[:unsupported_reason].to_s,
                                         "color/#{entry[:sample_entry_offset]}")
            end
            entry.fetch(:colr).each do |color|
              next if color[:status] == :complete

              message = color[:unsupported_reason]&.to_s || color[:issues].join(', ')
              issues << diagnostic_issue(color[:status], message, "color/#{color[:offset]}", color)
            end
          end
        end

        # 全体statusは読取完了ではなく、各issueの理由と優先順位から決める。
        def diagnostic_status(issues)
          statuses = issues.map { |issue| issue[:code] }
          return :complete if statuses.empty?
          return :limit if statuses.include?(:limit)
          return :unsupported if statuses.all? { |code| code.to_s.include?('unsupported') }

          :malformed
        end

        def diagnostic_failure(area, error)
          status = %i[unsupported limit].include?(error.code) ? error.code : :malformed
          if area == :chapter_references
            structure = ::TagLib::Plus::MP4::StructureDiagnostics.new(@path, @generation).report
            unless structure[:issues].empty?
              issues = structure[:issues].map { |issue| issue.merge(location: 'chapter_references') }
              return DeepCopy.call(status: structure[:status], data: structure[:data], issues: issues)
            end
          end
          DeepCopy.call(status: status, data: nil,
                        issues: repair_error_issues(error, location: area.to_s, details: {}))
        end

        # 原因側の診断を保持し、診断がない場合だけ呼出箇所の情報を付ける。
        def repair_error_issues(error, **context)
          issues = error.respond_to?(:issues) ? error.issues : []
          return issues unless issues.empty?

          [{ code: error.code, message: error.message, **context }]
        end

        def diagnostic_issue(code, message, location, details = {})
          { code: code, message: message, location: location, details: details }
        end
      end

      # 通常はstat世代検査、厳密モードだけ各操作で内容SHAを照合する。
      def self.open(path, verification: :stat)
        file = File.new(path, verification: verification)
        return file unless block_given?

        begin
          yield file
        ensure
          file.close
        end
      end
    end
  end
end

require_relative 'plus_mp4_limited_repair'
