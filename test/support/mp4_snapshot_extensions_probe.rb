# frozen_string_literal: true

# 原本置換前の許可範囲検証を、既存保存処理へテスト専用に追加する。
module MP4SnapshotExtensionsProbe
  # 実際の一時保存・再読込検証に期待snapshot照合を加え、rename前に拒否する。
  module ExpectedSave
    attr_accessor :probe_expected_snapshot

    def verify_saved_copy(path, *args, **keywords)
      super
      TagLib::MP4::File.open(path, false) do |verification|
        changes = probe_expected_snapshot.diff(verification.tag.metadata_snapshot)
        unless changes.empty?
          raise TagLib::MP4::MdtaSaveError.new("unauthorized metadata changes: #{changes.inspect}", phase: :verify)
        end
      end
    end
  end
end
