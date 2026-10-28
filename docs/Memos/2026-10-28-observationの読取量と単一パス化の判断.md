# observationの読取量と単一パス化の判断

日付: 2026-10-28
対象版: taglib-ruby-plus 2.3.2.42

## 目的

`observation(areas)`をmetadataの単一パス読取・Ruby化へ広げる前に、現行APIの読取量と同一世代での再読の有無を測る。測定は論理I/Oであり、物理ディスク転送量やSMBのレイテンシを表さない。

## 方法

計測器と操作は既存の`test/performance/io_meter.c`と`test/performance/plus_mp4_io.rb`を使う。`observation`の読取量を比べるため、次の操作を追加した。

- `observation_metadata`: `observation(:metadata)`を2回
- `observation_chapters`: `observation(:chapters)`を2回
- `observation_metadata_chapters`: `observation(%i[metadata chapters])`を2回

fixtureは`test/data/mp4.m4a`（12,037 bytes）と、その`covr`へ8MiB payloadを入れた`/private/tmp/taglib-artwork-242.mp4`（8,397,573 bytes）。artwork fixtureは計測前の準備処理で作り、計測対象に含めない。

```sh
clang -dynamiclib -O2 test/performance/io_meter.c -o /private/tmp/taglib_io_meter_242.dylib
BUNDLE_PATH=$PWD/.tmp/bundle \
RUBYOPT="-I/opt/homebrew/lib/ruby/gems/4.0.0/gems/taglib-ruby-plus-arm64-darwin-2.3.2.42/lib" \
python3 test/performance/run_plus_mp4_io.py \
  --ruby /opt/homebrew/opt/ruby/bin/ruby \
  --meter /private/tmp/taglib_io_meter_242.dylib \
  --after-lib $PWD/lib \
  test/data/mp4.m4a /private/tmp/taglib-artwork-242.mp4 \
  --operations read observation_metadata observation_chapters observation_metadata_chapters
```

## 結果

| fixture | 操作 | read bytes | native open | 備考 |
|---|---|---:|---:|---|
| mp4.m4a | read（metadata+chapters×2） | 4,708 | 0 | metadataは2回目が実質0増 |
| mp4.m4a | observation_metadata×2 | 9,926 | 0 | 1回あたり約4,963 |
| mp4.m4a | observation_chapters×2 | 192 | 0 | 1回あたり96 |
| mp4.m4a | observation_metadata_chapters×2 | 10,118 | 0 | ほぼarea合計 |
| 8MiB artwork | read（metadata+chapters×2） | 8,390,211 | 0 | ほぼfile size 1回分 |
| 8MiB artwork | observation_metadata×2 | 16,780,932 | 0 | 1回あたりほぼfile size |
| 8MiB artwork | observation_metadata_chapters×2 | 16,781,124 | 0 | chapter分の96×2のみ増 |

write bytes、全体hash、媒体copy、外部process起動はいずれも0、errorなし。

## 判断材料

- metadata観測の読取量は`covr`の実データ量で決まる。8MiB artworkでは1回の観測がfile size相当を読む。metadataをRuby読取へ移しても、この実データ読取は避けられないため削減効果は小さい。
- `metadata`は同一handle内でcacheされ2回目が実質0増、`observation(:metadata)`は呼出しごとに再読する。同一世代で同じareaを繰り返し観測する呼出しがある場合だけ、世代単位の観測cacheが有効になる。
- `observation(:chapters)`は1回あたり100 bytes程度で、chapter状態の共有を目的とした現行利用では追加の削減余地が小さい。
- MListNewの現行復修・字幕経路は、世代あたりmetadata観測1回で`observation(:chapters)`を併用する。多重観測の呼出しは確認できていない。

以上から、metadataのRuby化・単一パス観測は現時点では実装しない。世代単位の観測cacheは、多重観測する呼出しが実SMB経路で確認された場合の候補として残す。

## 未検証

実SMB上のレイテンシ、artwork以外の大きなmetadata（mdta多数・巨大chapter）、並行writer、4GiB超fixtureは測定していない。本記録の数値はローカル論理I/Oの1回測定であり、速度保証には使わない。
