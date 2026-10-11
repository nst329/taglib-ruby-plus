# snapshot追加APIの実装検証

2026-10-09。macOS arm64、Ruby 4.0.7。version 2.3.2.9。実動画原本・MListNew・インストール済みgemは変更していない。

## 隔離環境と再現

copyright-cpy-{legacy,grouped}/sourceに新native patchの4atom登録を反映し、cmake --build / --installを実行した。
既存bindingはAPI/ABI変更なしでこのnativeへリンクし、現行lib・test・tasksをsnapshot-extensions-final-{legacy,grouped}へコピーした。
リポジトリの通常bundleは旧nativeなので混在させず、隔離workdirで実行する。

```sh
cd /private/tmp/snapshot-extensions-final-legacy
MDTA_BINDING_LIB=$PWD/lib MDTA_BINDING_LAYOUT=legacy /opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/mp4_snapshot_edit_diff_test.rb test/mp4_snapshot_extensions_test.rb test/mp4_copyright_test.rb test/mp4_metadata_snapshot_test.rb test/mp4_metadata_api_test.rb test/mp4_mdta_replace_test.rb test/mp4_mdta_binding_adapter_test.rb test/mp4_mdta_taglib_test.rb test/mp4_chapters_test.rb
MDTA_BINDING_LIB=$PWD/lib MDTA_BINDING_LAYOUT=legacy /opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].sort.reject { |path| File.read(path).include?("minitest/autorun") }.each { |path| require_relative path }'
MDTA_BASELINE=/private/tmp/mdta-baseline MDTA_IO_FAULT=/private/tmp/mdta-io-fault /opt/homebrew/opt/ruby/bin/ruby -I. -Ilib -Itest -e 'require_relative "test/mp4_mdta_atom_probe_test"; require_relative "test/mp4_mdta_design_contract_test"'
```

groupedも対応workdir・layoutに替えて同じ範囲を実行。

## 結果

| 範囲 | legacy | grouped |
| --- | --- | --- |
| 関連範囲 | 81 tests / 838 assertions成功 | 81 tests / 843 assertions成功 |
| native patch適用補助 | 2 tests / 15 assertions成功 | 同じRuby共通処理 |
| 全体Test::Unit | 302 tests / 1418 assertions、1既知failure、0 errors、10 omissions | 302 tests / 1423 assertions、1既知failure、0 errors、10 omissions |
| 別プロセスMinitest | 12 runs / 54 assertions成功、0 skips | 12 runs / 54 assertions成功、0 skips |

構文・空白・文書リンク検査成功。新規sourceコピーにlegacy/grouped各patch列を順次apply --check/applyし、mp4tag.cpp/mp4tag.h/mp4itemfactory.cpp/mp4metadatahelpers.hが検証nativeとbytes一致。
全体Test::Unitは変更が揃い関連テスト成功後に各backendで1回。文書更新だけで再実行していない。

## 発見した問題と見直し

- title=の共通定義化で新binding helperを検討したが、インストール済みSWIG 4.5.1は既存ItemMap templateの旧scopeを拒否。原因は既存wrapper生成時の4.1.1との規則差。新helperを追加する必要自体を見直し、既存native文字列変換とItemMap処理を再利用してbinding変更をなくした。scope回避コードは追加していない。
- 初回のRuby title=からSWIG内部名__setitem__を呼ぶ試作はNoMethodError。公開側の既存ItemMap.insertへ統一し、nil/空文字/日本語別encoding/NUL/to_strをbase Tagのvirtual native setterと比較して一致を確認。
- ldes/keyw/purdはmdta構造のknown atom検査でunsupported_item。native Text登録を追加し、全propertyの更新・削除影響を実差分で照合できるようにした。
- contentRatingのfreeform atom型255がwriterで1に変わり、保存前snapshot診断が拒否。set_propertiesでfreeform文字列型1を明示して解消。snapshotに暗黙補完は追加していない。
- 第3patchが独立したため、最後のpatchだけのreverse確認では既存snapshot列を安全に更新できない。snapshotの重複hunkを識別する適用補助へ変更し、新規・更新・再実行を検証。
- diffの別型入力は既存MetadataSnapshotError（ArgumentError派生）を使う。テストは具体的な例外型と契約を確認する形に整理。

## 既知の全体テスト失敗

mp4_items_test.rb:171の借用wrapper数。全体では期待14/実測15。
変更前HEADのlib/testを新規archiveし、変更前nativeの両backendで同じテストを単独再現すると期待13/実測14で失敗する。差はどちらも余分なwrapper1個。
既存記録でも再現済み。今回の設計の原本保持・型保持と切り分け、テストを弱めず未解決として残した。
手動probeの10 omissionsはMListNew専用ENV不足。製品APIの新規受入テストには省略なし。

