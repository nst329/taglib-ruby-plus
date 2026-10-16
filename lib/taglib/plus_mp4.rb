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
      STRUCTURE_ERRORS = [::TagLib::MP4::MetadataSnapshotError, ::TagLib::MP4::ChapterSnapshotError,
                          ::TagLib::MP4::ChapterReferenceError, ::TagLib::MP4::ColorMetadataError].freeze
      private_constant :STRUCTURE_ERRORS
      Artwork = ::TagLib::MP4::Artwork
      ContentRating = ::TagLib::MP4::ContentRating

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
          allocate.tap { |value| value.__send__(:initialize_legacy, snapshot) }
        end
        private_class_method :from_legacy

        # nativeを開かず、型付きitemとmdta値から復元用snapshotを構築する。
        def initialize(items: [], mdta: {})
          raise ArgumentError, 'items must be an Array of MetadataItem' unless items.is_a?(Array) && items.all? { |item| item.is_a?(MetadataItem) }
          raise ArgumentError, 'mdta must be a Hash' unless mdta.is_a?(Hash)

          @mdta = {}.freeze
          rows = items.map { |item| [item.key, item.kind, item.atom_data_type, item.value] }
          groups = normalize_mdta(mdta, keep_empty: true).each_with_index.map { |(key, values), index| [key, index + 1, values] }
          initialize_legacy(::TagLib::MP4::MetadataSnapshot.new(items: rows, mdta: groups))
        end

        def initialize_legacy(snapshot)
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
          normalized_properties.each { |name, value| rows = ::TagLib::MP4::MetadataUpdate.properties(PROPERTY_NAMES.fetch(name) => value).apply(rows) }
          rows = rows.with(items: normalized_items.values) unless normalized_items.empty?
          rows = rows.with(mdta: normalized_mdta) unless normalized_mdta.empty?
          self.class.__send__(:from_legacy, rows)
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
          self.class.__send__(:from_legacy, rows)
        end

        def ==(other)
          other.is_a?(self.class) && @legacy == other.__send__(:to_legacy)
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

      # 原本世代と編集候補だけを所有する。native handleは操作ごとに破棄する。
      class File
        attr_reader :path

        def initialize(path)
          @path = ::File.realpath(path).freeze
          @digest = digest
          @closed = false
          @metadata_baseline = @metadata_candidate = nil
          @chapters_baseline = @chapters_candidate = nil
          @repair_plan = nil
          @repair_kind = nil
        rescue SystemCallError => error
          raise Error.new(error.message, code: :open, phase: :read), cause: error
        end

        def metadata
          ensure_current!
          ensure_no_repair!
          load_metadata
          @metadata_candidate
        end

        # metadata全体を検証済みsnapshotとして現在の編集候補へ置き換える。
        def metadata=(value)
          ensure_current!
          ensure_no_repair!
          raise ArgumentError, 'metadata must be TagLib::Plus::MP4::MetadataSnapshot' unless value.is_a?(MetadataSnapshot)
          load_metadata
          @metadata_candidate = value
        end

        # chapterの完全読取を遅延し、候補は形式別に保持する。
        def chapters
          ensure_current!
          ensure_no_repair!
          load_chapters
          @chapters_candidate
        end

        # 指定形式だけを含む不変ChapterSnapshotを保存候補にする。
        def chapters=(value)
          ensure_current!
          ensure_no_repair!
          raise ArgumentError, 'chapters must be TagLib::Plus::MP4::ChapterSnapshot' unless value.is_a?(ChapterSnapshot)
          load_chapters
          @chapters_candidate = value
        end

        # 原本と候補の差分を保存可能性とは分けて表示する。
        def changes
          ensure_current!
          DeepCopy.call(metadata: metadata_changed? ? [{ area: :metadata }] : [],
                        chapters: chapters_changed? ? [{ area: :chapters }] : [],
                        repair: @repair_kind,
                        changed: changed?)
        end

        # 保存済み原本の一領域だけを固定schemaで診断する。
        def diagnose(area)
          ensure_current!
          operations = { metadata: :metadata_diagnostics, chapters: :chapter_diagnostics,
                         chapter_references: :chapter_reference_diagnostics,
                         chapter_timing: :chapter_timing_diagnostics, color: :color_metadata_diagnostics }
          raise ArgumentError, "unknown diagnostic area: #{area.inspect}" unless operations.key?(area)

          read_native do |native|
            begin
              diagnostic_report(area, native.public_send(operations.fetch(area)))
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

          snapshot = read_native { |native| native.chapter_sample_snapshot }
          return nil unless snapshot

          fields = %i[track_id source_track_id media_timescale media_duration samples movie edit
                      preservation_signature ffprobe_comparison source_references signature_version]
          DeepCopy.call(fields.to_h { |field| [field, snapshot.public_send(field)] })
        end

        # 診断行を再検証し、指定したchapter参照の解除だけを保留する。
        def detach_chapter_references(references:)
          ensure_current!
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
        def save!(to: nil)
          ensure_current!
          output = to.nil? ? @path : ::File.expand_path(to)
          replace_source = output == @path
          validate_output!(output, replace_source)
          changed = changed?
          return result(output, @digest, changed: false) if !changed && replace_source

          committed = false
          phase = :write
          source_digest = @digest
          temporary = nil
          temporary_path = nil
          begin
            temporary = Tempfile.new(['taglib-plus-', '.mp4'], ::File.dirname(output))
            temporary_path = temporary.path
            temporary.close
            load_metadata if changed
            prepare_candidate(temporary_path, changed: changed)
            phase = :verify
            baseline = verify_candidate(temporary_path) if changed
            output_digest = Digest::SHA256.file(temporary_path).hexdigest
            raise IOError, 'copy verification failed' if !changed && output_digest != source_digest
            ensure_generation!
            phase = :publish
            publish_candidate(temporary_path, output, replace_source: replace_source)
            committed = true
            phase = :adopt
            adopt_baseline!(baseline, output_digest) if replace_source
            phase = :result
            result(output, output_digest, changed: changed, source_digest: source_digest)
          rescue StandardError => error
            @unusable = true if committed
            raise Error.new(error.message, code: error.is_a?(Error) ? error.code : :save,
                            area: error.is_a?(Error) ? error.area : nil,
                            issues: error.is_a?(Error) ? error.issues : [],
                            phase: phase, committed: committed,
                            output_path: output, temporary_path: temporary_path), cause: error
          ensure
            failure = $!
            begin
              cleanup_candidate(temporary) if temporary
            rescue StandardError => error
              @unusable = true if committed
              raise Error.new("temporary cleanup failed: #{error.message}", code: :cleanup,
                              phase: :cleanup, committed: committed, output_path: output,
                              temporary_path: temporary_path), cause: (failure || error)
            end
          end
        end

        def close
          @closed = true
          nil
        end

        private

        def read_native
          ::TagLib::MP4::Internal::File.open(@path, false) { |native| yield native }
        rescue *STRUCTURE_ERRORS => error
          raise Error.new(error.message, code: error.code, phase: :read), cause: error
        rescue IOError, SystemCallError => error
          raise Error.new(error.message, code: :io, phase: :read), cause: error
        end

        def digest
          Digest::SHA256.file(@path).hexdigest
        end

        def ensure_generation!
          return if digest == @digest

          raise Error.new('source changed', code: :source_changed, phase: :prepare)
        end

        # 全公開操作に共通するセッション状態と原本世代の検査。
        def ensure_current!
          raise Error.new('file is closed', code: :closed) if @closed
          raise Error.new('file is unusable after publication failure', code: :committed_failure, committed: true) if @unusable
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
          return if @metadata_baseline

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

        def write_candidate(path)
          ::TagLib::MP4::Internal::File.open(path, false) do |native|
            native.restore_metadata_snapshot(@metadata_candidate.__send__(:to_legacy))
            native.restore_chapter_snapshot(@chapters_candidate.__send__(:to_legacy)) if @chapters_candidate
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
          ::TagLib::MP4::Internal::File.open(path, false) do |native|
            actual = MetadataSnapshot.__send__(:from_legacy, native.metadata_snapshot)
            raise IOError, 'metadata verification failed' unless actual == @metadata_candidate
            if @chapters_candidate
              chapters = ChapterSnapshot.__send__(:from_legacy, native.chapter_snapshot)
              raise IOError, 'chapter verification failed' unless chapters == @chapters_candidate
            end
            source_media = native.send(:mdat_payload_signature, @path)
            output_media = native.send(:mdat_payload_signature, path)
            raise IOError, 'media verification failed' unless source_media == output_media
            if @repair_plan
              checked = ::TagLib::MP4::ChapterReferences.new(native)
              unless checked.report == @repair_plan.retained_report &&
                     checked.preservation_signature == @repair_plan.preservation_signature
                raise IOError, 'repair structure preservation verification failed'
              end
              native.chapter_snapshot if @repair_kind == :chapter_timing
            end
            { metadata: actual, chapters: @chapters_candidate ? chapters : nil }
          end
        end

        # 別出力はlinkの排他的作成を使い、競合した既存ファイルを上書きしない。
        def publish_candidate(temporary_path, output, replace_source:)
          replace_source ? ::File.rename(temporary_path, output) : ::File.link(temporary_path, output)
        end

        def cleanup_candidate(temporary)
          temporary.unlink
        end

        def validate_output!(output, replace_source)
          return if replace_source
          raise Error.new('output exists', code: :output_exists, output_path: output) if ::File.exist?(output) || ::File.symlink?(output)
        end

        # 公開前に独立再読込した値を採用し、公開後のnative読取を不要にする。
        def adopt_baseline!(baseline, output_digest)
          @metadata_baseline = @metadata_candidate = baseline.fetch(:metadata)
          if @chapters_candidate
            @chapters_baseline = @chapters_candidate = baseline.fetch(:chapters)
          end
          @repair_plan = @repair_kind = nil
          @digest = output_digest
        end

        def result(output, output_digest, changed:, source_digest: @digest)
          DeepCopy.call(output_path: output, changed: changed, source_digest: source_digest,
                        output_digest: output_digest, verification: :independent_reopen)
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
                     issues << diagnostic_issue(row[:status], row[:reason], "chapters/#{style}")
                   end
                   { formats: value }
                 when :chapter_references then { references: value }
                 when :chapter_timing then { tracks: value }
                 when :color
                   value.fetch(:entries).each do |entry|
                     # colrごとのstatusも集約し、読取完了を全項目対応済みと誤認させない。
                     if entry[:handler] == 'vide' && entry[:status] == :unsupported
                       issues << diagnostic_issue(:unsupported, entry[:unsupported_reason].to_s,
                                                  "color/#{entry[:sample_entry_offset]}")
                     end
                     entry.fetch(:colr).each do |color|
                       next if color[:status] == :complete
                       message = color[:unsupported_reason]&.to_s || color[:issues].join(', ')
                       issues << diagnostic_issue(color[:status], message,
                                                  "color/#{color[:offset]}", color)
                     end
                   end
                   { entries: value.fetch(:entries) }
                 end
          statuses = issues.map { |issue| issue[:code] }
          status = if statuses.empty? then :complete
                   elsif statuses.include?(:limit) then :limit
                   elsif statuses.all? { |code| code.to_s.include?('unsupported') } then :unsupported
                   else :malformed
                   end
          DeepCopy.call(status: status, data: data, issues: issues)
        end

        def diagnostic_failure(area, error)
          status = %i[unsupported limit].include?(error.code) ? error.code : :malformed
          DeepCopy.call(status: status, data: nil,
                        issues: [diagnostic_issue(error.code, error.message, area.to_s)])
        end

        def diagnostic_issue(code, message, location, details = {})
          { code: code, message: message, location: location, details: details }
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
