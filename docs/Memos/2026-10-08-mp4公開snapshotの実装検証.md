# 公開MP4 snapshotの実装検証

2026-10-08。macOS arm64、Ruby 4.0.7、FFmpeg n9.0.2。全て合成実MP4と隔離ビルド・一時コピーを使用。実動画原本、MListNewソース、TagLib C++本体、インストール済みgemは変更していない。2.3.2.8は実装versionで、未配布。

## 実装と再現方法

legacy: TagLib 2.3.2にpatches/taglib/0001-mp4-mdta-preservation.patch、0002-metadata-snapshot.patchを順に適用。
grouped: proposals/0001、binding用0002、0003-ruby-metadata-snapshot.patchを順に適用。両パッチ列を新規コピーへ適用し、ビルド済みsourceの変更4ファイルとbytes一致を確認した。

```sh
python3 test/support/build_mp4_mdta_upstream_probe.py --base-source /path/to/pristine-taglib-2.3.2 --workdir /tmp/snapshot-native-grouped --metadata-snapshot
python3 test/support/build_mp4_mdta_binding.py --native-prefix /tmp/snapshot-native-grouped/install --workdir /tmp/snapshot-binding-grouped
cd /tmp/snapshot-binding-grouped
MDTA_BINDING_LAYOUT=grouped ruby -Ilib -Itest test/mp4_metadata_snapshot_test.rb
```

native prefixとbinding workdirを分け、既存workdirを上書きしない。legacyでも別workdirに各patchを適用しcmake build/install後、同じbindingビルダを使用する。全11extensionを各native prefixへリンクし、backendを同一プロセスに混在させない。

## 結果

| 範囲 | legacy | grouped |
|---|---:|---:|
| 公開API最終テスト | 16 tests / 175 assertions、成功 | 16 tests / 175 assertions、成功 |
| snapshot・mdta・metadata・画像・チャプター対象テスト | 69 tests / 580 assertions、成功 | 69 tests / 585 assertions、成功 |
| 全体Test::Unit（追加mux専用テスト前） | 284 tests / 1105 assertions、既存1 failure、10 omissions | 284 tests / 1110 assertions、既存1 failure、10 omissions |
| 別プロセスMinitest | 12 runs / 54 assertions、成功 | 12 runs / 54 assertions、成功 |

全体テストの既存failureはtest/mp4_items_test.rb:171の借用wrapper数（期待14、実測15）。実装前HEADでも再現済みで、今回変更による新規failureではない。別件の実装・テストを弱める変更は行わない。10 omissionsはMListNewソース・専用ENVが必要な試作probe。実装公開APIの受入テストは省略していない。追加muxテストは全体実行後に両backendで対象範囲を再検証した。

旧native（従来0001のみ）でも新bindingの全11extensionをビルドでき、capabilitiesがfalse / native_snapshot_api_unavailable、captureがunsupported_captureになることを確認。既存mdta/metadata/画像の21 tests / 213 assertions成功。

新grouped nativeに既存C++ probeを再リンクし、19 Python tests / 40 native cases / 369 assertions成功。一キーAPI・構造拒否・保存故障・画像・チャプター・mediaの既存契約を確認した。

### 公開APIで確認した内容

- 全9通常Item型、atomDataType、freeform binary、2画像、mdta同一/異locale、異型、重複、NUL、空binary、順序、最大unsigned値を保存・再読込で比較。
- 元Fileを閉じGCした後もdeep frozen snapshotが利用できる。
- 別keys表へ復元し、既存index保持・新キー追加・不要キーの値削除・key-only保持・3回保存の冪等性を確認。
- 不正入力、保存幅を超えるtmpo、未知item、native後半で拒否する候補で編集状態・借用wrapperを維持。
- 一時保存後の故障は元ファイルhash不変、committed=false、編集状態を維持して再試行成功。
- rename後reopen故障はcommitted=true / phase=:reopen。独立再読込で値一致し、snapshotは引き続き利用可能。
- zero index、handler不整合、通常text NUL、通常atom重複、通常locale、scalar複数値を診断し、取得・復元を拒否。診断でdiskを変更しない。
- mdirで通常metadata往復に成功し、mdirへのmdta新設は拒否。
- 字幕mux（既存字幕を2streamへ複製）とaudio AAC再変換後へ公開APIで復元。タグ・画像・mdta論理値が一致し、字幕codec/extradata、language/title/disposition、順序付きpayload/有理数時刻と重複streamを保持。FFmpegは-write_btrt 0を明示し、元合成MP4のhash不変。
- メモリ復元成功ではItemMap wrapperを維持し、古い借用Itemを無効化。save時は従来どおりclose/reopenでnative wrapper寿命が切れる。

## 引き渡しと限界

最低実装versionは2.3.2.8。native機能検出はtag.metadata_capabilities[:snapshot_v1] / [:atomic_restore_v1]、対象構造はtag.metadata_diagnostics.restorable?で確認する。respond_to?だけでnative能力を判定しない。

metadataだけを管理対象として置換する。未知atom完全コピー、subtitle codec全種類、チャプター復元、上流正式採用、Intel/他OS・配布artifact、一般電源断の永続化は未検証/保証対象外。字幕mux/音声変換・字幕保持判定・原本置換・修復の適用判断はMListNewの責務。

詳細契約は[設計](../mp4-metadata-snapshot-design.md)、判断理由は[ADR](../ADR/2026-10-08-mp4公開snapshotの実装.md)。

## 2026-10-09: リファクタリング後の検証

Ruby snapshot構築・診断・復元候補と内部保存比較の重複を整理。native/bindingパッチは変更していない。

- 構文チェック・空白チェック成功。
- 両backendでsnapshot/mdta置換/metadata/画像/チャプターの47 tests / 421 assertions成功。
- 旧nativeの既存API: 21 tests / 213 assertions成功。公開snapshotは従来どおりunsupported_capture / phase=captureで拒否。
- 全体Test::Unitはlegacy 285 tests / 1126 assertions、grouped 285 tests / 1131 assertions。各既存wrapper数の1 failureのみ、0 errors、手動probeの10 omissions。

全体検証は変更が揃った後に各backendで一度実施。原本・MListNew・TagLib C++本体・インストール済みgemは変更していない。
