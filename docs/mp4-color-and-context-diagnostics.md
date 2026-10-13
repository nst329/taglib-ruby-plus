# MP4色構造とmetadata contextの診断

## 前提と責務

調査基準は2.3.2.15（e60fa99）。この変更は2.3.2.16へ収録する。
gemは構造診断、明示選択した参照の解除、保存と対象外構造の保持を担当する。
修復の採否、ffprobe警告の許容、stage、backup、公開、DB更新はMListNewが担当する。
colrの自動修復は実装しない。codecから観測したrangeを欠落フィールドへ補完しない。

## File#color_metadata_diagnostics

保存済みファイルを読み取り専用で診断し、native ownerから独立した凍結Hashを返す。
未保存タグ編集は反映しない。結果は安全に保存できるという判定ではない。

```ruby
TagLib::MP4::File.open(stage_path, false) do |file|
  report = file.color_metadata_diagnostics
  report[:entries].each do |entry|
    entry[:colr].each do |color|
      p [entry[:track_id], entry[:sample_entry_number], color[:offset],
         color[:color_type], color[:issues], color[:full_range]]
    end
  end
end
```

トップレベルは`status: :complete`と`entries`。completeは走査完了を表し、各entry/colrの
malformed/unsupportedを打ち消さない。

entryはtrack ID、0始まりtrack順番号、handler、stsd位置、sample entry位置・終端・種類、
0始まりindex、1始まり番号を返す。複数track、entry、colrを配列順と位置で区別する。
visual entryの固定78 bytesに対応する既知のentryだけを走査し、それ以外は
`status: :unsupported`、`unsupported_reason: :unsupported_sample_entry_layout`、`colr: []`を返す。
これは「colrがない」と断定する結果ではない。

colrの主なフィールド:

| フィールド | 意味 |
| --- | --- |
| colr_index | 同一entry内のcolr順番号、0始まり |
| atom_type / color_type | 外側のcolr / payload先頭のnclx、nclc等 |
| offset / end_offset / header_size | 絶対byte位置、排他的終端、8または16 bytesのheader |
| declared_size / payload_length | 宣言size、親境界で検証した実payload長 |
| parent_offset / parent_payload_offset / parent_end | sample entryの境界 |
| color_primaries / transfer_characteristics / matrix_coefficients | 16bitの生値。読めない値はnil |
| range_field_present / range_byte / full_range | nclxのrange byte有無、生byte、最上位bitのbool。欠落時はnil |
| raw_digest | headerを含むcolr全体のSHA-256 |
| status / issues / unsupported_reason | complete、malformed、unsupportedと構造上の理由 |

nclxの規定payloadは11 bytes、nclcは10 bytes。短いnclxでも境界内で読める色値は返すが、
rangeはnilのまま。nclcにはrangeフィールドがなく、full_rangeはnil。
予約range bitや余分なbytesも問題として記録する。
未知型は数値フィールドを解釈せず、位置・型・長さ・digestと未対応理由を返す。
size=0は宣言sizeとして0を保持し、実終端は親終端を使う。

既存atom parserを共有し、32/64bit header、親境界、深さ16、総atom数50,000を検証する。
header再読込を含む総読込予算は32 MiB、単一colr payloadは1 MiB。
mdatはheader以外を読まず、sample entryやcolrの隣接atomへ読み越さない。
境界異常など走査継続不能は`ColorMetadataError`を送出する。
`code`はmalformed、unsupported、limit。既存parser/IO例外はcauseに保持する。
Fileのnative constructor自体が開けない入力については、File.openの例外が先に発生し得る。

## File#metadata_context_diagnostics

既存`tag.metadata_diagnostics`を補完する、保存済みcontextの詳細診断。
snapshotの`source_structure`と構造比較契約には位置情報を混ぜない。

```ruby
TagLib::MP4::File.open(stage_path, false) do |file|
  report = file.metadata_context_diagnostics
  raise report[:issues].inspect if report[:status] == :failed
  report[:structure][:contexts].each do |context|
    p [context[:path], context[:offset], context[:handler], context[:keys]]
    context[:items].each do |item|
      p item.values_at(:raw_type_hex, :numeric_value, :interpretation,
                       :key_index, :key, :index_in_keys, :raw_digest)
    end
  end
end
```

