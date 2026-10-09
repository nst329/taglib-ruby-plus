# frozen_string_literal: true

# Test-only prototype: validate the public contract without adding a production API.
module MP4SnapshotDesignProbe
  class Unsupported < StandardError; end
  READERS = %i[invalid bool int int_pair byte uint long_long string_list byte_vector_list cover_art_list].freeze

  # Capture detached logical values; atomDataType/keys-table completeness need native support.
  def self.capture(tag)
    items = tag.item_map.to_a.sort_by(&:first).map do |key, item|
      reader = READERS[item.type]
      raise Unsupported, "unsupported item type #{item.type}" if reader.nil? || reader == :invalid
      value = item.public_send("to_#{reader}")
      value = value.map { |art| [art.format, art.data] } if reader == :cover_art_list
      [key, reader, value]
    end
    detached({ items: items, mdta: tag.mdta_items.map { |v| [v.key, v.key_index, v.data_type, v.locale, v.data] } })
  end

  def self.detached(value)
    copy = case value
           when Hash then value.to_h { |k, v| [detached(k), detached(v)] }
           when Array then value.map { |v| detached(v) }
           when String then value.dup
           else value
           end
    copy.freeze
  end

  # Across files, compare key-local sequences; physical keys indices are not identities.
  def self.logical(snapshot)
    [snapshot.fetch(:items), snapshot.fetch(:mdta).group_by(&:first).transform_values { |rows| rows.map { |r| r.values_at(2, 3, 4) } }]
  end

  # Stage all edits in a detached native Tag and commit via existing state transfer once.
  # This tests reuse of copyStateTo; it is not a complete public restore implementation.
  def self.restore(file, snapshot, fail_after_key: nil)
    tag = file.tag
    # Existing grouped status requires a real ilst; a default-constructed Tag is unsupported.
    owner = TagLib::MP4::File.new(file.name, false)
    candidate = owner.tag
    tag._copy_state_to(candidate)
    candidate.item_map.clear
    snapshot.fetch(:items).each do |key, kind, value|
      payload = kind == :cover_art_list ? value.map { |format, bytes| TagLib::MP4::CoverArt.new(format, bytes) } : value
      candidate.item_map.insert(key, TagLib::MP4::Item.public_send("from_#{kind}", payload))
    end
    wanted = snapshot.fetch(:mdta).map(&:first).uniq
    (candidate.mdta_items.map(&:key).uniq - wanted).each { |key| candidate.remove_mdta_item(key) }
    snapshot.fetch(:mdta).group_by(&:first).each do |key, rows|
      candidate.replace_mdta_items(key, rows.map { |row| { data_type: row[2], locale: row[3], data: row[4] } })
      raise Unsupported, 'injected late candidate failure' if key == fail_after_key
    end
    candidate._copy_state_to(tag)
    tag
  ensure
    owner&.close
  end
end
