# mdta数値keyをfourcc raw復元から分離する

## 状態

採用。taglib-ruby-plus 2.3.2.19に収録する。

## 前提・再現

実TagLib 2.3.2へ既存パッチを適用したnative拡張を使う。
FFmpegのuse_metadata_tagsで単一mdta contextの合成MP4を生成し、公開APIの
set_mdta_itemでpurlを新規保存、close、独立open、更新、saveする。
修正前の回帰テストでMdtaSaveError「restored purl raw verification failed」を再現した。
phaseはverify、codeはpurl_raw_mismatchで、atomic_save → save_temporary_copy →
restore_purl_raw_copyの経路だった。他キーだけの更新でも同じ失敗を再現した。

## 確定原因

save_temporary_copyの自動raw保持は通常item側のpurl保存署名のみを比較していた。
数値keyのmdta purlはitem_mapに存在しないため、更新前後ともnilであり不変と判定される。
一方raw_itemsはfourccと数値keyの両方を収集する。このため数値key atomを
fourcc専用replace_rawへ渡し、保存済み数値keyとの競合または識別不一致が生じ、
raw再読込の厳密検証で失敗した。nativeのmdta更新判定の欠陥ではない。

## 決定と理由

- 自動raw保持は通常item側の元署名が存在し、現在の署名と一致する場合に限定する。
  さらにkey_indexを持たないfourccだけを選び、識別方式を処理境界で区別する。
  数値keyをfourcc用の署名・変換へ渡さないことが、この処理の責務に合うため。
- mdtaはキー名によらず既存native保存経路で処理する。purl専用のmdta変更判定、
  復元計画、追加context、MList用処理は作らない。
- nativeのrenderItemsは全キー共通のchangedKeys/removedKeysを参照し、未編集はraw、
  更新は型付き値、削除は省略する。既存実装を使う方が重複や古いrawによる上書きを防げる。
- snapshotに明示されたraw復元計画と既存mdir・対応済み複合context経路は維持する。
  APIの互換性を保ち、今回の原因から修正範囲を広げないため。
- raw保持対象の選択をordinary_purl_restore_rowsへ分離し、native保存と復元の制御を整理する。
  nil同士の比較では保持判定を成立させない。
- rewrite_metadata_copyへatom変換、作業コピー、mode保持、置換、cleanupを集約する。
  明示snapshotの数値key復元とfourcc復元の重複を減らし、失敗時の処理を一箇所に保つ。
- 保存後検証、警告、例外、原本置換前の検証とcleanupは維持する。
- パッチリリースは2.3.2.19。既存のvタグによるarm64・Intel・source gem公開を利用し、
  既存versionのartifactを上書きしない。

## 検証と制約

詳細は[検証記録](../Memos/2026-10-14-mdta数値key保存の回帰検証.md)を参照。
通常item/fourccの既存raw保持は残るが、mdta purlは他キーと同じ扱いとする。
未対応context、型変更拒否、atom境界やchunk offsetの安全性などの既存制限は維持する。
FFprobeが解釈しないtype 33は、更新前からの警告を確認し、rawを保存できることと
新規の不正数値index警告がないことを区別して検証する。
