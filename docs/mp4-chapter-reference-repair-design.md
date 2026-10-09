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

両APIはclose後も使える不変のRuby所有Hash配列を返す。元トラックID・参照先ID・元trak内の0始まりtref_index・元chap内の0始まりreference_indexを報告し、順序・重複を保持する。

```ruby
{ source_track_id: 2, tref_index: 0, reference_index: 0, target_track_id: 0,
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

一時コピーのmoov内でchapの欠落IDだけを除去し、残ったIDの順序・重複を維持する。今回の欠落ID除去で空になったchapを除去し、その結果空になったtrefだけを除去する。元から空のchap／trefは保持する。同一trakの全trefを独立して編集し、統合・先頭／末尾だけの採用は行わない。他種のtref参照と全実トラックを保持する。nativeのchapter削除・タグ再シリアライズは呼ばない。

moov縮小分をfree atomで埋め、通常は後続の位置を維持する。混在chapから1 ID（4 bytes）だけ除去するとfreeの最小8 bytesを確保できないため、moovを8 bytes拡張する。その場合はmoovより後のmdatを指す検証済みstco／co64だけを8 bytes移動する。前のmdatへのoffsetは変更しない。64-bit atom headerを維持し、32-bit offset／atom sizeのoverflowを拒否する。

保存後の別handleから次を検証して、成功した場合だけ原本を置換する。

- 欠落参照が0件で、残った参照の元ID・先ID・順序・重複・判定と、削除後に詰め直したtref_index／reference_indexが計画と一致する。
- 欠落ID除去後のchap配列を含む全構造と、それ以外のleaf payloadのサイズ・SHA-256が一致する。元から空のatomとchapter以外の参照も比較し、trefのまとまりを変えた出力を拒否する。paddingは比較対象外。tkhd、Nero chpl、metadata、artwork、全トラックと全mdat payloadも対象。
- chunk offsetは対象mdatの番号とpayload内の相対位置が一致する。表の型・ヘッダー・件数・順序も保持する。
- 出力全体のSHA-256が生成時と一致し、原本SHA-256が計画作成時から変化していない。

テストは製品parserを使わない独立したatom解析、raw保持対象比較、別handle再読込も行う。ffprobe警告の有無は成功条件にしない。

## 対応範囲・失敗

字幕title等で使われる`udta/name`はopaque leaf payloadとして許可し、編集せず保持する。字幕nameのbytesと配置も既存の保持signatureで比較する。`name`内部の文字コード解釈や正規化は行わない。

非fragmented MP4の対応済みmoov／trak／mdia／minf／stbl構造に限定し、未知構造を拒否する。外部・複数data reference、fragmented、圧縮moov、暗号化offset、iloc等は非対応。metaは通常のhdlr／keys／ilst／freeを保持し、その内部値は編集しない。moovは64 MiB以下。atom parserの深さ16・全体件数50,000制限も適用する。

不正境界、chap payloadの4-byte不整合、重複したtkhd、単一tref内の重複chap、重複した実トラックID、実トラックID 0、truncatedヘッダー、stco／co64件数不整合、mdat外offset、未知構造は`ChapterReferenceError`で明示的に失敗する。`code`は`malformed`・`unsupported`・`pending_changes`・`source_changed`。部分診断や部分変更計画は公開しない。

保存失敗は既存の`MdtaSaveError`の`phase`／`committed`契約に従う。rename前の失敗は原本と未保存計画を維持し、一時ファイルを削除する。置換後の再open失敗だけ`committed: true`。原本modeを維持し、既存保存同様に置換・再openする。同時書込の排他制御を新設するものではない。

存在する不適切な参照は修復後も残るため、外部ツールの警告が残る可能性がある。成功条件は「欠落参照だけが消え、保持対象が一致する」ことで、全chapter構造の修復ではない。

[ADR](ADR/2026-10-09-QuickTime欠落chapter参照の明示的除去.md)

## 複数trefと保存後検証

修復記録のindexは原本上の位置。保存検証用indexは、各trakの全trefを走査し、今回削除するtrefだけを除外して計算する。chap内も残存IDを順に再採番する。集合比較や元indexとの単純一致にはしない。参照を持たないtrefも添字を占める。

厳密readerも全trefを列挙する。修復後に単一音声chap参照が残る構造は、空でないchapter以外のtrefが共存しても読取可能。複数有効chapter参照、複数ID、音声以外からの参照など、readerの従来の制限は維持する。欠落参照修復はこれらを削除しないため、参照修復が成功してもchapter_snapshotや通常タグ保存が非対応で拒否される構造は残る。

cleanupが失敗した場合はMdtaSaveErrorのphase=:cleanup、committed=falseで報告し、causeに元の保存失敗を保持する。メッセージに一時ファイルのパスを含める。原本と計画を保持し、障害解消後の再保存で復旧する。置換後の再open失敗は従来どおりphase=:reopen、committed=true。

## 時間情報の読み取り専用診断

`chapter_timing_diagnostics`は参照診断の対応構造内にあるtext/text候補を、未参照の候補も含めて診断する。参照修復の成功条件には追加しない。tkhd、elst、timescaleは修復処理でも診断でも変更しない。戻り値は不変のRuby所有値。mvhd／mdhd／tkhd／elstのversion 0/1を読む。不正な境界・件数・ゼロtimescale等はChapterReferenceErrorで拒否する。

```ruby
file.chapter_timing_diagnostics.first
# => {
#   track_id: 4,
#   movie: {version: 1, duration: 1605653349300, timescale: 441000000},
#   media: {version: 0, duration: 3640937, timescale: 1000},
#   track_header: {version: 0, duration: 3640937},
#   stts: {sample_count: 16, duration: 3640937},
#   edits: [{version: 0, segment_duration: 3630547892,
#            media_time: 0, media_rate: 65536}],
#   observations: [:tkhd_elst_duration_mismatch,
#                  :elst_matches_movie_duration_low32],
#   correction: :not_attempted
# }
```

比較は整数で行う。mdhd durationとstts合計、editありのtkhd durationとelst segment_duration合計を比較する。editなしの場合だけ、sttsをmovie timescaleへ換算した値とtkhdを比較し、movie tick 1単位以内の丸めを許す。editがある場合、mediaとtrackのduration差だけでは不整合扱いしない。media_time=-1のempty edit、非ゼロ開始のトリミング、複数edit、rate変更、rate=0を補正しない。

下位32bit一致は値の観測であり、overflow発生や生成原因を断定しない。単一editでmovie全期間に対応するという証拠もないため、mvhd durationをそのままtkhd／elstへ代入しない。64bitへの昇格やtimescaleの縮小も今回は行わない。観測が空でも全時刻写像・editの再生妥当性を保証しない。

提示ファイルはmdhd／stts／mvhdが約3640.937秒で一致する一方、tkhdとelstが互いにも一致しない。参照修復だけで全chapter表示が直るとは判断できない。ffprobeの1章表示の原因、生成時の演算、正しいedit mappingは実ファイルの追加調査が必要。

Appleの[tkhd duration仕様](https://developer.apple.com/documentation/quicktime-file-format/track_header_atom/duration)では、track durationはmovie時間座標で、editがあればedit duration合計から導かれる。[edit listの例](https://developer.apple.com/documentation/quicktime-file-format/playing_with_edit_lists)にもトリミング・反復・速度変更がある。このためmedia durationとの単純一致で補正しない。

提示構造の修復結果例（原本上の位置を保持）：

```ruby
removed = file.remove_dangling_chapter_references
removed.map { |r| [r[:source_track_id], r[:tref_index], r[:reference_index], r[:target_track_id]] }
# => [[1, 0, 0, 0], [2, 0, 0, 0], [3, 0, 0, 0]]
file.save_chapters
file.chapter_reference_diagnostics
# => [{source_track_id: 2, tref_index: 0, reference_index: 0,
#      target_track_id: 4, target_exists: true,
#      target_handler: "text", status: :chapter_candidate}]
```

修復前の有効参照は`[2, 1, 0, 4]`。tref削除後は`[2, 0, 0, 4]`となる。実API名は`remove_dangling_chapter_references`と保存APIの組合せであり、このリポジトリに`repair_chapter_references!`はない。

## 実ファイルでの追加確認

ユーザー指定の010226_001.mp4で、提示された複数tref・時間値の一致を確認した。一時コピーの参照修復は成功し、厳密reader／snapshotで15章を読み取れた。全mdat・chapter sample・時間atom・offset等は独立parserでも保持を確認した。原本SHA-256は不変。

修復コピーはffprobe通常設定で1章（0〜8.233秒）、ignore_editlist=1またはadvanced_editlist=0で16サンプルを表示する。edit list適用による表示制限を確認したが、生成原因・正しい補正値は未確定のため時間atomを変更しない。

通常タグ保存は別のmetadata変化でverify拒否となる。期待した空キーitemが出力で消え、mdta keys情報も変わる。一時出力の15章は保持されるが、保存成功とは扱わない。失敗はcommitted=falseでコピーを保持した。

[実ファイル検証記録](Memos/2026-10-09-実MP4複数tref修復検証-010226_001.md)
