# frozen_string_literal: true

require_relative 'mp4_limited_repair'

module TagLib::Plus::MP4
  # 所有セッションに束縛された不変の限定修復診断。内部保存計画は公開しない。
  class LimitedRepairPlan
    attr_reader :status, :required_operations, :metadata, :quicktime

    # 判定値を凍結し、登録権限は非公開の所有tokenへ束縛する。
    def initialize(status:, required_operations:, metadata:, quicktime:, owner:, repair:, quicktime_plan:)
      @status = status
      @required_operations = DeepCopy.call(required_operations)
      @metadata, @quicktime = DeepCopy.call(metadata), DeepCopy.call(quicktime)
      @owner, @repair, @quicktime_plan = owner, repair, quicktime_plan
      freeze
    end

    private

    attr_reader :owner, :repair, :quicktime_plan
  end

  class File
    # 方針とは独立に各領域を診断し、同じ原本座標の候補へ必要操作を合成する。
    def plan_limited_repairs(mdta_layout: nil)
      ensure_current!
      ensure_repair_slot!
      unless [nil, :indexed, :mixed_known_fourcc].include?(mdta_layout)
        raise ArgumentError, 'unknown mdta_layout'
      end
      editor, qt = read_structure do |native|
        reader = ::TagLib::MP4.const_get(:ChapterReader, false).read(native)
        analysis = ::TagLib::MP4.const_get(:LimitedRepairEditor, false).new(native,
          chapter_report: reader.report, mdta_layout: mdta_layout)
        @diagnostics[:chapters] ||= diagnostic_report(:chapters, reader.report)
        cache_reference_diagnostics(analysis)
        nero = reader.report.fetch(:nero)
        report = analysis.quicktime_report
        qt_status = { required: :removable, not_needed: report[:reason_code] == :quicktime_absent ? :absent : :complete,
                      blocked: :blocked }.fetch(report[:status])
        qt_plan = QuickTimeChapterRemovalPlan.new(status: qt_status, reason: report[:reason_code],
          reason_code: report[:reason_code], references: analysis.removed,
          target_track_id: analysis.target_track_id,
          nero: nero[:status] == :complete ? public_chapters(reader.values.fetch(:nero)) : [],
          nero_status: nero[:status], nero_chpl_sha256: reader.nero_payload_sha256,
          source_path: @path, generation_token: @generation.__send__(:token))
        [analysis, qt_plan]
      end
      metadata = editor.metadata_report
      quicktime = editor.quicktime_report.merge(references: editor.removed)
      operations = []
      operations << :remove_invalid_mdta_indices if metadata[:status] == :required
      operations << :remove_broken_quicktime_chapters if quicktime[:status] == :required
      status = if [metadata[:status], quicktime[:status]].include?(:blocked)
                 :blocked
               elsif operations.empty?
                 :unchanged
               else
                 :repairable
               end
      plan = LimitedRepairPlan.new(status: status, required_operations: operations, metadata: metadata,
        quicktime: quicktime, owner: (@limited_plan_owner ||= Object.new), repair: status == :repairable ? editor.repair_plan : nil, quicktime_plan: qt)
      @issued_limited_plan = plan
      plan
    end

    # 必要操作がすべて許可された同一セッションの計画を、部分適用せず登録する。
    def apply_limited_repairs(plan:, allow:)
      ensure_current!
      ensure_repair_slot!
      known = %i[remove_invalid_mdta_indices remove_broken_quicktime_chapters]
      raise ArgumentError, 'allow must contain known unique operations' unless allow.is_a?(Array) && allow.uniq == allow && (allow - known).empty?
      unless plan.is_a?(LimitedRepairPlan) && plan.__send__(:owner).equal?(@limited_plan_owner) && @issued_limited_plan.equal?(plan)
        raise Error.new('unrecognized limited repair plan', code: :invalid_plan, phase: :prepare)
      end
      raise Error.new('limited repair is blocked', code: :repair_blocked, phase: :prepare,
        issues: [plan.metadata, plan.quicktime].select { |row| row[:status] == :blocked }.map { |row|
          { code: row[:reason_code], message: 'limited repair blocked', location: 'repair', details: row }
        }) if plan.status == :blocked
      unless (plan.required_operations - allow).empty?
        raise Error.new('required repair is not permitted', code: :repair_not_allowed, phase: :prepare)
      end
      return [] if plan.status == :unchanged

      @repair_plan = plan.__send__(:repair)
      @repair_kind = :limited_repairs
      @limited_repair_plan = plan
      @quicktime_removal_plan = plan.__send__(:quicktime_plan) if plan.quicktime[:status] == :required
      plan.required_operations
    end

    private

    # 完全snapshotを前提にせず、対象atomだけを変えたraw signatureを独立比較する。
    def verify_limited_repair(native)
      checked = ::TagLib::MP4::ChapterReferences.new(native)
      unless checked.report == @repair_plan.retained_report && checked.preservation_signature == @repair_plan.preservation_signature
        raise IOError, 'limited repair preservation verification failed'
      end
      raise IOError, 'media verification failed' unless @source_scan.fetch(:media) == @output_scan.fetch(:media)
      verify_quicktime_removal(native, checked: checked) if @limited_repair_plan.quicktime[:status] == :required
      capture_snapshots(native, @requested_snapshots)
    end
  end
end
