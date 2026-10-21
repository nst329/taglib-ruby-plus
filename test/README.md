# テスト構成

`test/probes/mp4_smb_generation_design.rb`はSMB原本のctime差を模擬する設計probe。
製品Generationの`:sha256`基準SHAによるctime-only許容、stat既定の厳格拒否、plan後の内容変更・実体差し替えの拒否を確認する。
`ruby -Ilib -Itest test/probes/mp4_smb_generation_design.rb`で単独実行する。実SMBでctimeが揺れる瞬間の再現とは区別する。

`plus_mp4_io_test.rb`には、通常ファイルのNFD原表記保持とsymlinkの同一実体解決を確認する回帰assertを追加している。`shoulda-context`が必要なため、依存がない環境では構文チェックと設計probeを代替確認とする。指定SMB原本は読み取り専用のplan確認に限定する。

通常のRubyテストは`test/**/*_test.rb`を対象にする。test-unitとminitestはautorunの干渉を避けるため実行プロセスを分け、`rake test`が`test:unit`、`test:minitest`の順に実行する。個別に確認する場合は次を使う。

```sh
rake test:unit
rake test:minitest
rake test
```

Rake経由ではtest-unitの成功時の進捗・テスト名・色を抑制し、失敗時だけ例外、backtrace、causeを出力する。minitestには専用のオプションだけを渡し、6以降では--quietで進捗を抑制する。MP4のnative bindingを使うため、ローカルのTagLibライブラリを`DYLD_LIBRARY_PATH`で指定する環境では、プロジェクトの標準テストと同じRubyを使う。

現行のPlus APIは[plus_mp4_api_test.rb](plus_mp4_api_test.rb)で確認する。[plus_mp4_io_test.rb](plus_mp4_io_test.rb)は通常/厳密モード、cache、コピー予算、競合・部分コピー・purl raw・同時編集の独立検証を確認する。`test:plus_mp4`は`plus_mp4*_test.rb`をすべて実行する。ここでは編集用File、不変metadata/chapter値、save/save-as、世代不一致、無変更コピー、typed mdtaの所有コピー、chapter形式の保持を検証する。公開前後の障害注入、cleanupの原因連鎖、公開競合、旧APIの非公開化、診断schema、chapter sampleの所有もここで確認する。

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
公開APIから再現し、mdir/mdta contextの一括置換、media/chapter保持、失敗時の原本維持も検証する。metadata完全置換と両chapter形式の同時編集では、FFprobeのtrack ID別packet SHAで映像・音声・字幕を独立比較する。
実行時の`PLUS_BINDING_LIB`には、比較する配布gemの`lib`を指定できる。省略時はこのcheckoutを使う。

```sh
ruby test/probes/plus_mp4_metadata_contract.rb \
  --verbose=important-only --no-use-color \
  --progress-style=fault-only --no-show-detail-immediately
```

結果と設計判断は[完全復元設計](../docs/mp4-metadata-complete-restore-design.md)に記録する。

## I/O性能の検証

[plus_mp4_sample_boundaries_test.rb](plus_mp4_sample_boundaries_test.rb)は公開sample境界APIを、独立生成したMP4のoffset・時刻・edit・table破損・非対応・予算・I/O障害・世代競合で検証する。巨大sparse mdatと1億固定sampleを使い、実File#readの位置・回数・要求bytesと割当object数も確認する。ffmpeg/ffprobeが利用可能ならpriming editを含む実生成MP4とも比較する（全packet取得はテスト専用oracle）。結果と限界は[検証記録](../docs/Memos/2026-10-19-sample境界APIの検証.md)を参照。

[plus_mp4_info_test.rb](plus_mp4_info_test.rb)はnative/sample/probe不要のheader宣言、時間軸・日時・役割・名前・選択cacheを確認する。[plus_mp4_reuse_test.rb](plus_mp4_reuse_test.rb)は旧値変換と旧画像payload読取の禁止、stage直接出力、実出力snapshot、chapter解析の選択と観測共有、画像bytes共有を確認する。

`test/performance/` のprobeは公開APIのみで通常読取・診断・保存を実行する。Ruby/nativeの論理I/O bytes、一時領域、走査数と時間の計測方法は[I/O性能記録](../docs/Memos/2026-10-16-MP4公開APIのI-O性能検証.md)を参照する。

全体検証は`rake test`で両runnerを実行する。個別テストを直接requireする場合も、test-unitとminitestのファイルを同じRubyプロセスへ混在させない。

追加の[header・保存snapshot計測](../docs/Memos/2026-10-16-headerと保存snapshotの再利用検証.md)では、大きいartworkとmdatで原本native open、String共有、選択情報取得のbytesも記録する。

## 不正mdtaとQuickTime併用の設計probe

`test/probes/mp4_metadata_context_pair_design.rb`は複数metadata contextの設計probeである。公開診断と計画、別udtaの識別、context順序、未知子atom、独立候補のraw保持を確認する。公開pair修復の主な保存契約は`plus_mp4_limited_repair_test.rb`で受入検証する。

```sh
ruby -Ilib -Itest test/probes/mp4_metadata_context_pair_design.rb \
  --verbose=important-only --no-use-color \
  --progress-style=fault-only --no-show-detail-immediately
```

`test/probes/mp4_invalid_mdta_repair_design.rb`は未実装の併用修復設計を検討する試験で、通常テストglobから分離する。FFmpegと現行native bindingを必要とする。
不正indexの任意位置・32bit値域・fourcc解釈、正常bytes保持、現行readerの制約、同一moov候補への両編集と独立再読込を確認する。製品保存APIや障害契約の受入試験ではない。

```sh
ruby -Ilib -Itest test/probes/mp4_invalid_mdta_repair_design.rb \
  --verbose=important-only --no-use-color \
  --progress-style=fault-only --no-show-detail-immediately
```

結果と未検証範囲は[併用設計](../Docs/mp4-combined-limited-repair-design.md)に記録する。

`plus_mp4_limited_repair_test.rb`は製品公開APIの併用修復、各領域の独立判定、許可と要否の分離、layout、raw保持、出力digest、世代・障害契約を検証する。計画のmoov全面読込1回、候補copy1回と独立scan1回、保存後の構造解析1回も確認する。
`plus_mp4_reuse_test.rb`は取得済みchapter・無変更snapshotの再利用、およびchapter参照／時間診断でartwork payloadを読まないことを検証する。native内部のI/OとRubyのFile#read計測は区別する。