## 確認した契約

deep freeze・元snapshot不変、全9Item種の差分空判定、型/locale/順序/値数/画像format/追加削除の説明、binary/hash表示・長文制限、不正入力・index上限拒否。
mdir/mdtaの©cpy複数値保持・単一値更新・削除・cprt/mdta/画像保持・不正入力の原本不変。
全propertyとremoveの実影響、show別名、未対応native setter拒否、title=従来変換一致。
保存前の許可外変更拒否、原本hash不変、編集状態を期待snapshotへ戻した再試行成功。
既存snapshotの字幕/audio変換・全Item型・故障注入、mdta置換、metadata、画像、chapter回帰も成功。

[設計](../mp4-snapshot-extensions-design.md) / [実装ADR](../ADR/2026-10-09-snapshot追加APIの実装と検証後の見直し.md)

製品実装・設計・ADR・受入テスト・新native patch・patch適用補助はgemspecの明示的なファイル一覧にも追加した。

## 内部整理後の検証

2026-10-09。macOS arm64、Ruby 4.0.7。APIとversion 2.3.2.9の契約を維持。

### 範囲と再現

lib/taglib/mp4_metadata_snapshot.rbとlib/taglib/mp4.rbの内部責務整理。
現行lib/test/tasksをsnapshot-extensions-refactor-{legacy,grouped}へ新規コピーし、検証済みnativeへリンクするcopyright-cpy-binding-{backend}/libのbundleを使用した。
native source・インストール済みgem・原本・MListNewは変更していない。

```sh
cd /private/tmp/snapshot-extensions-refactor-legacy
MDTA_BINDING_LIB=$PWD/lib MDTA_BINDING_LAYOUT=legacy /opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e 'ARGV.each { |path| require_relative path }' test/mp4_snapshot_edit_diff_test.rb test/mp4_snapshot_extensions_test.rb test/mp4_copyright_test.rb test/mp4_metadata_snapshot_test.rb test/mp4_metadata_api_test.rb test/mp4_mdta_replace_test.rb test/mp4_mdta_binding_adapter_test.rb test/mp4_mdta_taglib_test.rb test/mp4_chapters_test.rb
```

groupedも対応workdirとlayoutで同じ範囲を実行。

| backend | tests | assertions | failures | errors | omissions |
| --- | ---: | ---: | ---: | ---: | ---: |
| legacy | 81 | 838 | 0 | 0 | 0 |
| grouped | 81 | 843 | 0 | 0 | 0 |

構文・空白・文書リンク検査成功。検証済み対象コードの変更後に関連テストを実行し、テスト中のコード変更なし。
source gemも再生成し、gemspecのファイル一覧がGit管理対象と新規ファイルに一致することを確認。
全体テスト・Minitest・native patch列は今回変更していないため、前回成功した範囲を繰り返していない。全体の既知wrapper数failureは本書の実装検証を参照。

[判断ADR](../ADR/2026-10-09-snapshot追加APIの内部責務整理.md)

## 先行試作の記録

以下は試作時点の結果です。未実装・未検証の記述は当時の状況であり、製品実装の検証結果は本書の前半を参照してください。

2026-10-09の試作時点の記録。Ruby 4.0.7、macOS。合成MP4のみ使用。

試作ファイルは製品実装時に公開APIの受入テストへ置換した。現在の再現手順は本書の実装検証を参照。

### 手順

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

### 失敗から特定した原因

- リポジトリの通常bundleはsnapshot_v1=false。既存隔離nativeビルドを使い、現行Ruby層を合わせた。
- ©cpyをfixtureに入れるとlegacyはcaptureを拒否、groupedは一時保存を拒否。両nativeのmp4itemfactory.cppではCOPYRIGHT=cprt。fixtureをcprtへ変更し、©cpy復元候補の明示拒否テストを追加した。
- Ruby subclassのUnboundMethodを元Tagへbindする試作はTypeError。通常のmodule拡張へ直した。製品APIへの影響なし。
- ©namのatom_data_type=1を指定した候補はunsupported_item。既存native Itemの形式255で成功。型推測や補完は行わない設計に反映。

### 結果と限界

部分編集の不変性、型付きmdta・画像保持、値除外、論理差分、setterの実影響、copyright単一値更新、許可外変更のrename前拒否を検証した。
詳細field分類付きdiff、全setter、copyrightのproperties列挙、実ファイルの©cpy運用、全9Item型と字幕の追加API組合せは未検証。
製品コード変更がないため全体テストは実行していない。

[設計](../mp4-snapshot-extensions-design.md) / [ADR](../ADR/2026-10-09-snapshot追加APIの試作結果に基づく設計.md)

### ©cpy必須要件を受けた追加試作

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
