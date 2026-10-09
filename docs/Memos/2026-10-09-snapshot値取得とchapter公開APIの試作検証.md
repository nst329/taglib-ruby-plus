# snapshot値取得・chapter公開APIの試作検証

2026-10-09。Ruby 4.0.7、macOS arm64。既存2.3.2.9の検証済みインストール済みnative gemを使用。製品コードは変更していない。

## 試作時の再現手順（歴史的記録）

下記試作ファイルは製品実装時にtest/mp4_snapshot_access_chapter_test.rbへ置換し、support moduleは削除した。現在の再現は[実装検証](2026-10-09-snapshot値取得とchapter公開APIの実装検証.md)を参照。

```sh
/opt/homebrew/opt/ruby/bin/ruby -c test/support/mp4_snapshot_access_chapter_probe.rb
/opt/homebrew/opt/ruby/bin/ruby -c test/mp4_snapshot_access_chapter_design_probe_test.rb
MDTA_BINDING_LIB=/private/tmp/taglib-native-gem-2329/gem-home-macos12/gems/taglib-ruby-plus-arm64-darwin-2.3.2.9/lib /opt/homebrew/opt/ruby/bin/ruby test/mp4_snapshot_access_chapter_design_probe_test.rb
```

MDTA_BINDING_LIBにはsnapshot機能付き2.3.2.9のlibを指定する。通常の旧bundleを混ぜない。テストは一時ディレクトリのfixtureコピーとffmpeg合成ファイルだけを変更する。mdta合成にはFFMPEG（既定/Users/nasu/Bin/ffmpeg）が必要。

最終結果: 12 tests / 94 assertions、failure/error/omissionなし。両Rubyファイルの構文チェック成功。製品コードの変更がないため全体テストは実行していない。今回Intel・grouped backendの追加試作は未実施。

## 初回失敗から特定した原因

- mdir fixtureへmdtaを新設する復元がnativeに拒否された。既存設計通りの制約。既存mdta領域の取得テストは合成mdta fixtureへ分け、mdirで拒否・理由・原本不変となるテストを別に追加した。
- readAudioProperties=falseでduration超過chapterが拒否されなかった。nativeはaudioPropertiesがありlength>0の場合だけ確認する。trueで拒否、falseでpending登録可能となる現状を独立テストで記録した。

## 確認できたこと

- nil、値なしキー、空UTF-8 payload、NUL入りbinary、複数locale、同値重複、値順を区別して取得できる。
- itemのatom型・日本語・空文字と画像形式・未知形式・空bytesを不変値として保持できる。未知/空画像はin-memory snapshotの取得試作のみで、native保存可能という主張ではない。
- 保存・close・GC後のmdtaと画像取得値が利用できる。
- 全PROPERTY_ATOMSの期待snapshotがsetter直後と論理一致。空titleとShift_JIS copyrightの手書き期待値、複数property更新の保存後独立再読込も一致する。
- 不正property入力は元snapshot・file状態・原本bytesを変更しない。
- NeroとQuickTimeの内容が異なるsnapshotを両形式別々に保存・再読込でき、タグを保持する。
- 選択形式だけの削除は非選択形式を保持する。
- 2形式目の不正順序・duration超過を先に拒否し、pendingの1形式目と原本を保持する。
- 元Chapterタイトルは可変だが、試作snapshotはdeep copy/freezeで影響を受けない。
- Neroの宣言countを1から2へ変更し実データを1件のままにすると、現行readerは1件だけを成功扱いする。chapter_statusは存在しない。公開前のnative診断追加が必要。
- Neroの256bytesタイトルはwrite時に切り詰められるが、File#saveの再読込検証でphase=:verify、committed=falseとして拒否され、原本bytesとpending値を保持する。
- タグと両chapterを同時変更し正常検証後に故障注入すると、rename前に停止し原本bytesとタグ・chapterのpending値を保持する。

## 未検証・未実装

以下は初期試作時点の未検証範囲であり、製品実装後に検証した項目は[実装検証](2026-10-09-snapshot値取得とchapter公開APIの実装検証.md)を参照。

公開API追加、共通property計画の製品リファクタリング、詳細chapter差分分類、構造status、QuickTime異常構造、空chapter物理構造、字幕mux・音声変換の実ファイル、Neroの255件超・時刻整数overflow・ミリ秒未満の精度。試作成功はこれらの対応を保証しない。

[設計](../mp4-snapshot-access-chapter-design.md) / [ADR](../ADR/2026-10-09-snapshot値取得とchapter公開APIの設計.md)
