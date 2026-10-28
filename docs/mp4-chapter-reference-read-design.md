# MP4 chapter参照の読取と明示的参照解除

状態: 実装済み。2026-10-13。Ruby層のみ変更し、native ABIを維持する。2.3.2.15として公開する。

## APIと責務

```ruby
TagLib::MP4::File.open(stage_path, false) do |file|
  selected = file.chapter_reference_diagnostics.select do |row|
    row[:status] == :missing && row[:target_track_id] == 0
  end
  removed = file.remove_chapter_references(references: selected)
  file.save_chapters unless removed.empty?
  after = file.chapter_reference_diagnostics
  samples = file.chapter_sample_snapshot # 未指定欠落・複数候補・不正sampleは例外
end
```

chapter_reference_diagnosticsは保存済み全chap関係を列挙し、source_handlerとsource_enabledを追加する。status=chapter_candidateはtext handlerと単一text sample entryによる候補であり、完全読取済みを意味しない。診断は除去対象を選ばず、変更bytesを生成しない。

remove_chapter_references(references:)はArray<Hash>を受け、source_track_id、tref_index、reference_index、target_track_idの非負整数4項目を一致条件にする。診断行全体を渡せば他の観測値も照合する。空配列はno-op。二重指定・位置不一致・観測値不一致はcode=:invalid_selectionとして全体を拒否し、pendingを変更しない。既存の参照計画があればpending_changesで拒否し、上書きしない。タグ・chapter・時間更新とも別保存にする。

戻り値は元位置を持つ、除去対象の順序付き不変診断行。削除するのは指定したchap関係だけで、存在する対象も明示して解除できる。対象trak、字幕、sample、mdat、他種参照は削除しない。編集で空になったchap/trefだけを除去し、元から空のatomは保持する。未指定の欠落参照も保持する。

