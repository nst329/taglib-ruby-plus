# frozen_string_literal: true

module TagLib::MP4
  # setter・影響説明・期待snapshotで更新対象と文字列変換を共有する内部計画。
  class PropertyUpdatePlan
    attr_reader :items, :remove_mdta

    def initialize(properties)
      raise ArgumentError, 'properties must be a Hash' unless properties.is_a?(Hash)

      entries = {}
      properties.each do |name, value|
        canonical = self.class.canonical_name(name)
        raise ArgumentError, "duplicate MP4 property: #{canonical.inspect}" if entries.key?(canonical)

        target = self.class.targets(canonical)
        native = Item.from_string_list([self.class.text(canonical, value)])
        native.set_atom_data_type(1) if target[:atom].start_with?('----:')
        entries[canonical] = [target, [target[:atom], :string_list, native.atom_data_type, native._snapshot_strings]]
      end
      @items = MetadataSnapshot.copy(entries.values.map(&:last))
      @remove_mdta = MetadataSnapshot.copy(entries.values.flat_map { |target, _row| target[:remove_mdta] }.uniq)
      freeze
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
  private_constant :PropertyUpdatePlan
end
