# frozen_string_literal: true

require 'test/unit'
$LOAD_PATH.unshift(ENV.fetch('MDTA_BINDING_LIB', File.expand_path('../lib', __dir__)))
require 'taglib/base'
require 'taglib/mp4'

# 保存に依存しないsnapshot編集と論理差分の契約を検証する。
class MP4SnapshotEditDiffTest < Test::Unit::TestCase
  S = TagLib::MP4::MetadataSnapshot

  def snapshot
    S.new(items: [['desc', :string_list, 255, ['a', '', 'a']],
                  ['covr', :cover_art_list, 255, [[13, "\0\xff".b], [14, 'b'.b]]],
                  ['----:test:binary', :byte_vector_list, 8, ["\0\xff".b, ''.b, "\0\xff".b]]],
          mdta: [['gain', 5, [[1, 1041, 'a'.b], [33, 7, "\0\xff".b], [1, 1041, 'a'.b]]],
                 ['desc', 8, [[1, 0, 'mdta'.b]]], ['key-only', 9, []]], source_structure: { fixture: ['source'] })
  end

  def test_without_is_explicit_by_area_and_keeps_source_immutable
    original = snapshot
    edited = original.without(items: ['desc'], mdta: ['gain', 'missing'])
    assert_not_nil original.items.find { |row| row[0] == 'desc' }
    assert_nil edited.items.find { |row| row[0] == 'desc' }
    assert_nil edited.mdta.find { |row| row[0] == 'gain' }
    assert_not_nil edited.mdta.find { |row| row[0] == 'desc' }
    assert_equal original.source_structure, edited.source_structure
    assert edited.frozen?
    assert_raise(FrozenError) { edited.items.first.last.first << 'x' }
    assert original.structure_equal?(original.without)
  end

  def test_with_replaces_entire_sequences_and_allocates_indices_without_reordering
    original = snapshot
    bytes = "\xff\0".b
    edited = original.with(items: [['desc', :string_list, 255, ['new', 'new']]],
                           mdta: { 'gain' => [[33, 7, bytes], [33, 7, bytes]], 'new' => [[1, 0, 'x']] })
    bytes << 'caller edit'
    assert_equal ['a', '', 'a'], original.items.find { |r| r[0] == 'desc' }[3]
    assert_equal ['new', 'new'], edited.items.find { |r| r[0] == 'desc' }[3]
    assert_equal [5, 8, 9, 10], edited.mdta.map { |r| r[1] }
    assert_equal [[33, 7, "\xff\0".b]] * 2, edited.mdta.first[2]
    assert_equal Encoding::BINARY, edited.mdta.first[2].first[2].encoding
    assert original.structure_equal?(original.with)
  end

  def test_edits_reject_invalid_shapes_types_keys_duplicates_and_index_overflow
    original = snapshot
    [nil, {}, [nil], [''], ["bad\0key"], ['key'.b]].each do |keys|
      assert_raise(TagLib::MP4::MetadataSnapshotError) { original.without(items: keys) }
      assert_raise(TagLib::MP4::MetadataSnapshotError) { original.without(mdta: keys) }
    end
    [nil, {}, [['x', :string_list, 255, ['a']], ['x', :string_list, 255, ['b']]],
     [['x', :string_list, 255, ["\xff".b]]], [['x', :bool, 255, 0]]].each do |items|
      assert_raise(TagLib::MP4::MetadataSnapshotError) { original.with(items: items) }
    end
    [nil, [], { 'x' => [[-1, 0, 'a']] }, { 'x' => [[1, -1, 'a']] },
     { 'x' => [[1, 0, nil]] }, { 'x' => 'a' }, { '' => [] }].each do |mdta|
      assert_raise(TagLib::MP4::MetadataSnapshotError) { original.with(mdta: mdta) }
    end
    maximum = S.new(items: [], mdta: [['last', 0xffff_ffff, []]])
    assert_raise(TagLib::MP4::MetadataSnapshotError) { maximum.with(mdta: { 'new' => [] }) }
    assert maximum.logical_equal?(maximum.with(mdta: { 'last' => [[1, 0, 'ok']] }).without(mdta: ['last']))
  end

  def test_diff_ignores_indices_key_order_and_empty_keys_like_logical_equal
    original = snapshot
    actual = S.new(items: original.items.reverse, mdta: original.mdta.reverse.map { |k, i, v| [k, i + 100, v] },
                   source_structure: { different: true })
    assert original.logical_equal?(actual)
    assert_empty original.diff(actual)
    assert_equal false, original.structure_equal?(actual)
    assert_empty original.diff(actual.with(mdta: { 'another-empty' => [] }))
    assert_raise(TagLib::MP4::MetadataSnapshotError) { original.diff({}) }
  end

  def test_mdta_diff_explains_type_locale_count_value_and_order
    original = snapshot
    { data_type: [[2, 1041, 'a'.b], [33, 7, "\0\xff".b], [1, 1041, 'a'.b]],
      locale: [[1, 0, 'a'.b], [33, 7, "\0\xff".b], [1, 1041, 'a'.b]],
      value: [[1, 1041, 'changed'.b], [33, 7, "\0\xff".b], [1, 1041, 'a'.b]],
      value_count: original.mdta.first[2].first(2),
      order: original.mdta.first[2].rotate }.each do |field, values|
      actual = original.with(mdta: { 'gain' => values })
      diff = original.diff(actual)
      assert_equal [field], diff.first[:changes]
      assert_equal :changed, diff.first[:change]
      assert_equal :mdta, diff.first[:area]
      assert_equal 'gain', diff.first[:key]
      assert_equal false, original.logical_equal?(actual)
      assert_equal original.logical_equal?(actual), diff.empty?
    end
  end

  def test_item_diff_explains_kind_atom_type_image_format_and_duplicates
    original = snapshot
    samples = { atom_data_type: ['desc', :string_list, 1, ['a', '', 'a']],
                order: ['desc', :string_list, 255, ['', 'a', 'a']],
                value_count: ['desc', :string_list, 255, ['a', '']],
                image_format: ['covr', :cover_art_list, 255, [[14, "\0\xff".b], [14, 'b'.b]]] }
    samples.each do |field, item|
      assert_equal [field], original.diff(original.with(items: [item])).first[:changes]
    end
    assert_equal [:kind, :value], original.diff(original.with(items: [['desc', :int, 255, 5]])).first[:changes]
    assert_equal :removed, original.diff(original.without(items: ['desc'])).first[:change]
    assert_equal :added, original.without(items: ['desc']).diff(original).first[:change]
  end

  def test_diff_never_returns_raw_binary_and_limits_long_text
    original = snapshot
    actual = original.with(items: [['----:test:binary', :byte_vector_list, 8, ['different'.b]],
                                    ['desc', :string_list, 255, ['あ' * 200]]],
                           mdta: { 'gain' => [[1, 0, 'new'.b]] })
    diff = original.diff(actual)
    binary = diff.find { |row| row[:key] == '----:test:binary' }[:before][:payload].first
    assert_equal({ bytesize: 2, sha256: Digest::SHA256.hexdigest("\0\xff".b) }, binary)
    assert_kind_of Hash, diff.find { |row| row[:key] == 'desc' }[:after][:payload].first
    assert_equal 600, diff.find { |row| row[:key] == 'desc' }[:after][:payload].first[:bytesize]
    assert_kind_of Hash, diff.find { |row| row[:key] == 'gain' }[:before].first[:data]
    assert_raise(FrozenError) { diff.first[:changes] << :extra }
    assert_raise(FrozenError) { binary[:sha256] << 'x' }
  end

  def test_diff_empty_contract_covers_every_item_kind
    { bool: false, int: -1, int_pair: [1, 2], byte: 3, uint: 4, long_long: 5,
      string_list: ['a', 'a', ''], byte_vector_list: ['a'.b, ''.b], cover_art_list: [[13, 'a'.b]] }.each do |kind, payload|
      original = S.new(items: [['test', kind, 255, payload]], mdta: [])
      [original, original.without(items: ['test']), original.with(items: [['test', kind, 1, payload]])].each do |actual|
        assert_equal original.logical_equal?(actual), original.diff(actual).empty?
      end
    end
  end
end
