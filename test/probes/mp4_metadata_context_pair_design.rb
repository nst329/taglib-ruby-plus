# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'taglib_plus'
require_relative '../support/mp4_investigation_fixture'

# 設計probe。独立parserによる親識別と候補編集を試し、製品実装の完成とは区別する。
class MetadataContextPairDesignTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  def setup
    @dir = Dir.mktmpdir('context-pair-design-')
    @path = File.join(@dir, 'source.mp4')
    _, error, status = Open3.capture3('ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
      'sine=duration=1', '-c:a', 'aac', @path)
    assert status.success?, error
    API.open(@path) do |file|
      file.chapters = file.chapters.with(nero: [API::Chapter.new(start_ms: 0, title: 'Nero')])
      file.save!
    end
    inject_metadata(@path, keys: ['a'], indices: [1])
    edit_fixture(@path) do |moov|
      udta = fixture_child(moov, 'udta')
      mdta = fixture_child(udta, 'meta')
      # 通常titleはmdirへ移し、mdtaを純粋なindexed contextにする。
      title = fixture_child(mdta, 'ilst')[:children].pop
      handler = [0, 0].pack('N2') + 'mdir' + "\0".b * 13
      mdir = parse_boxes(atom_box('meta', [0].pack('N') + atom_box('hdlr', handler) +
        atom_box('free', 'padding') + atom_box('ilst', render_boxes([title])))).first
      mdta[:children] << { type: 'free', data: 'mdta-padding'.b }
      udta[:children].unshift(mdir)
    end
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def contexts(moov)
    rows = []
    each_fixture_atom([moov]) do |parent|
      parent.fetch(:children, []).each do |child|
        rows << [parent, child] if child[:type] == 'meta'
      end
    end
    rows
  end

  def handler(meta)
    fixture_child(meta, 'hdlr')[:data].byteslice(8, 4)
  end

  # 例: [[udta実体, mdir], [同じudta実体, mdta]]のみから修復対象を選ぶ。
  # 内容の完全検証は製品側へ統合予定で、このprobeの選択器だけでは安全性を保証しない。
  def select_pair(moov)
    rows = contexts(moov)
    raise ArgumentError, 'multiple_meta' unless rows.size == 2 &&
      rows.map { |_, meta| handler(meta) }.sort == %w[mdir mdta]
    parent = rows.first.first
    raise ArgumentError, 'multiple_meta' unless parent[:type] == 'udta' &&
      moov[:children].any? { |child| child.equal?(parent) } &&
      rows.all? { |row| row.first.equal?(parent) }
    rows.find { |_, meta| handler(meta) == 'mdta' }.last
  end

  def test_public_diagnosis_and_plan_agree_on_valid_pair
    API.open(@path) do |file|
      report = file.diagnose(:metadata)
      assert_equal :complete, report[:status]
      assert_equal [], report[:issues]
      plan = file.plan_limited_repairs
      assert_equal :unchanged, plan.status
      assert_equal :metadata_complete, plan.metadata[:reason_code]
    end
    moov = read_fixture_moov(@path).first
    assert_equal 'mdta', handler(select_pair(moov))
    fixture_child(moov, 'udta')[:children].reverse!
    assert_equal 'mdta', handler(select_pair(moov))
  end

  def test_different_udta_is_not_the_same_parent_despite_equal_paths
    edit_fixture(@path) do |moov|
      udta = fixture_child(moov, 'udta')
      mdta = udta[:children].find { |child| child[:type] == 'meta' && handler(child) == 'mdta' }
      udta[:children].delete(mdta)
      moov[:children] << { type: 'udta', children: [mdta] }
    end
    moov = read_fixture_moov(@path).first
    assert_raise(ArgumentError) { select_pair(moov) }
    reader = TagLib::MP4.const_get(:MetadataStructureReader, false)
    report = reader.read(@path, detailed: true)
    assert_equal 1, report[:structure][:contexts].map { |row| row[:path] }.uniq.size
    assert_include report[:issues].map { |row| row[:code] }, :multiple_meta
    assert_equal :blocked, API.open(@path) { |file| file.plan_limited_repairs.status }
  end

  def test_unsafe_context_sets_are_rejected
    original = read_fixture_moov(@path).first
    [%w[mdir mdir], %w[mdta mdta], %w[mdir mdta mdir], %w[mdir zzzz]].each do |handlers|
      moov = Marshal.load(Marshal.dump(original))
      udta = fixture_child(moov, 'udta')
      templates = contexts(moov).to_h { |_, meta| [handler(meta), meta] }
      udta[:children].reject! { |child| child[:type] == 'meta' }
      handlers.each do |type|
        meta = Marshal.load(Marshal.dump(templates.fetch(type, templates['mdir'])))
        fixture_child(meta, 'hdlr')[:data][8, 4] = type
        udta[:children] << meta
      end
      assert_raise(ArgumentError) { select_pair(moov) }
      edit_fixture(@path) { |root| root.replace(moov) }
      plan = API.open(@path) { |file| file.plan_limited_repairs }
      assert_equal :blocked, plan.status
      assert_equal :multiple_meta, plan.metadata[:reason_code]
    end
  end

  def test_structure_reader_detects_unknown_meta_children
    reader = TagLib::MP4.const_get(:MetadataStructureReader, false)
    edit_fixture(@path) do |moov|
      contexts(moov).each { |_, meta| meta[:children] << { type: 'zzzz', data: 'unknown'.b } }
    end
    after = reader.read(@path)[:issues]
    assert_equal 2, after.count { |row| row[:code] == :unsupported_child }
    # 集合の選択だけでは不十分。共通検証器には子atom検査も必要。
    assert_equal 'mdta', handler(select_pair(read_fixture_moov(@path).first))
  end

  # 独立候補でraw保持の成立を確認する。公開save!の修復受入試験ではない。
  def test_independent_candidate_preserves_both_orders_media_chapters_and_offsets
    [false, true].each do |reverse|
      source = File.join(@dir, "source-#{reverse}.mp4")
      FileUtils.cp(@path, source)
      edit_fixture(source) do |moov|
        fixture_child(moov, 'udta')[:children].reverse! if reverse
        mdta = select_pair(moov)
        fixture_child(mdta, 'ilst')[:children].unshift(*parse_boxes(
          atom_box([0].pack('N'), atom_box('data', [1, 0].pack('N2') + 'invalid'))))
      end
      original = File.binread(source)
      before = read_fixture_moov(source).first
      output = File.join(@dir, "output-#{reverse}.mp4")
      FileUtils.cp(source, output)
      edit_fixture(output) do |moov|
        mdta = select_pair(moov)
        fixture_child(mdta, 'ilst')[:children].reject! { |item| item[:type].unpack1('N').zero? }
      end
      after = read_fixture_moov(output).first
      expected = Marshal.load(Marshal.dump(before))
      fixture_child(select_pair(expected), 'ilst')[:children].shift
      assert_equal render_boxes([expected]), render_boxes([after])
      assert_equal original, File.binread(source)
      roots = [source, output].map { |path| parse_boxes(File.binread(path)) }
      assert_equal roots[0].select { |row| row[:type] == 'mdat' }, roots[1].select { |row| row[:type] == 'mdat' }
      API.open(output) do |file|
        report = file.diagnose(:metadata)
        assert_equal :complete, report[:status]
        assert_equal [], report[:issues]
        assert_equal ['Nero'], file.read_chapters(style: :nero).map(&:title)
        assert_equal :unchanged, file.plan_limited_repairs.status
      end
      _, error, status = Open3.capture3('ffmpeg', '-v', 'error', '-i', output, '-f', 'null', '-')
      assert status.success?, error
    end
  end
end
