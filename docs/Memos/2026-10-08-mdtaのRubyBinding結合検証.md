# mdta Ruby binding結合検証

日付: 2026-10-08

## 実装範囲

「本体へ適用しない」はTagLib C++本体への適用を指す。Ruby binding関連は実装対象。以下を実装し、一時コピーに対してビルド・結合検証した。

- extconfによるgrouped/legacy APIのリンク検査と自動選択。
- 共通mdta_adapter.hによるgrouped snapshot→既存Ruby MdtaItem列、Ruby値配列→MdtaValueListへの変換。
- 既存set_mdta_itemの単一値置換、title/artist fallback、remove_mdta_itemの既存のself返却。
- mdta_statusの公開。groupedはabsent/editable/unsupported、legacyはunknown。
- binding用native状態移送パッチ0002。raw、keys/index、変更キー、削除、通常itemを転送し、宛先FileのAtom参照を保持する。
- 曖昧な新規fourCCを上流提案writerで書込前に拒否する検証の追加。

C++本体、システムライブラリ、原本動画、リポジトリの既存extensionバイナリは変更していない。更新したC++はRuby extensionソースと、適用前の提案パッチ成果物。一時コピーでのみnativeパッチを適用した。

## 結果

| 検証 | grouped（提案＋状態移送） | legacy（既存ローカルパッチ） |
| --- | --- | --- |
| mdta対象テスト | 30件成功 | 30件成功 |
| 新adapter専用 | 4件・31アサーション成功 | 4件・25アサーション成功 |
| Test::Unit全体 | 259件・956アサーション、既知失敗1件 | 259件・951アサーション、既知失敗1件 |
| Minitest | 12件・54アサーション成功、skipなし | 12件・54アサーション成功、skipなし |

全体の残る失敗はtest/mp4_items_test.rb:171の借用wrapper追跡数。groupedでは14→15、legacyでは13→14で、いずれも基準より1多い。変更前にも同じ失敗を隔離再現済み。期待値を緩めず記録する。

今回のnative変更に対応する連続保存・ItemMap直接変更の2ケースも再実行し、61アサーション成功。両パッチを原始ソースへ適用したコピーと、コンパイルしたnative実装の8ファイル一致を確認した。

検証は合成MP4とfixtureコピーのみ。複数値、NUL/空payload、重複・型・locale・index・順序、通常タグ・画像・字幕・chapterの維持、保存失敗時の原本保護、反復保存、プロパティ正規化と削除を既存対象テストで確認した。

最初の検証で内部のASCIIキーのUTF-8化漏れを修正した。新テストでのfrozen dataとremoveの返却値の期待は、既存Ruby契約に合わせて修正した。未知fourCCについては回避策を足さず、合意した非対応範囲として事前拒否を確認するテストにした。

## 再現手順

原始TagLib 2.3.2のHEADを持つbase-sourceを指定する。workdirには未作成の一時パスを指定する。Python 3.12以上、git、cmake、C++17、utf8cpp、Rubyと既存テスト依存gem、FFmpeg/FFprobeが必要。

```sh
python3 test/support/build_mp4_mdta_upstream_probe.py \
  --base-source /private/tmp/taglib-2.3.2 \
  --workdir /private/tmp/mdta-native-for-ruby-new \
  --ruby-state-transfer
python3 test/support/build_mp4_mdta_binding.py \
  --native-prefix /private/tmp/mdta-native-for-ruby-new/install \
  --workdir /private/tmp/mdta-ruby-check-new
cd /private/tmp/mdta-ruby-check-new
MDTA_BINDING_LAYOUT=grouped /opt/homebrew/opt/ruby/bin/ruby -Ilib -Itest -e '
  require_relative "test/mp4_mdta_replace_test"
  require_relative "test/mp4_mdta_taglib_test"
  require_relative "test/mp4_mdta_binding_adapter_test"
'
```

legacy確認ではnative-prefixを既存ローカルパッチ版へ変更し、別workdirを使いMDTA_BINDING_LAYOUT=legacyとする。builderはlib/ext/testをコピーし、SWIG再生成を行わず、全extensionを同じnative prefixへリンクする。生成済みwrapperはSWIG入力と同期済み。既存SWIG再生成のtemplateエラーはこの結合検証の経路に含めない。

全体テストは次のコマンドでMinitestファイルを分けて実行した。

```sh
ruby -Ilib -Itest -e '
  Dir["test/**/*_test.rb"].sort.reject { |f| File.read(f).include?("minitest/autorun") }
    .each { |f| require_relative f }
'
MDTA_BASELINE=/private/tmp/mdta-baseline MDTA_IO_FAULT=/private/tmp/mdta-io-fault \
  ruby -Ilib -Itest -e '
    require_relative "test/mp4_mdta_design_contract_test"
    require_relative "test/mp4_mdta_atom_probe_test"
  '
```

baseline/io-faultは先行ローカル実装で用意したnative手動probeであり、プロセスを分けて実行する。恒久的なテスト証拠は本記録とソース。一時ログは/private/tmp/mdta-ruby-{grouped,legacy}-full-test.log、同adapter-final-test.log、同minitest.log。

## MListNewでの使用

既存Ruby APIは維持する。restore先がgroupedのeditable構造であることを確認し、退避したflat列をキー単位で一括置換する。

```ruby
raise TagLib::MP4::MdtaItemError, 'unsupported mdta destination' unless tag.mdta_status == :editable
backup.group_by(&:key).each do |key, entries|
  tag.replace_mdta_items(key, entries.map { |item|
    { data_type: item.data_type, locale: item.locale, data: item.data }
  })
end
file.save
```

退避時もmdta_statusを確認する。unsupportedやunknownの空/部分一覧を完全なバックアップとして扱わない。absentはmdtaなしとして記録できるが、mdir-onlyへmdtaを新設する機能はない。退避元indexを復元先へ強制せず、既存index維持・新規キー末尾追加となる。

Rubyの必要版は今回のソース変更を含むtaglib-ruby-plus 2.3.2.7。grouped APIを使う場合のnative要件はTagLib 2.3.2基準＋提案0001＋binding用0002。未リリースの上流機能にリリース番号は付けない。既存legacyパッチでも一括置換を利用できるが、mdta_statusによる分類はunknownとなる。

flush/close失敗や電源断、一般IOStreamの全失敗に対するnative原子性は保証しない。原本保護はRubyの一時コピー・独立再読込照合・置換で維持する。本体への取り込みは将来の判断事項であり、binding接続・結合テストは今回完了した。

## リファクタリング後の確認

共通Hash変換、明示的なAPI probe、title/artist fallbackを整理した後、両backendのMP4 extensionを再構成・再ビルドした。対象30テストはgroupedで299アサーション、legacyで294アサーション、いずれも失敗・エラーなし。ログは `/private/tmp/mdta-refactor-{grouped,legacy}-target-test.log`。

空白を整理した提案パッチ0001・0002を新しい一時コピーへ適用し、検証済みnativeソース8ファイルとバイト単位で一致した。変更範囲の対象テストを再実行し、全体テストは上記の結果を維持する。
