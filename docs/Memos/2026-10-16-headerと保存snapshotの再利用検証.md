# header情報と保存snapshotの再利用検証

日付: 2026-10-16
対象: v2.3.2.23の変更前libと、header情報・保存snapshot再利用を含む最終実装。
環境: macOS 27.0.1 arm64、Ruby 4.0.7、同じTagLib 2.3.2 native binding。

[設計](../mp4-header-info-design.md)・[ADR](../ADR/2026-10-16-header情報共有と保存snapshotの再利用.md)に契約と判断を記録する。前段の[I/O改善計測](2026-10-16-MP4公開APIのI-O性能検証.md)は当時の結果として保持し、本記録で上書きしない。

## テストから確定した設計

- 先にinfoの受入テストを作り、未実装による5件の失敗を確認した。nativeを禁止し、不完全なsample表でもheader宣言だけを取得するfixtureを使って実装した。
- metadata完全置換では旧native読取を禁止したテストを通した。大きい旧covr payloadの構造検査用読取を禁止するテストを追加したところ、metaのversion確認が本文全体を読んでいたため失敗した。4 bytes確認へ限定して解消した。必要な原本SHA用の逐次読取はこの禁止対象に含めない。
- metadataのみの保存前にchapters getterを使うと、出力で不要なchapter解析が起動することを禁止テストで確認した。出力chapterの完全読取は、変更した場合または明示選択時だけにした。取得済みで未編集というだけでは解析しない。
- 保存出力のchapterを明示取得した後のdiagnoseにもnative再openが必要だったため、禁止テストで失敗を確認して修正した。検証済み世代のreader観測をgetterと診断へ引き継ぐ。
- 凍結済みimage bytesと未変更MetadataItemの同一object共有、可変入力からの所有分離を確認した。native/IO handleをreader cacheへ残さないことも確認した。

## 測定範囲

`test/performance/io_meter.c` によりRuby/nativeの論理read/write bytesと一時領域を計測した。詳細な境界と制約は[前段の計測方法](2026-10-16-MP4公開APIのI-O性能検証.md)と同じ。全体hash・全媒体コピーに加え、原本のInternal::File.open呼出し数とProcess.spawn数を計測した。内部フックは計測器だけに置き、操作本体は公開Plus APIだけを使う。

Native原本openは旧metadata/画像をnativeへ読み込む経路の指標であり、保存候補の独立native再読込は除く。外部起動カウンタは操作中のRuby Process.spawnを対象とする。製品header経路はnativeを呼ばず、外部起動関数も使わないことを実装・禁止テストと合わせて確認した。受入probeのFFmpeg/FFprobeは製品操作の計測外で、独立検証として残す。

時間は計測器を無効にした別プロセスの値。各条件1回でありcache状態等により変動する。I/O回数とbytesを受入主指標にし、時間だけで性能を判定しない。原本fixture準備とrequireは計測外。

### fixture

- `mp4.m4a`: 12,037 bytesの既存音声fixture。
- `plus-io-large.mp4`: 268,447,501 bytes。既存fixtureに256 MiBの未参照sparse mdatを追加。
- `plus-info-artwork.mp4`: 285,221,645 bytes。上記に8 MiBのJPEG-signature付きimageを2件設定。画像をデコードする検証ではなく、opaque artwork bytesの保持・共有を調べるfixture。

大量の実録画の経過時間を代表するfixtureではない。映像・音声・字幕の実packet保持は独立FFprobeの受入テストで確認する。

### 操作

| 操作 | 内容 |
| --- | --- |
| replace | titleだけのsnapshotを完全代入して原本保存し、metadataを取得 |
| stage_verified | titleだけの完全置換を未作成stageへ直接保存し、検証済みmetadataを再利用。旧版には返却snapshotがないため公開open(stage)で一度取得 |
| chapters_shared | chapters、diagnose(:chapters)、chapter_samplesを2回取得 |
| artwork_edit | metadata取得後、titleのwithとcommentのwithoutを10回。保存しない |
| info_movie | movieだけ2回 |
| info_tracks | 既定movie＋tracksを2回 |
| info_all | movie/tracks/chapters/artworkの全sectionを2回 |

旧版にinfo APIはないため、infoの旧版測定は行わない。既存使用側の外部probe回数も不明なので削減回数を推測しない。新経路で外部起動ゼロという観測と、API未提供という差を区別する。

## 実測結果

read/writeはbytes、tempはMiB、時間は秒。丸め前の全値は[raw JSON](2026-10-16-headerと保存snapshotのI-O計測.json)に記録する。

### mp4.m4a（12,037 bytes）

