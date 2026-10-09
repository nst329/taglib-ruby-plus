# frozen_string_literal: true

# 既存snapshotによる重複hunkを考慮し、未適用の独立した追加patchだけを安全に適用する。
def ensure_taglib_patch(source, patches, expected_commit)
  actual_commit = IO.popen(['git', '-C', source, 'rev-parse', 'HEAD'], &:read).strip
  abort "Unexpected TagLib source commit: #{actual_commit}" unless actual_commit == expected_commit
  snapshot_applied = system('git', '-C', source, 'apply', '--reverse', '--check', patches.fetch(1),
                            out: File::NULL, err: File::NULL)
  patches.each_with_index do |patch, index|
    # snapshotが適用済みなら、変更済みの重複hunkで最初のpatchを再判定しない。
    next if index.zero? && snapshot_applied
    next if system('git', '-C', source, 'apply', '--reverse', '--check', patch, out: File::NULL, err: File::NULL)

    abort 'TagLib metadata patch cannot be applied' unless system('git', '-C', source, 'apply', '--check', patch)
    abort 'TagLib metadata patch application failed' unless system('git', '-C', source, 'apply', patch)
  end
end
