# MP4公開snapshotの設計試作検証

日付: 2026-10-08。合成実MP4と一時ディレクトリのみ使用。MListNew、TagLib C++本体、インストール済みgem、実動画原本は変更していない。

## 環境と実行

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

## 成功した動作と限界

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

## 反例から変更した設計

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

## 完了条件と未実装の区別

確認事項の設計判断は確定した。API名、全体置換、論理/構造比較、空values、index維持、字幕の厳密比較、修復との分離を[設計](../mp4-metadata-snapshot-design.md)へ反映した。利用者へ追加の仕様質問はない。

今回の成功はテスト専用probeの結果。atomDataTypeのRuby接続、keys全体のRuby接続、native全体commit/clear-values、詳細diagnostics、capabilitiesは未実装。これらの完成実装に対する故障注入と配布artifact検証は実装時の受入項目であり、試作だけで検証済みと扱わない。未知atomの完全保存、全codec、全OS/ABI、一般I/O永続化保証も証明していない。

後続の公開API実装と受入結果は[実装検証](2026-10-08-mp4公開snapshotの実装検証.md)を参照。この記録の未実装事項は試作時点の状況。
