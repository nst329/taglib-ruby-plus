# frozen_string_literal: true

module TagLib::MP4
  # setter・影響説明・期待snapshotで更新対象と文字列変換を共有する更新値。
  # nativeへ適用する処理は持たず、入力全体を検証した結果だけを所有する。
  class MetadataUpdate
    attr_reader :items, :remove_mdta

    def initialize(properties)
      raise ArgumentError, 'properties must be a Hash' unless properties.is_a?(Hash)

      entries = {}
      properties.each do |name, value|
        canonical = self.class.canonical_name(name)
        raise ArgumentError, "duplicate MP4 property: #{canonical.inspect}" if entries.key?(canonical)

        target = self.class.targets(canonical)
        text = self.class.text(canonical, value)
        # The update plan is native-independent. iTunes atoms use the native
        # text item type (255); reverse-DNS/freeform atoms use UTF-8 (1).
        atom_type = target[:atom].start_with?('----:') ? 1 : 255
        entries[canonical] = [target, [target[:atom], :string_list, atom_type, [text]]]
      end
      @items = MetadataSnapshot.copy(entries.values.map(&:last))
      @remove_mdta = MetadataSnapshot.copy(entries.values.flat_map { |target, _row| target[:remove_mdta] }.uniq)
      freeze
    end

    def self.properties(values)
      new(values)
    end

    # MetadataSnapshotへ同じ更新を適用する。Tagのnative編集とは分離する。
    def apply(snapshot)
      unless snapshot.is_a?(MetadataSnapshot)
        raise ArgumentError, 'expected MetadataSnapshot'
      end

      snapshot.without(mdta: remove_mdta).with(items: items)
    end

    def self.canonical_name(name)
      name = name.to_s
      name == 'show' ? 'TVShowName' : name
    end

    # 操作経路によって変わるatomとmdta除去を一箇所で解決する。
    def self.targets(name, via: :set_property)
      name = canonical_name(name)
      unless via == :set_property || (via == :native_setter && name == 'title')
        raise ArgumentError, "unsupported MP4 setter: #{via.inspect} for #{name.inspect}"
      end
      atom = Tag::PROPERTY_ATOMS.fetch(name) { raise ArgumentError, "unsupported MP4 property: #{name.inspect}" }
      { atom: atom, remove_mdta: via == :native_setter ? [] : [Tag::MDTA_PROPERTY_KEYS[name]].compact }
    end

    # 全経路でencoding・NUL・ContentRatingの同じ制約を使う。
    def self.text(name, value)
      if canonical_name(name) == Tag::CONTENT_RATING_PROPERTY
        raise ArgumentError, 'contentRating must be a TagLib::MP4::ContentRating' unless value.is_a?(ContentRating)

        return value.to_s
      end
      raise ArgumentError, "#{name} must be a String" unless value.is_a?(String)

      text = value.encode(Encoding::UTF_8)
      raise ArgumentError, "#{name} must be a UTF-8 String" unless text.valid_encoding?
      raise ArgumentError, "#{name} must not contain NUL bytes" if text.include?("\0")

      text
    end
  end

  # Internal callers are migrated incrementally; the public name is MetadataUpdate.
  PropertyUpdatePlan = MetadataUpdate
  private_constant :PropertyUpdatePlan
end
