# テスト構成

通常のRubyテストは`test/**/*_test.rb`を対象にし、`Rakefile`の`rake test`から実行する。Rake経由では成功時の進捗・テスト名・色を抑制し、失敗時だけ例外、backtrace、causeを出力する。MP4のnative bindingを使うため、ローカルのTagLibライブラリを`DYLD_LIBRARY_PATH`で指定する環境では、プロジェクトの標準テストと同じRubyを使う。

現行のPlus APIは[plus_mp4_api_test.rb](plus_mp4_api_test.rb)で確認する。ここでは編集用File、不変metadata/chapter値、save/save-as、世代不一致、無変更コピー、typed mdtaの所有コピー、chapter形式の保持を検証する。公開前後の障害注入、cleanupの原因連鎖、公開競合、旧APIの非公開化、診断schema、chapter sampleの所有もここで確認する。

内部専用の`TagLib::MP4::Internal::File`を使うテストは、metadata snapshot、chapter sample、chapter参照、atom修復などの責務別テストで検証する。Plus APIの保存処理がこれらを経由するため、関連変更時は次の範囲を合わせて実行する。

```sh
bundle exec rake test:plus_mp4
ruby -Ilib -Itest test/mp4_metadata_snapshot_test.rb
ruby -Ilib -Itest test/mp4_snapshot_access_chapter_test.rb
ruby -Ilib -Itest test/mp4_chapter_reference_selection_test.rb
ruby -Ilib -Itest test/mp4_chapter_references_test.rb
```

直接実行する場合も、同じ出力設定を付ける。

```sh
ruby -Ilib -Itest test/plus_mp4_api_test.rb \
  --verbose=important-only --no-use-color \
  --progress-style=fault-only --no-show-detail-immediately
```

`test/plus_api_design_probe_test.rb`と`test/support/plus_api_design_probe.rb`は、Document/Update/SavePlanを公開する前案の設計probeである。現行APIの回帰テストとして変更せず、過去に確認した保存境界を記録する資料として扱う。設計probeの結果は現行APIの実装完了を意味しない。

native bindingを別途ビルドする`*_design_probe_test.rb`、C++/Pythonのprobe、実ファイル用テストは通常の受入テストから分ける。必要な環境変数や外部fixtureがない場合は、各テストの条件に従ってomit/skipされる。

`test/probes/plus_mp4_metadata_contract.rb`はmetadata完全復元・artwork・wire情報・Error契約を確認する受入probeである。
FFmpegと独立fixtureを使うため通常の`*_test.rb` globには含めず、Plus保存経路の変更時に明示的に実行する。
公開APIから再現し、mdir/mdta contextの一括置換、media/chapter保持、失敗時の原本維持も検証する。
実行時の`PLUS_BINDING_LIB`には、比較する配布gemの`lib`を指定できる。省略時はこのcheckoutを使う。

```sh
ruby test/probes/plus_mp4_metadata_contract.rb \
  --verbose=important-only --no-use-color \
  --progress-style=fault-only --no-show-detail-immediately
```

結果と設計判断は[完全復元設計](../docs/mp4-metadata-complete-restore-design.md)に記録する。
