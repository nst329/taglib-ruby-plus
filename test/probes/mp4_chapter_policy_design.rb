# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'open3'
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'taglib_plus'
require_relative '../support/mp4_investigation_fixture'

# 設計probe。現行readerを実fixtureで観測し、選択・削除候補の仕様を試す。
# 製品の削除・保存処理の受入テストではない。
class ChapterPolicyDesignTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  # 形式間で異なるタイトルを持たせ、優先形式を値から独立に判別する。
  def setup
    @dir = Dir.mktmpdir('chapter-policy-design-')
    @path = File.join(@dir, 'source.m4a')
    _, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'sine=duration=1', '-c:a', 'aac', @path)
    assert status.success?, error
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      %i[nero quicktime].each do |style|
        file.set_chapters([TagLib::MP4::Chapter.new(0, style.to_s.encode(Encoding::UTF_8))], style: style)
      end
      assert file.save_chapters
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # 例: { quicktime: :complete, nero: :malformed } -> [:quicktime, [:nero]]。
  # 削除候補と安全に削除できる計画は別。unsupportedは破損と断定しない。
  def policy(statuses)
    selected = %i[quicktime nero].find { |style| statuses.fetch(style) == :complete }
    broken = %i[quicktime nero].select { |style| statuses.fetch(style) == :malformed }
    [selected, broken]
  end

  # 実readerの状態と選択後の公開値を照合し、読取が原本を書き換えないことも確認する。
  def observe
    before = File.binread(@path)
    report = TagLib::MP4::Internal::File.open(@path, false) { |file| file.chapter_diagnostics }
    statuses = report.transform_values { |row| row.fetch(:status) }
    selected, broken = policy(statuses)
    titles = selected && API.open(@path) { |file| file.read_chapters(style: selected).map(&:title) }
    assert_equal before, File.binread(@path)
    [selected, broken, titles]
  end

  def test_different_valid_formats_select_quicktime_and_keep_nero
    assert_equal [:quicktime, [], ['quicktime']], observe
  end

  def test_absent_quicktime_falls_back_to_nero
    TagLib::MP4::Internal::File.open(@path, false) do |file|
      file.remove_quicktime_chapters
      assert file.save_chapters
    end
    assert_equal [:nero, [], ['nero']], observe
  end

  def test_broken_nero_does_not_block_valid_quicktime_selection
    break_nero
    assert_equal [:quicktime, [:nero], ['quicktime']], observe
    API.open(@path) { |file| assert_equal :nero_unreadable, file.plan_quicktime_chapter_removal.reason }
  end

  def test_broken_nero_can_be_removed_while_quicktime_is_preserved
    break_nero
    output = File.join(@dir, 'nero-removed.m4a')
    API.open(@path) do |file|
      plan = file.plan_broken_chapter_removal
      assert_equal :removable, plan.status
      assert_equal [:nero], plan.remove_styles
      file.remove_broken_chapters(plan: plan)
      file.save!(to: output)
    end
    API.open(output) do |file|
      assert_equal :quicktime, file.select_chapters.style
      assert_equal ['quicktime'], file.select_chapters.chapters.map(&:title)
      assert_nil file.read_chapters(style: :nero)
    end
  end

  def test_broken_quicktime_falls_back_to_nero
    break_quicktime
    assert_equal [:nero, [:quicktime], ['nero']], observe
  end

  def test_both_broken_have_no_selection_and_both_are_deletion_candidates
    break_nero
    break_quicktime
    assert_equal [nil, %i[quicktime nero], nil], observe
  end

  def test_state_matrix_keeps_unsupported_separate_from_corruption
    %i[complete absent malformed unsupported].repeated_permutation(2) do |qt, nero|
      selected, broken = policy(quicktime: qt, nero: nero)
      expected = qt == :complete ? :quicktime : (nero == :complete ? :nero : nil)
      assert_equal expected, selected, [qt, nero].inspect
      assert_equal(qt == :malformed, broken.include?(:quicktime))
      assert_equal(nero == :malformed, broken.include?(:nero))
    end
  end

  private

  def break_nero
    edit_fixture(@path) do |moov|
      chpl = fixture_child(fixture_child(moov, 'udta'), 'chpl')
      chpl[:data] = chpl.fetch(:data).byteslice(0...-1)
    end
  end

  def break_quicktime
    edit_fixture(@path) do |moov|
      track = fixture_tracks(moov).find do |candidate|
        fixture_child(fixture_child(candidate, 'mdia'), 'hdlr').fetch(:data).byteslice(8, 4) == 'text'
      end
      stbl = fixture_child(fixture_child(fixture_child(track, 'mdia'), 'minf'), 'stbl')
      stts = fixture_child(stbl, 'stts')
      stts[:data] = stts.fetch(:data).byteslice(0...-1)
    end
  end
end
