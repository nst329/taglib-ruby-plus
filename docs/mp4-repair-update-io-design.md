# MP4修復・更新のI/O削減

## 現行と採用案

既存のPlus Fileは世代単位のatom index、chapter reader、header view、診断を共有する。
保存は原本から候補へのStreamコピーと、候補の独立全体走査でdigest・media署名を取得し、別handle検証後に公開する。
無変更の原本保存は候補を作らない。別出力の無変更保存はコピーする契約を維持する。

`plan_metadata_repair_and_update(properties:, mdta_layout: nil)` は既存の限定修復計画へタグ差分を合成する。
`apply_limited_repairs(plan:, allow:)` で全必要操作を許可し、`save!(to:, snapshots:, diagnostics:)` で別出力へ保存する。
更新操作名は `update_metadata`。計画statusは `unchanged` / `repairable` / `blocked`。
実変更は保存結果の `changed`。候補の存在ではなく、必要atom編集の有無から決定する。

初期対象は既存mdirの4byte文字列property更新と、不正mdta index除去・安全に一意同定できるQuickTime除去。
propertiesの検証・atom対応は既存MetadataUpdateを再利用する。
対象外はfreeform、空文字、mdir不在、更新propertyと同名の有効mdta値が存在する場合。
更新先itemの重複も拒否する。UTF-8／UTF-16BEの単一textが同値ならencoding・localeを保持して変更なしとする。
これらは理由付きblockedとし、snapshot復元や試行保存へフォールバックしない。
時間修復・汎用snapshot編集・Nero破損除去との追加合成はpending_changesで拒否する。
破損chapter両形式の除去は既存 `plan_broken_chapter_removal` を使用する。

## 保持条件

修復で不正indexだけを除去したmetadataへ、指定propertyだけを適用する。
指定外item、mdta、artwork、正常chapter、trackはraw bytesのまま保持する。
更新前snapshotを復元しないため、破損値や古い更新値を復活させない。
期待raw signature、参照、metadata context、media署名を独立再読込して検証する。
世代競合、公開unknown、cleanup失敗は従来の保存状態機械を維持する。

`chapter_samples(style: :quicktime)` は正常Neroの併存・内容差・Nero破損によらずQuickTimeだけを検査する。
引数省略時の既存の併存拒否は互換性のため維持する。
不在はnil、破損・未対応はErrorとissues、I/O・世代競合は専用Errorとする。
track・参照の複数候補は既存の一意性検証で拒否する。

## I/O

計画はmoovとchapter診断を読むが、全体hash・コピー・保存・一時ファイル作成を行わない（stat検証時）。
合成保存は原本全体の読取兼候補書込1回、候補の独立全体読取1回。
metadataだけの中間MP4やnative保存を追加しない。
厳密sha256検証を選択した場合の全体照合は既存契約どおり必要。
正常profile指定は強制書換えとせず、時間診断に異常がない場合unchangedとする。

保存後snapshotは要求された領域だけ返す既存限定修復経路を再利用する。
metadata観測は同一世代で完全snapshot取得済みなら再読込しない。

## 調査した既存APIと再利用範囲

| 既存API／内部機構 | 今回の扱い |
| --- | --- |
| `metadata` / `metadata=` / `changes` | 汎用snapshot編集は従来どおり。修復と混在させない |
| `MetadataUpdate.properties` | property名、入力検証、atomとmdta aliasの対応を共用 |
| `plan_limited_repairs` / `apply_limited_repairs` | 原本座標、所有token、許可操作、独立検証を共用 |
| `plan_broken_chapter_removal` | 片形式／両形式のmalformedだけを専用計画で除去 |
| `select_chapters` / `read_chapters` | 正常QuickTime優先。Neroとの内容差を破損にしない |
| `repair_chapter_timing` | profile一致時の既存修復を維持。正常なら `unchanged` を返す |
| `observation` / `diagnose` | generationのatom index・chapter reader・診断を共用。完全metadata観測の再読込を削減 |
| `Generation` / `Stream` / `Publication` | 世代、コピー時のdigest・media署名、独立検証、公開とcleanupを維持 |

限定修復計画は既存どおり最大64MiBのmoovをraw解析する。計画をmetadata headerだけに置き換える変更は行わない。
headerだけを求める `info`、参照・時間診断では、既存の遅延header readerを引き続き使用する。
完全chapter診断・sample要求は対象sampleを読む。完全snapshot要求時のmetadata-only stagingも既存経路を維持する。
「全体走査ゼロ」はMP4ファイル全体についての値であり、moov全体の読取ゼロを意味しない。

## 使用例と拒否理由

```ruby
TagLib::Plus::MP4.open(source) do |file|
  plan = file.plan_metadata_repair_and_update(properties: { title: '新しい題名' })
  case plan.status
  when :unchanged
    # 原本保存なら保存・コピー・一時ファイル作成をしない。
    result = file.save!
  when :repairable
    # 削除の運用判断は呼出側にある。予期しないQuickTime除去は許可しない例。
    file.apply_limited_repairs(plan: plan,
      allow: %i[remove_invalid_mdta_indices update_metadata])
    result = file.save!(to: output, snapshots: [:metadata], diagnostics: [:chapters])
  when :blocked
    # metadata / quicktime の reason_code と issues を確認する。
  end
end
```

`update_mdir_required`、`update_mdta_conflict`、`update_multiple_targets`、`update_unsupported` は保存前のblocked理由。
入力型・未知propertyはArgumentError、I/Oと原本世代変化はそれぞれ `io` / `source_changed` のError。
`pending_changes` は汎用snapshot・別修復の混在、`repair_not_allowed` は必要操作の許可不足を表す。

sample取得のErrorは従来のstatus codeに加え、`issues[].code` で `missing_chapter_track`、
`multiple_references` 等の具体的理由を保持する。複数参照が安全に同一trackへ収束する既存対応範囲は維持する。

保存結果の `diagnostics` は要求時だけ追加する。対応領域はmetadata、chapters、chapter_references、chapter_timing。
独立検証で解析した参照と時間情報は再解析せず使い、chapter readerも候補のgeneration内で共有する。
原本置換では返却診断を新世代cacheへ採用する。別出力では元Fileのcacheへ出力世代を混ぜない。

## 互換性

既存APIの引数・別出力コピー契約を維持する。追加機能を使う場合だけ専用計画へ移行する。
専用計画は更新のみの場合も別出力必須。原本を直接更新する既存metadata APIは引き続き利用可能。
正常時間に対するprofile指定は、従来のprofile_mismatch例外に代えてunchangedを返す。
異常がありprofile不適合なら引き続きprofile_mismatch、診断不能・I/O失敗は成功扱いしない。
Neroのsample取得や複数のQuickTime対象trackの自動選択は提供しない。
時間修復、破損Nero除去、汎用chapter編集、任意metadata snapshotの全組合せは今回の合成対象外。

検証・実測は[検証記録](Memos/2026-10-29-MP4修復更新I-O検証.md)を参照。
