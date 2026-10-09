# snapshot値取得とchapter公開APIの実装検証

2026-10-09。Ruby 4.0.7 / macOS arm64。Ruby実装は2.3.2.10、nativeは既存の2.3.2.9 patched TagLib。native変更はない。

## 対象と再現

公開APIのtest/mp4_snapshot_access_chapter_test.rbへ試作を置換した。隔離libへ現行lib/taglibをコピーし、既存native bundle・dylibを使う。リポジトリのbundleは変更しない。

```sh
MDTA_BINDING_LIB=/private/tmp/snapshot-access-implementation/lib /opt/homebrew/opt/ruby/bin/ruby test/mp4_snapshot_access_chapter_test.rb
MDTA_BINDING_LIB=/private/tmp/snapshot-access-implementation-grouped/lib /opt/homebrew/opt/ruby/bin/ruby test/mp4_snapshot_access_chapter_test.rb
```

legacyは前回生成済みarm64 native gemのlibを元にした。groupedはsnapshot-extensions-final-grouped/libを元にした。各backendは別プロセスで実行。

| 検証 | tests | assertions | 結果 |
| --- | ---: | ---: | --- |
| 新公開API legacy・最終状態 | 18 | 248 | 成功 |
| 新公開API grouped・最終状態 | 18 | 248 | 成功 |
| 関連9ファイル legacy | 80 | 971 | 成功 |
| groupedの新API・編集差分・copyright | 27 | 377 | 成功 |
| 全体Test::Unit legacy | 318 | 1624 | 既知失敗1、omission10、error0 |
| Minitest | 12 | 24 | 成功、既存の手動probe5件skip |

全体は新API詳細diffのorder分類とNero flags拒否・一時出力診断エラーのphase調整前に1回実行した。その追加変更後は影響する新API18件だけを両backendで再検証した。全体を最終追加変更後の全体成功として扱わない。各検証中にソースは変更していない。

全体の唯一の失敗はMP4ItemsTestのborrowed wrapper tracking count（expected14/actual15）。前回2.3.2.9の実装検証でもHEADで再現済みの同じ失敗。今回の新機能に起因する失敗として扱わず、回避コードやskipは加えていない。10 omissionsはMListNewと隔離bindingを明示指定する歴史的手動probe。Minitestの5 skipsはMDTA_BASELINE/MDTA_IO_FAULT指定が必要な歴史的手動probe。

構文チェック: mp4.rb、mp4_metadata_snapshot.rb、mp4_property_update_plan.rb、mp4_chapter_snapshot.rb、mp4_chapter_reader.rb、新受入テストが成功。

## 契約検証

- mdtaのキーなし・値なし・空payload、日本語・locale・binary・NUL・順序・同値重複。
- 通常itemのkind/atom型、画像format/bytes、close/GC後の所有、不変性、入力キーの拒否。
- 全propertyの期待値と実setterの一致、空title・Shift_JIS copyrightの手書き期待値、保存後独立再読込、alias重複と不正値の原状保持。
- 両chapter形式の不一致を独立保持、別ファイルへの復元、片形式だけ削除、非ゼロ開始時刻padding、詳細diffと不変性。
- Neroの部分payload、QuickTimeのstts/stsz/stsc件数不整合・timescale0・参照先欠落・mdat外offset・切れたtextをmalformedとして拒否。
- QuickTimeのtx3g・外部drefをunsupportedとして理由付き拒否。診断も不変。
- chapterの文字列bytes・件数・整数writer幅の事前拒否、復元候補全体の事前検証、原本SHA-256とpendingタグ・chapterの保持。
- 保存再読込の正常検証後に故障注入し、rename前停止を確認。
- 実際の一時出力chplを破損させ、phase=:verify、committed=falseで拒否し、原本・pending状態を保持して一時出力を削除することを確認。

## 配布内容の検証

gem buildで/private/tmp/taglib-ruby-plus-2.3.2.10.gemを生成。gemspecのファイル一覧はtrackedと追加予定ファイルを含む実一覧と一致する。CI YAMLとgemspec/versionの構文チェックも成功。

gemを/private/tmp/snapshot-access-package-checkへ展開し、そのlibを優先して既存2.3.2.9 native bundleを読み込み、2.3.2.10のversion・copyright期待snapshot・item/artworks/mdta_values・両chapter形式の復元・File#save・close/GC後の再読込を検証して成功した。Rubyコードのみ変更のためnative再ビルドや新バイナリgemの公開は行っていない。

## 限界

Linux/Ruby3.2/Intel実行は未実施。Ruby3.2以上で利用可能な構文を使用し、native ABIは変更していない。QuickTimeは単一音声参照・text/stco/stsz等の明示対応範囲に限定し、co64/stz2/複数参照等は拒否する。物理構造完全復元・非整数ミリ秒・実利用ファイルの網羅を保証しない。

[設計](../mp4-snapshot-access-chapter-design.md) / [ADR](../ADR/2026-10-09-snapshot値取得とchapter公開APIの設計.md)
