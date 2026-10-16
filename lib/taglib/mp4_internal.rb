# frozen_string_literal: true

module TagLib::MP4
  # Plusのwriterと構造テストだけが利用する実装層。公開APIの互換性は保証しない。
  module Internal
    FILE_OPERATIONS = %i[
      apply_metadata_update chapter_diagnostics chapter_reference_diagnostics
      chapter_sample_snapshot chapter_snapshot chapter_style chapter_timing_diagnostics
      chapters color_metadata_diagnostics metadata_capabilities metadata_context_diagnostics
      metadata_diagnostics metadata_snapshot nero_chapters quicktime_chapters
      remove_chapter_references remove_chapters remove_dangling_chapter_references
      remove_nero_chapters remove_quicktime_chapters repair_native_chapter_timing
      restore_chapter_snapshot restore_metadata_snapshot save_chapters
      save_preserving_unindexed_mdta set_chapters set_nero_chapters set_quicktime_chapters
    ].freeze
    TAG_OPERATIONS = %i[
      apply_metadata_update artwork mdta_item mdta_items mdta_status metadata_capabilities
      metadata_diagnostics metadata_snapshot properties property property_update_effects
      property_values remove_artwork remove_mdta_item remove_property replace_mdta_items
      restore_metadata_snapshot set_artwork set_mdta_item set_properties set_property
    ].freeze

    # 内部Fileが返すTagだけに旧操作を許す。通常のFile#tagには追加しない。
    module TagAccess
      TAG_OPERATIONS.each do |operation|
        define_method(operation) do |*args, **keywords, &block|
          super(*args, **keywords, &block)
        end
      end
    end

    # native資源の所有・既存writerを再利用する内部専用File。
    class File < ::TagLib::MP4::File
      def tag
        super&.extend(TagAccess)
      end
    end
  end

  File.class_eval do
    private(*Internal::FILE_OPERATIONS)
    private :metadata_context_diagnostics_without_purl_target,
            :metadata_snapshot_without_purl_pair, :restore_metadata_snapshot_without_purl_pair,
            :save_without_purl_pair
  end
  Tag.class_eval do
    private(*Internal::TAG_OPERATIONS)
    private :metadata_capabilities_without_purl_raw, :metadata_snapshot_without_purl_raw,
            :restore_metadata_snapshot_without_purl_preflight
  end
  Internal::File.class_eval { public(*Internal::FILE_OPERATIONS) }
end
