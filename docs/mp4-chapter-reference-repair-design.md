# QuickTime chapter参照の診断・明示的除去

## 前提・責務

通常の読込・保存へ自動修復を追加しない。2.3.2.9の合成MP4で、`remove_chapters(style: :quicktime)`と`save_chapters`がtrueを返しても`chap → 0`と全ファイルbytesが変わらない現象を再現した。nativeのQtChapterList::removeは参照先chapterトラックが見つからないと何もせずtrueを返す。

gemは参照診断・欠落参照だけの明示的除去計画・安全な保存を担当する。修復判断、原本バックアップ、別ファイル出力、修復記録、作品整理との統合検証は呼出側の責務。検証では実ユーザーファイルに書き込まず合成fixtureだけを使用する。

## 公開API

```ruby
TagLib::MP4::File.open(path, false) do |file|
  report = file.chapter_reference_diagnostics
  removed = file.remove_dangling_chapter_references
  file.save_chapters unless removed.empty?
  # 成功後にremovedを修復記録へ残す。
end
```

両APIはclose後も使える不変のRuby所有Hash配列を返す。元トラックID・参照先ID・元chap内の0始まりindexを報告し、順序・重複を保持する。

```ruby
{ source_track_id: 2, reference_index: 0, target_track_id: 0,
  target_exists: false, target_handler: nil, status: :missing }
```

| status | 意味 | 除去対象 |
|---|---|---|
| missing | 実トラックID一覧に存在しない | はい |
| inappropriate | 存在するがtext handler / text sample entryの組ではない | いいえ |
| chapter_candidate | text handlerと単一text sample entryを持つ | いいえ |

候補判定は時刻・本文・sample tableまで検証した有効chapterを意味しない。完全読取は別の`chapter_diagnostics`の責務。参照先を推測して付け替えず、chapterを新設せず、既存字幕・映像・音声をchapterへ変換しない。

診断は常にディスク上の原本を対象とし、未保存の除去計画を反映しない。除去APIは全解析・検証後にだけ保存待ち計画を設定し、ディスクもnative chapter状態も変更しない。参照なし・欠落なし・同じhandleで同じ計画を再実行した場合は空配列。保存後の再実行も空配列。

修復とタグ・chapter更新は別々に保存する。未保存の変更があれば計画を拒否し、計画後にそれらを変更した場合も保存を拒否する。計画の保存には`save_chapters`と`save`のどちらも利用できるが、修復以外を混在させない。

## 編集と保持検証

### 内部責務の整理

解析結果と保存待ち計画を分ける。`ChapterReferences`は原本構造・参照・保持対象を読取り、明示的な`repair_plan`でだけ変更bytesを生成する。診断と保存後検証では変更bytesを生成しない。

`ChapterReferenceRepair`は、元moov境界、生成済み変更bytes、原本hash、除去記録、保持期待値だけを所有する不変のRuby値とする。File／native handle／開いたIOを保持しない。Fileは計画の受付・保存準備・一時コピーへの適用・検証・原子的置換を担当する。公開APIと修復／更新を別保存にする契約は変更しない。

この設計を実装して対象テストを確認した後、保持signature計算と保存準備の小さな責務を抽出するコードリファクタリングを行う。後段では比較基準・公開API・例外phaseを変更しない。

一時コピーのmoov内でchapの欠落IDだけを除去し、残ったIDの順序・重複を維持する。空chapを除去し、trefも空なら除去する。他種のtref参照と全実トラックを保持する。nativeのchapter削除・タグ再シリアライズは呼ばない。

moov縮小分をfree atomで埋め、通常は後続の位置を維持する。混在chapから1 ID（4 bytes）だけ除去するとfreeの最小8 bytesを確保できないため、moovを8 bytes拡張する。その場合はmoovより後のmdatを指す検証済みstco／co64だけを8 bytes移動する。前のmdatへのoffsetは変更しない。64-bit atom headerを維持し、32-bit offset／atom sizeのoverflowを拒否する。

保存後の別handleから次を検証して、成功した場合だけ原本を置換する。

- 欠落参照が0件で、残った参照の元ID・先ID・順序・重複・判定が計画と一致する。
- chapとpadding以外の全構造とleaf payloadのサイズ・SHA-256が一致する。tkhd、Nero chpl、metadata、artwork、全トラックと全mdat payloadも対象。
- chunk offsetは対象mdatの番号とpayload内の相対位置が一致する。表の型・ヘッダー・件数・順序も保持する。
- 出力全体のSHA-256が生成時と一致し、原本SHA-256が計画作成時から変化していない。

テストは製品parserを使わない独立したatom解析、raw保持対象比較、別handle再読込も行う。ffprobe警告の有無は成功条件にしない。

## 対応範囲・失敗

非fragmented MP4の対応済みmoov／trak／mdia／minf／stbl構造に限定し、未知構造を拒否する。外部・複数data reference、fragmented、圧縮moov、暗号化offset、iloc等は非対応。metaは通常のhdlr／keys／ilst／freeを保持し、その内部値は編集しない。moovは64 MiB以下。atom parserの深さ16・全体件数50,000制限も適用する。

不正境界、chap payloadの4-byte不整合、重複したtkhd／tref／chapや実トラックID、実トラックID 0、truncatedヘッダー、stco／co64件数不整合、mdat外offset、未知構造は`ChapterReferenceError`で明示的に失敗する。`code`は`malformed`・`unsupported`・`pending_changes`・`source_changed`。部分診断や部分変更計画は公開しない。

保存失敗は既存の`MdtaSaveError`の`phase`／`committed`契約に従う。rename前の失敗は原本と未保存計画を維持し、一時ファイルを削除する。置換後の再open失敗だけ`committed: true`。原本modeを維持し、既存保存同様に置換・再openする。同時書込の排他制御を新設するものではない。

存在する不適切な参照は修復後も残るため、外部ツールの警告が残る可能性がある。成功条件は「欠落参照だけが消え、保持対象が一致する」ことで、全chapter構造の修復ではない。

[ADR](ADR/2026-10-09-QuickTime欠落chapter参照の明示的除去.md)