contextにはmeta、handler、keys、ilstの位置と終端、handler、keys、item配列を含む。
同じpathの複数contextも絶対offsetで区別する。
itemには順番号、位置・終端、raw 4 bytesとhex、big-endian uint32解釈値、解釈区分、
key indexと解決key、keys内にあるか、headerを含むSHA-256を含む。
`interpretation`はgemの既存解釈に合わせ、mdta内で先頭byteが0のitemをkey_index、それ以外をfourccとする。
これはFFmpegの解釈と常に同じとは限らない。特にpurlはfourccでありながら、
mdta contextでFFmpegが数値index 1886745196として試行する。
mdirにはkeysによる解釈がなく、key_index/key/index_in_keysはnil。

status completeは構造走査の完了。編集可否は既存診断とissuesで判断する。
境界異常等ではstatus failed、issuesにunreadable_structureと原因messageを返し、
部分的なcontextを完全な結果として返さない。既存の64 MiB meta上限、50,000 atom上限、
深さ上限、境界検証を維持し、mdatをskipする。

## purl保存の契約

数値itemだけのmdta contextに`set_property('podcastURL', ...)`を行うと、既存native writerは
そのilstへ4文字purlを追加する。handlerとkeysは変更しない。
ffprobe n9.0.2で警告の新規生成を確認した。

通常saveとsave_preserving_unindexed_mdtaは、mdta contextへ新しいfourcc purlを導入する場合、
`MdtaSaveError`（phase prepare、committed false）で拒否する。原本を変更しない。
既存purlを含むcontextの保持とmdirへのpurl保存は可能。
未編集purlは保存後のraw digestも比較する。nativeがdata_type等を変更した場合は
`MdtaSaveError`（phase verify、committed false）で原本置換を拒否する。
例えば既存purlのdata_type 1をnativeが0へ変える入力は、論理値が等しくても保存成功にしない。
既存警告を許容するかはMListNewの判断であり、gemは警告の無視やデータ削除を行わない。
この変更は新規purlのmdta保存を可能にするものではない。
新しいmdir contextの生成にはnativeの複数context読取・保存・snapshot契約の設計が必要なため、
この修正で暗黙に追加しない。MListNewは拒否されたstageを公開しないこと。

参照解除保存はnativeタグwriterを通さず、meta全体をraw保持するため、
参照解除だけではpurl itemやhandler/keysを生成・変更しない。

## 欠落chapter参照とMListNewへの導入

2.3.2.15の既存APIで、非ゼロの欠落参照も位置とIDによって選択解除できる。
参照解除処理への修正は不要。診断を取ったstageと同じファイルに対して選択を渡す。

```ruby
# stageはMListNewが用意する原本のコピー。採否の判断もMListNewが行う。
TagLib::MP4::File.open(stage_path, false) do |file|
  references = file.chapter_reference_diagnostics
  # 例: 呼出側でこの欠落参照群を解除すると決定済みの場合。
  selected = references.select { |row| row[:status] == :missing && row[:target_exists] == false }
  file.remove_chapter_references(references: selected)
  file.save_chapters
end
TagLib::MP4::File.open(stage_path, false) do |verification|
  p verification.chapter_reference_diagnostics
  p verification.color_metadata_diagnostics
  p verification.metadata_context_diagnostics
  p verification.nero_chapters
end
# 次にMListNewがffprobe全packet読取・警告比較・backup・公開・DB更新を実施する。
```

未選択の欠落参照、正常Nero章、全track、字幕、画像、metadata、media payloadを保持する。
通常saveの不正参照拒否は維持する。対象不一致、境界異常、保存失敗を成功として扱わない。
失敗時は既存MdtaSaveErrorのphase/committed/causeも確認し、reopen失敗は保存済みの場合がある。

MListNewは2.3.2.16の配布gemを隔離環境で検証し、Gemfile/lockを2.3.2.16へ更新する。
配布名は既存どおりarm64-darwin、x86_64-darwin、sourceに分ける。
診断APIの存在確認には`file.respond_to?(:color_metadata_diagnostics)`と
`file.respond_to?(:metadata_context_diagnostics)`を使える。

検証範囲と未確認事項は[合成検証記録](Memos/2026-10-13-MP4診断保存の合成検証.md)、
判断理由は[ADR](ADR/2026-10-13-colr診断とpurlのcontext生成拒否.md)に記録する。
