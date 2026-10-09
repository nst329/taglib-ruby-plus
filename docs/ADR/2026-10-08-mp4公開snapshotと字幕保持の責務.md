# ADR: MP4公開snapshotと字幕保持の責務

- 日付: 2026-10-08
- 状態: 採用（実装は[実装ADR](2026-10-08-mp4公開snapshotの実装.md)を参照）

## 判断と理由

1. タグsnapshotをgem、字幕コピーと保持検証をMListNewへ置く。字幕はtrack/sampleであり、Tag snapshotと同じ保存モデルには載せられないため。ただし字幕保持は初版の受入条件とする。
2. チャプター復元は後回しとし、通常保存の非破壊検証は残す。優先度が低く、字幕とのtext track識別を省略する理由にはならないため。
3. 公開snapshotは独立した不変Ruby値とし、未知型を拒否する。close後も使え、部分的な退避を完全な退避と誤認させないため。
4. 論理比較と構造比較を分ける。別出力ではkey_indexが変わるため。未知atomの完全保持とは区別する。
5. 復元は管理対象metadataの全体置換とする。元snapshotへ戻す意味を明確にし、再実行で値を増やさないため。保存先固有タグの保持は暗黙mergeにしない。
6. native候補モデルの一括commitを追加する。一キーsetterの反復では複数キー間の部分更新を防げないため。既存applyChangesは全mdta置換を担えない。
7. 保存基盤は既存File#saveを利用する。一時コピー・検証・phase/committed契約を二重管理しないため。
8. 診断は修復と分離し、unknownは復元不可とする。legacyの能力不足を推測で安全扱いしないため。
9. 画像は通常item内に一度だけ格納する。artworkとcovrを重複管理すると不整合を起こすため。
10. snapshot復元はproperty setterを使わない。既存正規化によるmdta削除を避け、raw typed値を保持するため。
11. 永続化形式の公開を初版から外す。まずメモリ上の完全な退避と復元を確立し、形式移行の契約を増やさないため。
12. 値を持たないkeysもnativeの一括復元で扱う。flat一覧では失われ、全体置換でindexを維持する値削除にも必要なため。能力がなければ拒否し、既存replace_mdta_itemsの空配列拒否は維持する。

## 影響

2.3.2.7の一キー一括置換によるMListNewの値消失解消を先行できる。公開snapshotの最低versionは実装後に確定する。既存単一値setter/property更新は変更しない。C++本体へは適用せず、native提案と隔離検証を行う。

詳細は[公開snapshot設計](../mp4-metadata-snapshot-design.md)。MListNew関連ソースと該当再現テストは確認済み。

## 試作による設計更新

13. 通常itemにatom_data_typeを追加する。同じItem::type/payloadでもnative equalityが異なる反例を確認し、復元writerにも影響するため。
14. mdtaの全体置換は保存先固有キーの値を消し、keys表を維持する。既存removeMdtaItemが残るindexを詰め直す反例を確認したため。
15. 候補作成はnative内部状態で行い、default構築Tagを編集しない。groupedのEditable判定がilst参照に依存するため。File所有候補による試作は既存状態移送の再利用を検証するためだけに使用し、本番の追加ファイルopen基盤にはしない。
16. mov_textのcodec設定bytesを厳密に比較し、btrt変更を自動的に無視しない。FFmpegコピーで設定bytesが変わることを確認したため。保持成功するオプションをMListNew側で明示する。
17. 同一キー内の順序を比較する。MListNew現行比較が順序違いを受け入れる反例を確認し、依頼された保存契約では不十分なため。
18. 通常itemはキーと型のwriter往復可否も検証する。nativeの整数型APIと、キーごとの保存幅は同一ではないため。

検証の詳細と限界は[設計試作記録](../Memos/2026-10-08-mp4公開snapshotの設計試作検証.md)。
