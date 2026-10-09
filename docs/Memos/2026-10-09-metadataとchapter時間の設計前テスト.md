# metadataとchapter時間の設計前テスト

## 順序と変更範囲

ユーザーの「テストコードで検証してから設計」に従い、現行の製品コードを変更せず、調査テストとテスト内の試作を作成・実行した。結果が揃った後に設計とADRを作成した。前段の複数tref実装とは別の調査であり、今回の新規変更はtest/supportと文書だけである。

- test/mp4_repair_investigation_test.rb: 現行の失敗、原因の再現、候補処理の検証。
- test/support/mp4_investigation_fixture.rb: 独立atom parser、境界検証、moovだけの編集、stco/co64補正とmdat逐次コピー。

実ファイルの時間atomと原本は変更していない。実ファイルを使用するテストはMP4_REPAIR_REAL_FILE指定時だけ実行し、test作業ディレクトリへコピーする。fixture編集は作業ディレクトリ外のpathと外部symlinkを拒否する。

## 環境

macOS arm64、Ruby4.0.7、FFmpeg/ffprobe n9.0.2。現在のRubyコードと対応済みnative bundleを配置した隔離libを使用した。

otool -Lで実際の依存を確認した：

- legacy: /private/tmp/copyright-cpy-legacy/install/lib/libtag.2.dylib
- grouped: /private/tmp/copyright-cpy-grouped/install/lib/libtag.2.dylib

sourceの確認対象は各prefixのsource/taglib/mp4/mp4qtchapterlist.cppとmp4tag.cpp。現行writerのコードと動作を確認したもので、上流個別コミットの比較・取込みはしていない。

## 最終結果

| 検証 | 結果 |
|---|---|
| 合成fixture / legacy | 19 tests / 134 assertions、失敗0・エラー0・実ファイル指定なしのomission1 |
| 合成fixture / grouped | 19 tests / 134 assertions、失敗0・エラー0・実ファイル指定なしのomission1 |
| 実ファイルコピー / legacy（対象テスト単独） | 1 test / 26 assertions、失敗0・エラー0 |
| 実ファイルコピー / grouped（対象テスト単独） | 1 test / 23 assertions、失敗0・エラー0 |
| 新規Ruby2ファイルの構文チェック | 成功 |
| git diff --check | 成功 |

backendによる実ファイルassertion数の差は、legacyがverify段階でmetadataの差を観測し、groupedがその前のnative保存で拒否するため。いずれも期待する失敗と原本保護、試作での保存成功を検証している。

製品コードを今回変更していないため、成功済みの既存関連テストや全体テストは繰り返していない。前段全体テストのborrowed wrapper不一致を解消した結果ではない。

## metadataの検証

1. 正常index1/2、同一キーの複数値、通常titleの混在は保存できる。
2. 不正index0が2件あると、legacyは空文字キー1件に潰し、writerは落とす。verifyが拒否し、原本とrawの2件は保持される。
3. groupedは0 itemを公開viewへ出さず、native saveがUnsupportedで拒否する。原本は保持される。
4. 非0の範囲外indexも診断され、完全snapshotが拒否される。位置による割当は行われない。
5. keys順を逆にしても0 itemのnative viewは同じ。native viewだけからキー対応を復元できない。
6. 保存後にhandler/keys/0 itemを戻すだけの試作はlegacyでは成功するがgroupedではnative保存前に止まる。
7. 一時コピーだけをmdir作業用contextにし、型付き通常itemを復元してnative保存した後、元rawを戻す二段階試作は両backendで成功する。
8. 試作で2件目の0 itemを落とす故障を注入しても、現行native snapshot検証は通る。raw保持signatureが必要である。

実ファイルコピーでも、現行saveの失敗を再現した後、二段階試作でtitle変更が保存できた。元のhandler/keys/0 itemのraw bytesが一致し、保存後のchapter_snapshotは15章、原本SHA-256は不変。

テスト内の試作は検証用であり、汎用の保持処理・本番APIではない。製品化時の対応条件・raw保持signature・故障拒否は別途実装する。

