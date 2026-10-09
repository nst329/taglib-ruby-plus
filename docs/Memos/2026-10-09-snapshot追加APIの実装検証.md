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

[設計](../../Docs/mp4-snapshot-extensions-design.md) / [実装ADR](../../Docs/ADR/2026-10-09-snapshot追加APIの実装と検証後の見直し.md)

製品実装・設計・ADR・受入テスト・新native patch・patch適用補助はgemspecの明示的なファイル一覧にも追加した。