| 操作 | 版 | read bytes | write bytes | 全体hash | 全媒体コピー | 原本native open | 外部起動 | temp MiB | 秒 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| replace | 前 | 216,355 | 28,178 | 10 | 2 | 2 | 0 | 0.023 | 0.005434 |
| replace | 後 | 31,003 | 13,170 | 2 | 1 | 0 | 0 | 0.011 | 0.003387 |
| stage_verified | 前 | 229,027 | 28,178 | 11 | 2 | 2 | 0 | 0.023 | 0.006620 |
| stage_verified | 後 | 30,991 | 13,170 | 2 | 1 | 0 | 0 | 0.011 | 0.007195 |
| chapters_shared | 前 | 76,422 | 0 | 5 | 0 | 4 | 0 | 0.000 | 0.001293 |
| chapters_shared | 後 | 8,291 | 0 | 0 | 0 | 2 | 0 | 0.000 | 0.000940 |
| artwork_edit | 前 | 32,009 | 0 | 2 | 0 | 1 | 0 | 0.000 | 0.003364 |
| artwork_edit | 後 | 4,516 | 0 | 0 | 0 | 1 | 0 | 0.000 | 0.002706 |
| info_movie | 後 | 213 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000276 |
| info_tracks | 後 | 404 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000318 |
| info_all | 後 | 524 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000401 |

### plus-io-large.mp4（268,447,501 bytes）

| 操作 | 版 | read bytes | write bytes | 全体hash | 全媒体コピー | 原本native open | 外部起動 | temp MiB | 秒 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| replace | 前 | 4,563,619,395 | 536,899,106 | 10 | 2 | 2 | 0 | 512.023 | 2.294527 |
| replace | 後 | 536,901,971 | 268,448,634 | 2 | 1 | 0 | 0 | 256.011 | 0.904354 |
| stage_verified | 前 | 4,832,067,555 | 536,899,106 | 11 | 2 | 2 | 0 | 512.023 | 2.177017 |
| stage_verified | 後 | 536,901,959 | 268,448,634 | 2 | 1 | 0 | 0 | 256.011 | 0.818292 |
| chapters_shared | 前 | 1,342,253,822 | 0 | 5 | 0 | 4 | 0 | 0.000 | 0.640273 |
| chapters_shared | 後 | 8,331 | 0 | 0 | 0 | 2 | 0 | 0.000 | 0.001955 |
| artwork_edit | 前 | 536,902,961 | 0 | 2 | 0 | 1 | 0 | 0.000 | 0.271464 |
| artwork_edit | 後 | 4,540 | 0 | 0 | 0 | 1 | 0 | 0.000 | 0.003573 |
| info_movie | 後 | 221 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000957 |
| info_tracks | 後 | 412 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000399 |
| info_all | 後 | 532 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000465 |

### plus-info-artwork.mp4（285,221,645 bytes）

| 操作 | 版 | read bytes | write bytes | 全体hash | 全媒体コピー | 原本native open | 外部起動 | temp MiB | 秒 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| replace | 前 | 4,899,102,219 | 587,221,538 | 10 | 2 | 2 | 0 | 544.017 | 3.585245 |
| replace | 後 | 570,450,275 | 285,222,778 | 2 | 1 | 0 | 0 | 272.009 | 0.865112 |
| stage_verified | 前 | 5,184,324,523 | 587,221,538 | 11 | 2 | 2 | 0 | 544.017 | 2.682715 |
| stage_verified | 後 | 570,450,263 | 285,222,778 | 2 | 1 | 0 | 0 | 272.009 | 1.778181 |
| chapters_shared | 前 | 1,493,221,038 | 0 | 5 | 0 | 4 | 0 | 0.000 | 0.674046 |
| chapters_shared | 後 | 33,556,579 | 0 | 0 | 0 | 2 | 0 | 0.000 | 0.018350 |
| artwork_edit | 前 | 603,999,529 | 0 | 2 | 0 | 1 | 0 | 0.000 | 0.283083 |
| artwork_edit | 後 | 16,778,696 | 0 | 0 | 0 | 1 | 0 | 0.000 | 0.016451 |
| info_movie | 後 | 221 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000314 |
| info_tracks | 後 | 412 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000659 |
| info_all | 後 | 548 | 0 | 0 | 0 | 0 | 0 | 0.000 | 0.000626 |

## 受入結果と制限