既存remove_dangling_chapter_referencesは全欠落IDの一括除去を維持する。ID 0だけという方針はAPIに埋め込まない。実Track ID 0は禁止されるが、参照削除は利用者の明示操作である。[Apple Track ID](https://developer.apple.com/documentation/quicktime-file-format/track_header_atom/track_id)

gemは構造解析、対応範囲、限定変更、対象外保持を担当する。MListNewは削除採否、0だけの選択、stage・backup・排他、ffprobe照合、原本置換とDB更新を担当する。

## sample読取と互換性

chapter_sample_snapshotだけを非音声sourceと同一対象への複数chap関係へ拡張する。全chapが一つの実在targetへ収束し、そのtext sample表・payload・時間写像を完全に読めることを要求する。欠落や不適切な対象を読み飛ばさない。異なる対象があればunsupported、不正境界・表・payloadはmalformed。自動修復はしない。

Apple仕様ではchapter sourceは任意種類で、有効sourceからのchapがchapter listとして認識される。[Apple Chapter lists](https://developer.apple.com/documentation/quicktime-file-format/chapter_lists)

構造captureはプレイヤー認識とは別で、無効sourceからも読める既存挙動を維持する。source_enabledを観測値として返し、再生認識の採否は呼出側に残す。通常mov_text字幕や未参照textは推測で候補にしない。明示chapのあるtextは字幕表示を兼ね得るため、読取成功をトラック削除許可と扱わない。

snapshot.source_referencesはsource/target ID、source_handler、source_enabled、tref_index、reference_indexを持つ順序付き不変配列。単一参照では既存source_track_idと署名v1を維持する。複数参照ではsource_track_id=nil、signature_version=2。v2はversion、target、media時計、sample数、参照数、順序付きsource/target ID対、全sampleのindex/start/duration/payload_size/payload SHA256をunsigned 64bit big endianで連結してSHA256とする。物理tref位置、handler、有効フラグ、movie/edit contextは保持署名に含めない。順序・重複は含む。版をまたぐpreserved_equal?はfalse。

ChapterReader内で参照列挙を分離し、sample captureだけ対応範囲を切り替える。chapter_snapshotとnative APIは従来の単一音声参照制約を維持する。通常save/save_chapters、時間修復の適用範囲を暗黙に拡張しない。非音声sample読取成功でも、通常保存がprepare段階で拒否されることがある。native書込・データトラック削除・物理payload回収は対象外。

## 保存と失敗の保証

ChapterReferencesは診断と明示選択を分離し、選択済み位置だけを@editsへ登録する。全指定を照合してから不変保存計画をFileへ登録する。保存後のtref/reference位置を計算し、未指定欠落も含む期待reportを構成する。

保存は既存限定atom編集を再利用する。source digest、一時出力の期待bytes、別handleの全参照report、対象外atomと全mdat payload signature、mdat相対chunk offsetを確認後に置換する。未指定欠落が残る場合があるので、欠落ゼロを保存成功条件にしない。

読取・診断・計画失敗は原本とpendingを維持する。write/verify/replace等の置換前失敗はcommitted=falseで原本と再試行計画を維持する。置換後reopen失敗はcommitted=true、phase=:reopen。cleanup失敗はcauseと一時パスを保持する。digest確認は完全な外部書込排他ではない。

保存後の利用者確認は既存参照診断、sample snapshot、preserved_equal?を使用し、新しい保存確認APIは追加しない。ffprobe依存も追加しない。

## chunk offsetの一括検証と保持署名

`ChapterReferences#collect_offsets`はstco/co64の全offsetを読み、mdatが1つなら最小値・最大値だけでmdat範囲内を判定する。複数mdatは開始位置で昇順な範囲を二分探索し、範囲外offsetを従来どおり`malformed`で拒否する。

保持署名は`[header, width, count, digest]`。単一mdatはoffset − mdat開始位置の相対位置列、複数mdatは所属mdat index列と相対位置列を幅に応じた`N*`/`Q>*`で連結し、SHA-256へ畳み込む。絶対位置の移動を許しつつ、同じmdat内の同じmedia bytesを指すことを比較でき、chunk数に比例する配列を保持しない。公開snapshotの`preservation_signature`（v1/v2）とは別である。詳細は[ADR](adr/2026-10-28-chunk-offset検証と保持署名を一括化する.md)を参照する。

## 検証

test/mp4_chapter_reference_selection_test.rbは合成映像・音声・mov_text字幕にnativeでtext chapterを追加し、独立parserで参照を注入する。実ファイルは使わず、fixture編集は一時ディレクトリ内に限定する。期待値を製品の編集計画から生成しない。

非音声capture、native/論理snapshot/通常保存の制約維持、提示構造の0参照解除、通常字幕mdia・全mdat保持、同一targetと複数targetの区別、不適切な字幕target、非ゼロ欠落の保持、共有targetの参照解除、全参照解除後もtrak保持、選択不一致・二重指定・pending上書き拒否、保存検証失敗と再試行、不正stts、無効source、署名の重複・順序差を検証する。

既存参照修復suiteでverify/replace/cleanup/reopen失敗、source変更、offset補正、保存再試行を確認する。既存sample/時間修復/metadata保存suiteも実行する。新規解除API固有の検証失敗と既存保存フローの障害テストは区別して報告する。

実行環境はworkspaceのRubyコードと既存隔離native拡張。native再ビルド、他OS/backend、4GiB超の物理offsetは今回未検証。提示実MP4のsource 1の種類・flagsとtarget 28の完全読取も未確認。

```sh
FFMPEG=/Users/nasu/Bin/ffmpeg FFPROBE=/Users/nasu/Bin/ffprobe \
  ruby -Ilib -I/private/tmp/taglib-ruby-native-build-2/tmp/arm64-darwin27/stage/lib \
  test/mp4_chapter_reference_selection_test.rb
```

### 実行結果

| 範囲 | 結果 |
| --- | --- |
| 最終参照選択suite | 12 tests / 103 assertions、失敗・エラー・省略0 |
| 関連6 suites | 92 tests / 1263 assertions、失敗・エラー0、実ファイル未指定の省略2 |
| Test::Unit全体（実装整理後） | 413 tests / 2725 assertions、失敗・エラー0、省略13。2.3.2.15更新後に再実行済み |
| Minitest | 12 runs / 24 assertions、失敗・エラー0、任意probeのskip 5 |
| 包装・構文 | gemspecの244 pathsの存在、変更Rubyの構文、差分空白を確認 |

新規suiteは実APIのテストであり、初期調査のreaderサブクラスprobeは残していない。全体テストはTest::UnitとMinitestを分けて実行し、混在autorunnerによる未実行を避けた。
