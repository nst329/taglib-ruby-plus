# snapshot追加APIの試作検証

2026-10-09の試作時点の記録。Ruby 4.0.7、macOS。合成MP4のみ使用。

試作ファイルは製品実装時に公開APIの受入テストへ置換した。現在の再現手順は[実装検証](2026-10-09-snapshot追加APIの実装検証.md)を参照。

## 手順

現行libのRubyファイルを新規/private/tmp/snapshot-extensions-{legacy,grouped}/libへコピーし、既存snapshot-binding-{legacy,grouped}/libのbundleを各対応先へコピー。backendは別プロセスで実行。

```sh
ruby -c test/support/mp4_snapshot_extensions_probe.rb
ruby -c test/mp4_snapshot_extensions_probe_test.rb
MDTA_BINDING_LIB=/private/tmp/snapshot-extensions-legacy/lib /opt/homebrew/opt/ruby/bin/ruby test/mp4_snapshot_extensions_probe_test.rb
MDTA_BINDING_LIB=/private/tmp/snapshot-extensions-grouped/lib /opt/homebrew/opt/ruby/bin/ruby test/mp4_snapshot_extensions_probe_test.rb
```

| backend | tests | assertions | failures | errors | omissions |
| --- | ---: | ---: | ---: | ---: | ---: |
| legacy | 7 | 77 | 0 | 0 | 0 |
| grouped | 7 | 77 | 0 | 0 | 0 |

## 失敗から特定した原因

- リポジトリの通常bundleはsnapshot_v1=false。既存隔離nativeビルドを使い、現行Ruby層を合わせた。
- ©cpyをfixtureに入れるとlegacyはcaptureを拒否、groupedは一時保存を拒否。両nativeのmp4itemfactory.cppではCOPYRIGHT=cprt。fixtureをcprtへ変更し、©cpy復元候補の明示拒否テストを追加した。
- Ruby subclassのUnboundMethodを元Tagへbindする試作はTypeError。通常のmodule拡張へ直した。製品APIへの影響なし。
- ©namのatom_data_type=1を指定した候補はunsupported_item。既存native Itemの形式255で成功。型推測や補完は行わない設計に反映。

## 結果と限界

部分編集の不変性、型付きmdta・画像保持、値除外、論理差分、setterの実影響、copyright単一値更新、許可外変更のrename前拒否を検証した。
詳細field分類付きdiff、全setter、copyrightのproperties列挙、実ファイルの©cpy運用、全9Item型と字幕の追加API組合せは未検証。
製品コード変更がないため全体テストは実行していない。

[設計](../../Docs/mp4-snapshot-extensions-design.md) / [ADR](../../Docs/ADR/2026-10-09-snapshot追加APIの試作結果に基づく設計.md)

## ©cpy必須要件を受けた追加試作

初期のcprtだけを追加する案は撤回した。初回拒否はiTunes形式での©cpy不要を意味せず、mdta構造の既知atom判定に登録されていないことが原因。
ItemFactory::nameHandlerMapへ©cpyのText handlerを1行追加すると両backendで保存・取得・復元が成功した。

再現用patch: test/support/mp4-copyright-cpy-prototype.patch。
各snapshot-native-{legacy,grouped}/sourceをcopyright-cpy-{legacy,grouped}/sourceへ新規コピーしpatchを適用。
cmakeはDebug/shared、BUILD_TESTING=OFF/BUILD_EXAMPLES=OFF、install prefixは各copyright-cpy-{backend}/install。
既存test/support/build_mp4_mdta_binding.pyで各nativeに対するbindingをcopyright-cpy-binding-{backend}へ新規ビルドした。

```sh
MDTA_BINDING_LIB=/private/tmp/copyright-cpy-binding-legacy/lib /opt/homebrew/opt/ruby/bin/ruby -I/private/tmp/copyright-cpy-binding-legacy/lib -Itest -e 'ARGV.each { |path| require_relative path }' test/mp4_copyright_design_probe_test.rb test/mp4_metadata_snapshot_test.rb test/mp4_metadata_api_test.rb test/mp4_mdta_replace_test.rb
MDTA_BINDING_LIB=/private/tmp/copyright-cpy-binding-grouped/lib /opt/homebrew/opt/ruby/bin/ruby -I/private/tmp/copyright-cpy-binding-grouped/lib -Itest -e 'ARGV.each { |path| require_relative path }' test/mp4_copyright_design_probe_test.rb test/mp4_metadata_snapshot_test.rb test/mp4_metadata_api_test.rb test/mp4_mdta_replace_test.rb
```

両backend: 各37 tests / 424 assertions、failure/error/omissionなし。copyright単独は3 tests / 55 assertions。
mdir/mdta両構造、日本語/空文字/重複の©cpy複数値、更新/削除、cprt/mdta/画像保持、不正入力拒否、snapshot復元を確認した。
既存snapshotテストの字幕・全Item型・故障注入も対象範囲に含まれる。

元のextensions probeにある©cpy拒否テストは未登録nativeの検証として残し、追加patch適用済みnativeの試験対象からは除いた。製品APIのコードは未変更。