- 約285 MBの入力でmovieは221 bytes、movie＋tracksは412 bytes、全sectionでも548 bytes。image payloadを含まず、全体hash・全媒体コピー・原本native open・外部起動・一時書込は全てゼロ。同じ選択の2回目はcache値である。
- 約285 MBで完全置換のreadは4,899,102,219から570,450,275 bytesへ、writeは587,221,538から285,222,778 bytesへ減った。原本native openは2→0、候補全媒体コピーは2→1、全体hashは10→2。
- 同じ入力のstage_verifiedはreadが5,184,324,523→570,450,263 bytes。使用側のstage事前コピーは不要で、gem内の候補コピーは一回。返却snapshotから取得し、使用側の追加open(stage)一回を省いた。出力の独立再読込は維持した。
- 全体hash二回は原本コピーと保存後出力読取に共有される。原本SHAを返す契約のため、削除する旧metadata bytesも原本走査で一回読む。旧metadataの値変換・画像hash・再構成用本文読取とは区別する。
- 大きいartworkで、第一画像bytesを保持する11個のsnapshotを作る操作のString object数は11→1。保持String長の合計は88 MiB→8 MiB（第一画像だけの集計）。Rubyのcopy-on-writeがあるため物理RAMや実際のmemcpy量を意味しない。同一object共有の回帰テストで契約を確定した。
- artworkを含むmetadata自体を取得する初回には画像bytesの読取が必要。章の完全読取にもnativeの初回openが残る。軽量なheaderだけならinfoを使い、この経路を起動しない。
- header宣言だけでcodec実体・実再生時間・デコード可能性を検証した扱いにしない。音声変換後などの独立probeは残す。

## 最終回帰検証

- Plus公開API対象: 62 tests / 602 assertions、失敗・エラーなし。
- test-unit全体: 535 tests / 4,068 assertions、失敗・エラーなし、13 omissions。
- minitest: 12 runs / 24 assertions、失敗・エラーなし、5 skips。
- 映像・音声・字幕付きのmetadata受入probe: 16 tests / 111 assertions、失敗・エラー・omitなし。
- omit/skipは既存の外部実ファイル、隔離binding、native design probe等の未指定条件。新しいinfo/reuseテストにはomitを置いていない。
- 元の保存競合・各phase失敗・cleanup・媒体保持・purl raw・型/locale/順序/重複の受入を維持した。返却snapshotについても、入力の通常purlが実出力でmdtaへ移る例で、期待値をそのまま返していないことを確認した。
- 64-bit日時・all-ones duration・言語unknown・track ID・名前とhandler名・回転・edit timelineとmedia時間軸・不完全sample表の宣言数・cacheと原本置換後の失効を検証した。
- 配布gemのリリース、音声の変換・デコード、大容量実録画での受入は実施していない。

最終変更をまとめた後に対象テストを実行し、その成功後に全体を検証した。途中の失敗や実装変更に対する結果を最終成功として扱っていない。test-unitとminitestのrunnerは[前段と同様](2026-10-16-MP4公開APIのI-O性能検証.md)に分離した。

## 再現

```sh
clang -dynamiclib -O2 test/performance/io_meter.c -o /private/tmp/plus_io_meter.dylib
python3 test/performance/run_plus_mp4_io.py \
  --ruby /opt/homebrew/opt/ruby/bin/ruby \
  --meter /private/tmp/plus_io_meter.dylib \
  --before-lib "$BEFORE_LIB" --after-lib "$PWD/lib" \
  test/data/mp4.m4a /private/tmp/plus-io-large.mp4 /private/tmp/plus-info-artwork.mp4 \
  --operations replace stage_verified chapters_shared artwork_edit

# infoは旧APIにないため現行だけを測る。
python3 test/performance/run_plus_mp4_io.py \
  --ruby /opt/homebrew/opt/ruby/bin/ruby \
  --meter /private/tmp/plus_io_meter.dylib --after-lib "$PWD/lib" \
  test/data/mp4.m4a /private/tmp/plus-io-large.mp4 /private/tmp/plus-info-artwork.mp4 \
  --operations info_movie info_tracks info_all
```

BEFORE_LIBにはv2.3.2.23のRubyと同じnative bindingを配置する。大きいmdat fixtureは[前段の生成方法](2026-10-16-MP4公開APIのI-O性能検証.md)を使う。artwork fixtureは次のように生成した（計測外）。

```ruby
require 'taglib_plus'
require 'fileutils'
path = '/private/tmp/plus-info-artwork.mp4'
FileUtils.cp('/private/tmp/plus-io-large.mp4', path)
api = TagLib::Plus::MP4
bytes = "\xFF\xD8\xFF".b + 'x'.b * (8 * 1024 * 1024 - 3)
image = api::Artwork.new(format: :jpeg, data: bytes)
api.open(path) do |file|
  file.metadata = file.metadata.with(artworks: [image, image])
  file.save!
end
```
