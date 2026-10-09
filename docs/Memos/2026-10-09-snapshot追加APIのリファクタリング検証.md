# snapshot追加APIのリファクタリング検証

2026-10-09。macOS arm64、Ruby 4.0.7。APIとversion 2.3.2.9の契約を維持。

## 範囲と再現

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
全体テスト・Minitest・native patch列は今回変更していないため、前回成功した範囲を繰り返していない。全体の既知wrapper数failureは[実装検証](2026-10-09-snapshot追加APIの実装検証.md)を参照。

[判断ADR](../../Docs/ADR/2026-10-09-snapshot追加APIの内部責務整理.md)
