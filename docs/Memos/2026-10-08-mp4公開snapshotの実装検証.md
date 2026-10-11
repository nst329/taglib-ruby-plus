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

## 先行試作の記録

以下は試作時点の結果です。未実装・未検証の記述は当時の状況であり、製品実装の検証結果は本書の前半を参照してください。

日付: 2026-10-08。合成実MP4と一時ディレクトリのみ使用。MListNew、TagLib C++本体、インストール済みgem、実動画原本は変更していない。

### 環境と実行

macOS arm64、Ruby 4.0.7、FFmpeg n9.0.2（libavformat 63.1.102）。既に隔離ビルド済みのgrouped（TagLib 2.3.2＋提案0001＋binding0002）とlegacy（ローカルmdtaパッチ）の全extensionをそれぞれ独立プロセスで使用した。

```sh
MLIST_ROOT=/Users/nasu/Projects/MListNew MDTA_PROBE_LIB=/private/tmp/mdta-ruby-grouped-binding/lib /opt/homebrew/opt/ruby/bin/ruby test/mp4_snapshot_design_probe_test.rb
MLIST_ROOT=/Users/nasu/Projects/MListNew MDTA_PROBE_LIB=/private/tmp/mdta-ruby-legacy-binding/lib /opt/homebrew/opt/ruby/bin/ruby test/mp4_snapshot_design_probe_test.rb
```

bindingの再作成にはtest/support/build_mp4_mdta_binding.pyと既存の[結合検証記録](2026-10-08-mdtaのRubyBinding結合検証.md)を参照。MLIST_ROOTはタグsnapshotクラスの実装を読むためだけに使う。環境指定がない通常テスト実行では本手動probeをomitする。

Ruby probeは10テスト。最終結果はgrouped 102アサーション、legacy 101アサーション、両方失敗・エラーなし。ログは `/private/tmp/mp4-snapshot-design-{grouped,legacy}.log`。

```sh
c++ -std=c++17 -I/private/tmp/mdta-upstream-implementation-1/install/include -L/private/tmp/mdta-upstream-implementation-1/install/lib -Wl,-rpath,/private/tmp/mdta-upstream-implementation-1/install/lib test/mp4_snapshot_native_design_probe.cpp -ltag -o /private/tmp/mp4-snapshot-native-design-probe
/Users/nasu/Bin/ffmpeg -y -v error -i /private/tmp/snapshot-subtitle-analysis/source.mp4 -map 0 -c copy -movflags use_metadata_tags -metadata first=fixture /private/tmp/snapshot-native-fixture.mp4
/private/tmp/mp4-snapshot-native-design-probe /private/tmp/snapshot-native-fixture.mp4
```

native probeはatomDataType欠落、keys詰め直し、default Tagの編集拒否の3条件を確認しPASS。source.mp4は色映像・sine音声・SRT字幕をlibx264/aac/mov_textで合成した一時fixture。新環境ではRubyテストのsetupと同じFFmpeg入力から作成する。

### 成功した動作と限界

- Ruby所有の深いコピーはsource closeとGC後も使え、深い値の変更を拒否する。
- 通常item全9型（画像を含む）、mdtaの異型・locale・重複・NUL・空バイナリを、実MP4保存・再読込で論理比較した。
- 別出力への一括候補編集と繰返し保存は論理一致する。index一致は現行削除で破れる反例として別に検証した。
- 最後のキーで注入した失敗/不正型は、保存先のpending item・mdta・dirty状態・原本hash・借用ItemMapの値を変更しない。
- tmpoへ65536を設定するとRuby intでは保持できてもnative writerで16bitへ切り詰められる。既存再読込検証が:verify/committed=falseで拒否し、原本とpending値は維持する。公開restoreではこのキーと型の組を事前検証する。
- set_propertyのtitle/artist/description/TVShowNameは対応mdtaを削除し、通常値を作る。native title=は両backendともtitle mdtaを残す。
- mov_textのsample hash・有理数timing・codec設定・言語・dispositionを比較。音声再encodeの前後とgem通常保存後に一致する経路を確認した。
- 字幕の複製を2本として数え、脱落・重複数違い・timing違いを検出する。default muxのcodec設定変更も検出する。
- zero indexでgroupedのunsupportedと一括置換拒否を確認。legacyはunknownだが置換を拒否する。診断/拒否で原本hashは不変。

試作restoreはFileに所有された候補Tagへ変更を集め、既存copyStateToで一回移送した。本番APIでも追加Fileをopenする提案ではない。native内部で構造文脈を維持した候補を作る設計の実現性を検証した。

### 反例から変更した設計

| 反例 | 設計への反映 |
|---|---|
| Item::typeとpayloadが同じでもatomDataTypeが違う | 通常itemへatom_data_typeを追加しbindingから観測する |
| removeMdtaItemはkeysを詰め、残るindexを変える | 一括復元はキーを残すclear-valuesをnativeへ追加 |
| keysのみのentryはflat一覧に出ない | grouped keys全体と空valuesを公開snapshotへ含める |
| default Tagへ状態移送するとilst参照がなくUnsupported | native内部候補で実Tagの構造文脈を使う |
| MListNewのpreserved_by?は同一キーの並べ替えを受理 | 論理比較でキー内の順序を比較する |
| FFmpeg字幕コピーでextradataが変わる | 不一致は厳密に拒否し、無条件にhashを除外しない |

FFmpegの差分をhexで調べ、mov_text設定の末尾btrt boxの追加/重複が原因と確認した。設定を勝手に正規化しない。-write_btrt 0で生成・コピーしたfixtureは設定も一致する。オプション採用と既存入力の扱いはMListNewの責務。

MListNew実ファイルのtest_multiple_values_after_existing_mux_are_detected_not_acceptedを確認した。さらに実際のMp4TagMetadataSnapshot.capture/restore_toを合成fixtureに適用し、5値が最後の1値になることを両backendで再現した。公開snapshot試作のキー単位replaceでは全値を保持する。元の限定修復テスト全体は依存環境を変更して実行せず、読取と独立再現で確認した。

### 完了条件と未実装の区別

確認事項の設計判断は確定した。API名、全体置換、論理/構造比較、空values、index維持、字幕の厳密比較、修復との分離を[設計](../mp4-metadata-snapshot-design.md)へ反映した。利用者へ追加の仕様質問はない。

今回の成功はテスト専用probeの結果。atomDataTypeのRuby接続、keys全体のRuby接続、native全体commit/clear-values、詳細diagnostics、capabilitiesは未実装。これらの完成実装に対する故障注入と配布artifact検証は実装時の受入項目であり、試作だけで検証済みと扱わない。未知atomの完全保存、全codec、全OS/ABI、一般I/O永続化保証も証明していない。

後続の公開API実装と受入結果は本書の実装検証を参照。この記録の未実装事項は試作時点の状況。