## 時間情報の検証と原因

高timescaleのmvhdだけを設定した合成入力を、未変更native writerへ渡して15章を生成させた。chapterのtkhd/mdhd/elst/sttsは手で注入していない。それでも両backendで実ファイルと同じ値になり、ffprobe通常設定で1章、ignore_editlistで16サンプルを返した。

- movie duration: 1605653349300 / 441000000 = 3640.937300秒。
- mdhd/stts: 3640937 / 1000 = 3640.937000秒。
- tkhd: media単位の3640937がmovie単位の欄へ書かれる。
- elst: movie durationをunsigned intへ縮めた0xd865c3b4がv0で書かれる。

readMovieInfoのduration格納とbuildChapterTrakのmovieDuration引数がunsigned int、tkhd書込がmedia totalDurationになっているコードと一致した。したがって、検証したwriterに対する生成原因は再現・特定できた。実ファイルの生成履歴まで証明したものではない。

mvhdとmediaは0.3ms差があり、mediaからの換算値1605653217000はmovie durationと完全一致しない。初期テストの「両者が厳密に等しい」という期待は失敗し、実数値とms丸めの事実を検証する期待へ直した。製品側へ許容幅を増やす回避策は入れていない。

## 補正候補とreader

既存writerがmovie全域の単一identity editを作る意図に合わせ、合成fixtureのtkhdとelstをv1にし、movie duration=1605653349300を使用した候補を検証した。mdhd/sttsの値、全mdatと15章は保持され、ffprobeで16サンプルが表示された。

ただし現行chapter_snapshotはv1 elstをunsupportedとして拒否することが分かった。テスト内だけのreader試作で、v1・単一entry・media_time=0・rate=1の限定読取を検証し、15章とmediaの一致を確認した。v1の非0 media_time、empty edit、speed変更、dwellは引き続き拒否する。

正常な短いedit、trim、empty edit＋active edit、反復edit、rate2、dwell、movieより短いmedia、mdhd/stts不一致、movie tick丸めも検証した。下位32bit一致だけで正常なcropを延長する判断はできない。

初期の補正候補テストは現行readerのv1拒否により失敗した。その失敗を明示的に確認するテストと、限定reader試作の検証へ分けた。現行製品が補正後のv1を既に読めるとは扱わない。

## 実行方法

合成fixture（隔離libには対応済みnative bundleと現在のRubyコードが必要）：

```sh
MDTA_BINDING_LIB=/private/tmp/taglib-multi-tref-validation/lib \
/opt/homebrew/opt/ruby/bin/ruby -Itest test/mp4_repair_investigation_test.rb
```

groupedはMDTA_BINDING_LIBを/private/tmp/taglib-multi-tref-grouped/libへ変更する。

実ファイルテスト（パスは対象原本へ置換。保存先はテスト用コピーに限定される）：

```sh
MP4_REPAIR_REAL_FILE='/path/to/010226_001.mp4' \
MDTA_BINDING_LIB=/private/tmp/taglib-multi-tref-validation/lib \
/opt/homebrew/opt/ruby/bin/ruby -Itest test/mp4_repair_investigation_test.rb \
  --name test_real_file_reference_repair_editlist_behavior_and_metadata_failure
```

現行writerの不整合を再現するテストは、writer修正後には「正常な64bit値が生成される」期待へ変更する。旧不整合の独立注入fixtureは診断・既存ファイル修復の回帰として残す。backend固有の失敗再現も製品実装後のAPI契約に合わせて整理する。

## 未検証

製品への新API組込み、raw保持signatureの拒否実装、新native writerビルド、実ファイルコピーへの明示的な時間補正、各保存段階・cleanup/replace/reopenの新経路故障、全プラットフォームは未実施。試作の成功を本番実装完了とはしない。

[採用設計](../mp4-unindexed-metadata-and-chapter-timing-repair-design.md) / [ADR](../ADR/2026-10-09-未対応mdtaのraw保持とchapter時間修復の分離.md)
