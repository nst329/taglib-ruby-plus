# frozen_string_literal: true

require 'test/unit'
require 'tmpdir'
require 'open3'
require 'digest'
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'taglib/base'
require 'taglib/mp4'
require_relative 'support/mp4_investigation_fixture'
require_relative 'support/plus_api_design_probe'

# 前案Document/Update/SavePlanについて、adapterと実MP4で状態・保存契約を検証する。
class PlusAPIDesignProbeTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  P = PlusAPIDesignProbe
  L = TagLib::MP4

  def setup
    @dir = Dir.mktmpdir('plus-api-design-')
    @path = File.join(@dir, 'source.mp4')
    _, error, status = Open3.capture3(ENV.fetch('FFMPEG', 'ffmpeg'), '-v', 'error',
      '-f', 'lavfi', '-i', 'color=size=32x32:rate=10:duration=1',
      '-f', 'lavfi', '-i', 'sine=duration=1', '-c:v', 'mpeg4', '-c:a', 'aac',
      '-metadata', 'title=original', '-metadata', 'untouched=keep', '-movflags', '+faststart+use_metadata_tags', @path)
    assert status.success?, error
    L::Internal::File.open(@path, false) do |file|
      snapshot = file.metadata_snapshot.with(mdta: { 'empty-key' => [], 'binary' => [[33, 7, "\0\xff".b], [1, 1041, ''.b]] })
      file.restore_metadata_snapshot(snapshot)
      file.set_chapters(initial_chapters, style: :both)
      assert file.save
    end
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def initial_chapters
    [L::Chapter.new(0, '開始'), L::Chapter.new(500, '終わり')]
  end

  def digest(path = @path)
    Digest::SHA256.file(path).hexdigest
  end

  # 製品の保持signatureに頼らず、全mdat payloadとトラックIDを独立parserで比較する。
  def retained(path)
    roots = parse_boxes(File.binread(path))
    moov = roots.find { |atom| atom[:type] == 'moov' }
    [fixture_tracks(moov).map { |track| fixture_track_id(track) },
     roots.select { |atom| atom[:type] == 'mdat' }.map { |atom| Digest::SHA256.hexdigest(atom[:data]) }]
  end

  def title_update(value = '新しい題名')
    P::MetadataUpdate.properties(set: { title: value })
  end

  # faultとテスト本体の二つのblockを明示し、必ず元の保存処理へ戻す。
  def with_fault(method, fault, before: false)
    klass = P::SavePlan
    original = klass.instance_method(method)
    klass.define_method(method) do |*args, **keywords|
      fault.call(self, *args, **keywords) if before
      value = original.bind_call(self, *args, **keywords)
      fault.call(self, *args, **keywords) unless before
      value
    end
    klass.send(:private, method)
    yield
  ensure
    klass.define_method(method, original)
    klass.send(:private, method)
  end

  def test_plan_is_reviewable_and_does_not_change_document_or_disk
    before = digest
    P.open(@path) do |document|
      original = document.metadata
      plan = document.plan(metadata: title_update)
      assert_equal before, digest
      assert_equal original, document.metadata
      assert_equal true, plan.preview.fetch(:changed)
      assert_raise(FrozenError) { plan.preview[:changed] = false }
      expected = title_update.apply(original)
      assert_equal ['新しい題名'], expected.item('©nam').fetch(:value)
      assert_equal [], expected.mdta_values('title')
      assert_equal original.mdta_values('untouched'), expected.mdta_values('untouched')
    end
    assert_equal before, digest, 'ブロック終了で自動保存しない'
  end

  def test_commit_after_document_close_keeps_media_and_rejects_old_generation
    document = P.open(@path)
    original, media = document.metadata, retained(@path)
    plan = document.plan(metadata: title_update)
    document.close
    GC.start
    result = plan.commit!
    assert_equal true, result.fetch(:changed)
    assert_equal digest, result.fetch(:output_digest)
    assert_equal media, retained(@path)
    P.open(@path) do |read|
      actual = read.metadata
      assert_equal ['新しい題名'], actual.item('©nam').fetch(:value)
      assert_equal original.mdta_values('binary'), actual.mdta_values('binary')
      assert_equal [], actual.mdta_values('empty-key')
      assert_equal initial_chapters, read.chapters.quicktime
    end
    assert_raise(P::ClosedError) { document.metadata }
    assert_raise(P::SourceChangedError) { plan.commit! }
  end

  def test_open_document_does_not_silently_read_committed_generation
    P.open(@path) do |document|
      snapshot = document.metadata
      document.plan(metadata: title_update).commit!
      assert_nil snapshot.item('©nam')
      assert_raise(P::SourceChangedError) { document.metadata }
      assert_raise(P::SourceChangedError) { document.chapters }
    end
  end

  def test_foreign_edit_rejects_read_plan_and_commit
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      File.open(@path, 'ab') { |file| file.write(atom_box('free', ''.b)) }
      changed = digest
      assert_raise(P::SourceChangedError) { document.metadata }
      assert_raise(P::SourceChangedError) { document.plan(metadata: title_update) }
      assert_raise(P::SourceChangedError) { plan.commit! }
      assert_equal changed, digest
    end
  end

  def test_noop_commit_does_not_replace_file
    P.open(@path) do |document|
      inode, before = File.stat(@path).ino, digest
      plan = document.plan(metadata: P::MetadataUpdate.properties)
      assert_equal false, plan.preview.fetch(:changed)
      assert_equal false, plan.commit!.fetch(:changed)
      assert_equal inode, File.stat(@path).ino
      assert_equal before, digest
    end
  end

  def test_independent_updates_merge_but_normalization_side_effects_conflict
    P.open(@path) do |document|
      mdta = P::MetadataUpdate.mdta(set: { 'custom' => [{ data_type: 1, locale: 0, data: 'new'.b }] })
      merged = title_update.merge(mdta).apply(document.metadata)
      assert_equal ['新しい題名'], merged.item('©nam').fetch(:value)
      assert_equal 'new'.b, merged.mdta_values('custom').first.fetch(:data)
      shadow = P::MetadataUpdate.mdta(set: { 'title' => [{ data_type: 1, locale: 0, data: 'shadow'.b }] })
      assert_raise(P::PlanError) { title_update.merge(shadow) }
      assert_raise(P::PlanError) { shadow.merge(title_update) }
      assert_raise(P::PlanError) { title_update.merge(title_update) }
    end
  end

  def test_absence_clear_and_empty_payload_remain_distinct
    P.open(@path) do |document|
      source = document.metadata
      clear = P::MetadataUpdate.mdta(clear: ['binary', 'missing']).apply(source)
      assert_equal [], clear.mdta_values('binary')
      assert_nil clear.mdta_values('missing')
      payload = P::MetadataUpdate.mdta(set: { 'empty-key' => [{ data_type: 1, locale: 1041, data: ''.b }] }).apply(source)
      assert_equal [{ data_type: 1, locale: 1041, data: ''.b }], payload.mdta_values('empty-key')
      assert_raise(ArgumentError) { P::MetadataUpdate.mdta(set: { 'empty-key' => [] }) }
      assert_raise(ArgumentError) { P::MetadataUpdate.properties(set: { title: nil }) }
      assert_raise(ArgumentError) { P::MetadataUpdate.properties(set: { show: 'alias' }) }
      assert_raise(ArgumentError) { P::MetadataUpdate.properties(set: { title: '' }, remove: [:title]) }
    end
  end

  def test_late_invalid_property_does_not_change_source_or_saved_plan
    before = digest
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      assert_raise(ArgumentError) { P::MetadataUpdate.properties(set: { title: 'valid', artist: nil }) }
      assert_equal before, digest
      assert plan.commit!
    end
  end

  def test_nero_removal_preserves_omitted_quicktime_and_metadata
    P.open(@path) do |document|
      original, media = document.metadata, retained(@path)
      update = P::ChapterUpdate.new(nero: [])
      expected = update.apply(document.chapters)
      assert_equal [], expected.nero
      assert_equal initial_chapters, expected.quicktime
      document.plan(chapters: update).commit!
      P.open(@path) do |read|
        assert_equal expected, read.chapters
        assert_equal original, read.metadata
      end
      assert_equal media, retained(@path)
    end
  end

  def test_write_to_preserves_source_and_reopens_independently
    before, media = digest, retained(@path)
    output = File.join(@dir, 'output.mp4')
    P.open(@path) { |document| document.plan(metadata: title_update) }.write_to!(output)
    assert_equal before, digest
    assert_equal media, retained(output)
    P.open(output) { |read| assert_equal ['新しい題名'], read.metadata.item('©nam').fetch(:value) }
  end

  def test_write_to_refuses_existing_source_hardlink_and_symlink
    before = digest
    output, hardlink, symlink = %w[existing hardlink symlink].map { |name| File.join(@dir, name) }
    File.write(output, 'other owner')
    File.link(@path, hardlink)
    File.symlink(@path, symlink)
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      [@path, output, hardlink, symlink].each do |destination|
        assert_raise(P::SaveError) { plan.write_to!(destination) }
      end
    end
    assert_equal before, digest
    assert_equal 'other owner', File.read(output)
  end

  def test_output_created_at_publication_is_not_overwritten
    output = File.join(@dir, 'race.mp4')
    before = digest
    fault = proc { |_plan, _temporary, destination, **_options| File.write(destination, 'concurrent output') }
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      with_fault(:publish, fault, before: true) do
        error = assert_raise(P::SaveError) { plan.write_to!(output) }
        assert_equal :publish, error.phase
        assert_false error.committed
      end
    end
    assert_equal 'concurrent output', File.read(output)
    assert_equal before, digest
    assert_empty Dir.glob(File.join(@dir, 'plus-design-*'))
  end

  def test_damaged_media_fails_verification_and_plan_can_be_retried
    before = digest
    fault = proc do |_plan, path|
      data = File.binread(path)
      offset = data.index('mdat') + 4
      data.setbyte(offset, data.getbyte(offset) ^ 255)
      File.binwrite(path, data)
    end
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      with_fault(:write_candidate, fault) do
        error = assert_raise(P::SaveError) { plan.commit! }
        assert_equal :verify, error.phase
        assert_false error.committed
        assert_match(/media mismatch/, error.message)
      end
      assert_equal before, digest
      assert_empty Dir.glob(File.join(@dir, 'plus-design-*'))
      assert plan.commit!
    end
  end

  def test_loss_of_untouched_empty_key_is_not_hidden_by_same_values
    before = digest
    fault = proc do |_plan, path|
      data = File.binread(path)
      raise 'fixture empty key absent' unless data.include?('empty-key')
      File.binwrite(path, data.sub('empty-key', 'other-key'))
    end
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      with_fault(:write_candidate, fault) do
        error = assert_raise(P::SaveError) { plan.commit! }
        assert_match(/metadata mismatch/, error.message)
      end
    end
    assert_equal before, digest
  end

  def test_replace_snapshot_may_leave_only_explicitly_cleared_destination_keys
    source = P.open(@path, &:metadata)
    L::Internal::File.open(@path, false) do |file|
      file.tag.replace_mdta_items('destination-only', [{ data_type: 1, locale: 0, data: 'remove'.b }])
      assert file.save
    end
    P.open(@path) { |document| document.plan(metadata: P::MetadataUpdate.replace(source)) }.commit!
    P.open(@path) do |read|
      actual = read.metadata
      assert source.same_values?(actual)
      assert [nil, []].include?(actual.mdta_values('destination-only'))
      assert_equal source.mdta_values('binary'), actual.mdta_values('binary')
    end
  end

  def test_unknown_arguments_and_closed_document_are_explicitly_rejected
    document = P.open(@path)
    assert_raise(ArgumentError) { document.plan }
    assert_raise(ArgumentError) { document.plan(metadata: 'not an update') }
    assert_raise(ArgumentError) { document.plan(repair: Object.new) }
    assert_raise(ArgumentError) { P::ChapterUpdate.new(both: []) }
    document.close
    document.close
    assert_raise(P::ClosedError) { document.metadata }
    assert_raise(P::ClosedError) { document.plan(metadata: title_update) }
  end
  def test_empty_property_is_a_value_and_remove_is_explicit
    P.open(@path) do |document|
      empty = P::MetadataUpdate.properties(set: { title: '' })
      assert_equal [''], empty.apply(document.metadata).item('©nam').fetch(:value)
      removed = P::MetadataUpdate.properties(remove: [:title]).apply(document.metadata)
      assert_nil removed.item('©nam')
      document.plan(metadata: empty).commit!
    end
    P.open(@path) { |read| assert_equal [''], read.metadata.item('©nam').fetch(:value) }
  end

  def test_noop_write_to_is_a_byte_identical_copy
    output = File.join(@dir, 'unchanged.mp4')
    before = digest
    P.open(@path) do |document|
      result = document.plan(metadata: P::MetadataUpdate.properties).write_to!(output)
      assert_false result.fetch(:changed)
      assert_equal before, result.fetch(:output_digest)
    end
    assert_equal before, digest(output)
    assert_equal before, digest
  end

  def test_source_change_during_save_is_a_verify_save_error
    fault = proc { |_plan, _path| File.open(@path, 'ab') { |file| file.write(atom_box('free', ''.b)) } }
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      with_fault(:write_candidate, fault) do
        error = assert_raise(P::SaveError) { plan.commit! }
        assert_equal :verify, error.phase
        assert_false error.committed
        assert_kind_of P::SourceChangedError, error.cause
      end
    end
    L::Internal::File.open(@path, false) { |file| assert_nil file.metadata_snapshot.item('©nam') }
  end

  def test_cleanup_failure_preserves_original_failure_and_temporary_path
    before = digest
    damage = proc do |_plan, path|
      data = File.binread(path)
      offset = data.index('mdat') + 4
      data.setbyte(offset, data.getbyte(offset) ^ 255)
      File.binwrite(path, data)
    end
    cleanup = proc { |_plan, _temporary| raise IOError, 'injected cleanup failure' }
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      with_fault(:write_candidate, damage) do
        with_fault(:cleanup_candidate, cleanup, before: true) do
          error = assert_raise(P::SaveError) { plan.commit! }
          assert_equal :cleanup, error.phase
          assert_false error.committed
          assert_equal File.realpath(@path), error.output_path
          assert File.exist?(error.temporary_path)
          assert_kind_of P::SaveError, error.cause
          assert_equal :verify, error.cause.phase
        end
      end
      assert_equal before, digest
      assert plan.commit!
    end
  end

  def test_error_after_publication_is_committed_and_must_not_be_retried
    fault = proc { |_plan, *_args, **_options| raise IOError, 'injected result failure' }
    P.open(@path) do |document|
      plan = document.plan(metadata: title_update)
      with_fault(:result, fault, before: true) do
        error = assert_raise(P::SaveError) { plan.commit! }
        assert_true error.committed
        assert_equal :publish, error.phase
      end
      assert_raise(P::SourceChangedError) { plan.commit! }
    end
    P.open(@path) { |read| assert_equal ['新しい題名'], read.metadata.item('©nam').fetch(:value) }
  end

end
