# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tempfile'

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

      class Error < StandardError
        attr_reader :code, :area, :phase, :committed, :output_path, :temporary_path, :issues

        def initialize(message, code: nil, area: nil, phase: nil, committed: false,
                       output_path: nil, temporary_path: nil, issues: [])
          @code, @area, @phase = code, area, phase
          @committed, @output_path, @temporary_path = committed, output_path, temporary_path
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
                   when String then value.dup
                   when Symbol, Integer, Float, TrueClass, FalseClass, NilClass then value
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
          @data = data.dup.force_encoding(Encoding::BINARY).freeze
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

        def self.from_legacy(snapshot)
          new(snapshot)
        end

        def initialize(snapshot)
          unless snapshot.is_a?(::TagLib::MP4::MetadataSnapshot)
            raise ArgumentError, 'expected TagLib::MP4::MetadataSnapshot'
          end
          @legacy = snapshot
          @items = snapshot.items.map { |key, kind, type, value| MetadataItem.new(key: key, kind: kind, atom_data_type: type, value: value) }.freeze
          @mdta = snapshot.mdta.to_h do |key, _index, values|
            [key, values.map { |type, locale, data| MdtaValue.new(data_type: type, locale: locale, data: data) }.freeze]
          end.freeze
          freeze
        end

        def to_legacy
          @legacy
        end

        def item(key)
          items.find { |item| item.key == key.to_s }
        end

        def properties
          PROPERTY_NAMES.to_h do |public_name, native_name|
            item = item(::TagLib::MP4::Tag::PROPERTY_ATOMS.fetch(native_name))
            [public_name, item ? property_values(native_name, item) : mdta_property_values(native_name)]
          end
        end

        def artworks
          item = item('covr')
          return [].freeze unless item

          item.value.map { |format, data| ::TagLib::MP4::Artwork.new(format: format, data: data) }.freeze
        end

        # 指定した領域だけを全入力検証して置換し、元snapshotは変更しない。
        def with(properties: {}, items: {}, mdta: {})
          validate_hash!(properties, 'properties')
          validate_hash!(items, 'items')
          validate_hash!(mdta, 'mdta')
          rows = @legacy
          normalized_properties = normalize_properties(properties)
          normalized_items = normalize_items(items)
          normalized_mdta = normalize_mdta(mdta)
          normalized_properties.each { |name, value| rows = ::TagLib::MP4::MetadataUpdate.properties(name => value).apply(rows) }
          rows = rows.with(items: normalized_items.values) unless normalized_items.empty?
          rows = rows.with(mdta: normalized_mdta) unless normalized_mdta.empty?
          self.class.new(rows)
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
          self.class.new(rows)
        end

        def ==(other)
          other.is_a?(self.class) && @legacy == other.to_legacy
        end
        alias eql? ==

        def hash
          @legacy.hash
        end

        private

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

        def normalize_mdta(values)
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
            next if normalized.empty? && !@mdta.key?(key)
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
      end

      class ChapterSnapshot
        attr_reader :nero, :quicktime
        UNSET = Object.new.freeze

        def self.from_legacy(snapshot)
          new(nero: snapshot.nero, quicktime: snapshot.quicktime)
        end

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
          ::TagLib::MP4::ChapterSnapshot.new(nero: nero.map(&:to_legacy), quicktime: quicktime.map(&:to_legacy))
        end

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

      # 原本世代と編集候補だけを所有する。native handleは操作ごとに破棄する。
      class File
        attr_reader :path

        def initialize(path)
          @path = ::File.realpath(path).freeze
          @digest = digest
          @closed = false
          @metadata_baseline = read_native(&:metadata_snapshot)
          @metadata_candidate = MetadataSnapshot.from_legacy(@metadata_baseline)
          @chapters_baseline = nil
          @chapters_candidate = nil
          @repair_plan = nil
          @repair_kind = nil
        rescue SystemCallError => error
          raise Error.new(error.message, code: :open, phase: :read), cause: error
        end

        def metadata
          ensure_readable!
          ensure_generation!
          @metadata_candidate
        end

        # metadata全体を検証済みsnapshotとして現在の編集候補へ置き換える。
        def metadata=(value)
          ensure_editable!
          ensure_generation!
          ensure_no_repair!
          raise ArgumentError, 'metadata must be TagLib::Plus::MP4::MetadataSnapshot' unless value.is_a?(MetadataSnapshot)
          @metadata_candidate = value
        end

        # chapterの完全読取を遅延し、候補は形式別に保持する。
        def chapters
          ensure_editable!
          ensure_generation!
          ensure_no_repair!
          load_chapters
          @chapters_candidate
        end

        # 指定形式だけを含む不変ChapterSnapshotを保存候補にする。
        def chapters=(value)
          ensure_editable!
          ensure_generation!
          ensure_no_repair!
          raise ArgumentError, 'chapters must be TagLib::Plus::MP4::ChapterSnapshot' unless value.is_a?(ChapterSnapshot)
          load_chapters
          @chapters_candidate = value
        end

        # 原本と候補の差分を保存可能性とは分けて表示する。
        def changes
          ensure_readable!
          ensure_generation!
          DeepCopy.call(metadata: @metadata_baseline == @metadata_candidate.to_legacy ? [] : [{ area: :metadata }],
                        chapters: chapter_changes,
                        repair: @repair_kind,
                        changed: changed?)
        end

        # 保存済み原本の一領域だけを固定schemaで診断する。
        def diagnose(area)
          ensure_readable!
          ensure_generation!
          result = read_native do |native|
            case area.to_sym
            when :metadata then native.metadata_diagnostics
            when :chapters then native.chapter_diagnostics
            when :chapter_references then native.chapter_reference_diagnostics
            when :chapter_timing then native.chapter_timing_diagnostics
            when :color then native.color_metadata_diagnostics
            else raise ArgumentError, "unknown diagnostic area: #{area.inspect}"
            end
          end
          status = result.is_a?(Hash) ? result[:status] || result['status'] : (result.respond_to?(:status) ? result.status : :complete)
          issues = result.is_a?(Hash) ? (result[:issues] || result['issues'] || []) : (result.respond_to?(:issues) ? result.issues : [])
          DeepCopy.call(status: status || :complete,
                        data: diagnostic_data(result),
                        issues: issues)
        rescue ::TagLib::MP4::ChapterReferenceError => error
          raise Error.new(error.message, code: error.code, area: :chapter_references, phase: :read), cause: error
        rescue ArgumentError
          raise
        rescue StandardError => error
          raise Error.new(error.message, code: :diagnostic, area: area, phase: :read), cause: error
        end

        def chapter_samples
          ensure_readable!
          ensure_generation!
          raise Error.new('chapter samples are unavailable while chapters are edited', code: :pending_changes, area: :chapters) if @chapters_candidate && @chapters_candidate != @chapters_baseline

          read_native { |native| native.chapter_sample_snapshot }
        rescue Error
          raise
        rescue StandardError => error
          raise Error.new(error.message, code: :chapter_samples, phase: :read), cause: error
        end

        # 診断行を再検証し、指定したchapter参照の解除だけを保留する。
        def detach_chapter_references(references:)
          ensure_editable!
          ensure_generation!
          ensure_repair_slot!
          raise ArgumentError, 'references must be an Array' unless references.is_a?(Array)
          plan, removed = read_native do |native|
            analysis = ::TagLib::MP4::ChapterReferences.new(native, removal: references)
            [analysis.repair_plan, analysis.removed]
          end
          @repair_plan, @repair_kind = plan, :chapter_references if plan
          DeepCopy.call(removed)
        rescue ::TagLib::MP4::ChapterReferenceError => error
          raise Error.new(error.message, code: error.code, area: :chapter_references, phase: :prepare), cause: error
        rescue ArgumentError
          raise
        rescue StandardError => error
          raise Error.new(error.message, code: :repair, area: :chapter_references, phase: :prepare), cause: error
        end

        # 既知profileに一致するchapter時間修復を保存待ちにする。
        def repair_chapter_timing(track_id:, profile:)
          ensure_editable!
          ensure_generation!
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
        rescue ArgumentError
          raise
        rescue StandardError => error
          raise Error.new(error.message, code: :repair, area: :chapter_timing, phase: :prepare), cause: error
        end

        # 候補の検証・別handle再読込・media保持を終えてから一度だけ公開する。
        def save!(to: nil)
          ensure_editable!
          ensure_generation!
          output = to.nil? ? @path : ::File.expand_path(to)
          replace_source = output == @path
          validate_output!(output, replace_source)
          changed = !!changed?
          return result(output, @digest, changed: false) if !changed && replace_source

          temporary = Tempfile.new(['taglib-plus-', '.mp4'], ::File.dirname(output))
          temporary.close
          committed = false
          phase = :write
          source_digest = @digest
          begin
            prepare_candidate(temporary.path, changed: changed)
            phase = :verify
            if changed
              verify_candidate(temporary.path)
            elsif Digest::SHA256.file(temporary.path).hexdigest != source_digest
              raise IOError, 'copy verification failed'
            end
            ensure_generation!
            phase = :publish
            replace_source ? ::File.rename(temporary.path, output) : ::File.link(temporary.path, output)
            committed = true
            digest_after = Digest::SHA256.file(output).hexdigest
            adopt_baseline! if replace_source
            result(output, digest_after, changed: changed, source_digest: source_digest)
          rescue Error
            raise
          rescue StandardError => error
            @unusable = true if committed
            raise Error.new(error.message, code: :save, phase: phase, committed: committed,
                            output_path: output, temporary_path: temporary.path), cause: error
          ensure
            begin
              temporary.unlink if temporary.path && ::File.exist?(temporary.path)
            rescue StandardError => error
              raise Error.new("temporary cleanup failed: #{error.message}", code: :cleanup,
                              phase: :cleanup, committed: committed, output_path: output,
                              temporary_path: temporary.path), cause: ($! || error)
            end
          end
        end

        def close
          @closed = true
          nil
        end

        private

        def read_native
          ::TagLib::MP4::File.open(@path, false) { |native| yield native }
        end

        def digest
          Digest::SHA256.file(@path).hexdigest
        end

        def ensure_generation!
          return if digest == @digest

          raise Error.new('source changed', code: :source_changed, phase: :prepare)
        end

        def ensure_readable!
          raise Error.new('file is closed', code: :closed) if @closed
        end

        def ensure_editable!
          ensure_readable!
          raise Error.new('file is unusable after publication failure', code: :committed_failure) if @unusable
        end

        def ensure_no_repair!
          return unless @repair_plan

          raise Error.new('repair and snapshot edits cannot be mixed', code: :pending_changes)
        end

        def ensure_repair_slot!
          raise Error.new('repair and snapshot edits cannot be mixed', code: :pending_changes) if changed?
          raise Error.new('repair already planned', code: :pending_changes) if @repair_plan
        end

        def load_chapters
          return if @chapters_baseline

          @chapters_baseline = ChapterSnapshot.from_legacy(read_native(&:chapter_snapshot))
          @chapters_candidate = @chapters_baseline
        end

        def chapter_changes
          return [] unless @chapters_candidate
          return [] if @chapters_baseline == @chapters_candidate

          [{ area: :chapters }]
        end

        def changed?
          @repair_plan || @metadata_baseline != @metadata_candidate.to_legacy ||
            (@chapters_candidate && @chapters_baseline != @chapters_candidate)
        end

        def write_candidate(path)
          ::TagLib::MP4::File.open(path, false) do |native|
            native.restore_metadata_snapshot(@metadata_candidate.to_legacy)
            native.restore_chapter_snapshot(@chapters_candidate.to_legacy) if @chapters_candidate
            raise IOError, 'native save failed' unless native.save
          end
        end

        # 通常編集・raw修復・無変更コピーの候補生成だけを受け持つ。
        def prepare_candidate(path, changed:)
          if @repair_plan
            @repair_plan.write_copy(@path, path)
          else
            ::FileUtils.cp(@path, path)
            write_candidate(path) if changed
          end
        end

        def verify_candidate(path)
          ::TagLib::MP4::File.open(path, false) do |native|
            actual = MetadataSnapshot.from_legacy(native.metadata_snapshot)
            raise IOError, 'metadata verification failed' unless actual == @metadata_candidate
            if @chapters_candidate
              chapters = ChapterSnapshot.from_legacy(native.chapter_snapshot)
              raise IOError, 'chapter verification failed' unless chapters == @chapters_candidate
            end
            source_media = native.send(:mdat_payload_signature, @path)
            output_media = native.send(:mdat_payload_signature, path)
            raise IOError, 'media verification failed' unless source_media == output_media
            if @repair_plan
              report = ::TagLib::MP4::ChapterReferences.new(native).report
              if @repair_kind == :chapter_references && report != @repair_plan.retained_report
                raise IOError, 'reference verification failed'
              end
            end
          end
        end

        def validate_output!(output, replace_source)
          return if replace_source
          raise Error.new('output exists', code: :output_exists, output_path: output) if ::File.exist?(output) || ::File.symlink?(output)
        end

        def adopt_baseline!
          @metadata_baseline = read_native(&:metadata_snapshot)
          @metadata_candidate = MetadataSnapshot.from_legacy(@metadata_baseline)
          if @chapters_candidate
            @chapters_baseline = ChapterSnapshot.from_legacy(read_native(&:chapter_snapshot))
            @chapters_candidate = @chapters_baseline
          end
          @repair_plan = @repair_kind = nil
          @digest = digest
        end

        def result(output, output_digest, changed:, source_digest: @digest)
          DeepCopy.call(output_path: output, changed: changed, source_digest: source_digest,
                        output_digest: output_digest, verification: :independent_reopen)
        end

        def diagnostic_data(result)
          return result if result.is_a?(Hash)
          return { structure: result.structure, capabilities: result.capabilities } if result.respond_to?(:structure)

          result
        end
      end

      def self.open(path)
        file = File.new(path)
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
