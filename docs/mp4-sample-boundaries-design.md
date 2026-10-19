# 読み取り専用sample境界API

状態: 実装済み・未リリース。MListNew A3向けの物理構造証拠を取得する。
判断理由は[ADR](ADR/2026-10-19-sample境界を圧縮tableから読み取る.md)。

## 公開契約

```ruby
require 'taglib_plus'
TagLib::Plus::MP4.open(path) do |file|
  evidence = file.sample_boundaries(
    track_id: audio_track_id,
    max_table_bytes: 8 * 1024 * 1024,
    max_table_entries: 1_000_000
  )
  next unless evidence[:status] == :complete
  first, last = evidence[:data].values_at(:first, :last)
end
```

IDはMP4 tkhdのIDでありffprobeのstream indexではない。引数は正のIntegerを要求し、不在trackはArgumentError。保存済み原本を読み、未保存編集候補は反映しない。返却値は再帰的にfreezeしたHash/Array/String/整数等だけで、File・native handleを保持しない。close後も利用可能。要求ごとにtableを読み、結果やtable本文をFileへcacheしない。同じ世代のatom境界indexだけを既存header reader等と共有する。

| トップレベルキー | 契約 |
| --- | --- |
| status | `:complete` / `:unsupported` / `:limit` |
| data | 下記の観測値。unsupported/limitでは部分値のみ存在し得る |
| issues | `code`, `message`、必要時`atom_offset`。具体的な非対応boxや予算を示す |
| coverage | `{check:, status:}`。complete/unsupported/not_checked。未到達checkは含まない |
| counts | `table_bytes`, `table_entries`, `bytes_read`, `read_calls` |
| tables_digest | 完全に取得した各tableのabsolute atom offset（big-endian uint64）・fourcc・payloadを取得順にSHA256へ投入したhex。全体hash・media署名・永続cache keyではない |

`complete`は指定trackの対応範囲のsample table整合性が確認できた意味。codec設定の正当性、復号可否、payload、他trackのsample領域、ffprobe packetとの一致、統合muxの適用可否を保証しない。coverageの`media_payload`と`codec_configuration`は常にnot_checked。非対応構造を発見しても通常tableの検証を継続する。fragmentや未知fullbox version、空track、予算到達では早期終了するためcoverageも限定される。

破損は`TagLib::Plus::MP4::Error(code: :malformed, area: :sample_boundaries, phase: :read)`。I/O失敗は`:io`でcauseを維持する。共通parserの破損例外もcauseを保持する。世代変更は既存の`:source_changed`をそのまま伝播する。これらをunsupported/limitへ変換しない。予算後の未読領域の破損検出は保証しない。

## dataと時間軸

| キー | 単位・内容 |
| --- | --- |
| track_id, handler | tkhd ID、handler fourcc |
| media_timescale, media_duration | mdhdのticks/秒、宣言media duration。all-onesのunknownはnil |
| movie_timescale | mvhdのticks/秒 |
| time_axis | 常に`:raw_media` |
| sample_descriptions | stsd順の`fourcc`, `data_reference_index`, `raw`（entry headerを含むbytes）。mp4aは`audio_version`, `channels`, `sample_rate_fixed`（16.16）も返す。rawはesds等のcodec設定を含むが解釈しない |
| sample_count | size tableのsample数。stts/ctts/stscと照合 |
| decode_end | sttsの全duration合計、media ticks |
| composition_offsets | `:absent` / `:zero` / `:nonzero`。nonzeroはunsupported |
| first, last | `{index:, offset:, size:, dts:, pts:, duration:}`。indexは0始まり、offsetはabsolute bytes、sizeはbytes。他はraw media ticks |
| last_is_max_raw_presentation_end | CTTSなし／全0と正durationに基づき、lastのraw PTS+durationが最大であること。nonzero CTTS時はfalse |
| edits | nilまたはelst順の`segment_duration`, `media_time`, `rate_integer`, `rate_fraction`。durationはmovie ticks、media_timeはmedia ticks、rateは16.16の二分表現 |

DTSはsttsを0から累積し、対応範囲のPTSはDTSと同じ。nonzero CTTS時のfirst/last PTSはnilとし、推定値を返さない。非対応構造がある場合も位置・raw時刻が入ることはあるが、製品の適用判定へ流用せずstatusを確認する。

単一rate=1のeditでは、sampleのedit適用後の秒は`Rational(raw_pts - media_time, media_timescale)`で得られる。表示範囲は`0 ... Rational(segment_duration, movie_timescale)`。先頭primingや末尾切詰めがあってもraw値と物理的lastは変えない。edit終端より後のsample、最後のpacketのduration切詰め、skip/discard情報を利用するかはMListNewで判断する。ffprobeのDTS/PTSやdurationをraw値と直接同一視しない。ffmpeg固有の丸め・decode・mux処理は含めない。

## 検証範囲

- sttsの全行、正のcount/delta、size tableとの件数一致。decode終端は符号付き64bit正値以内。既知mdhd durationとstts終端の不一致は破損。
- stszの固定長／可変長、stz2の4/8/16bit。宣言件数とpayload長を厳密照合。固定長ではsample数に比例する走査を行わない。
- stscはfirst_chunk=1、行の厳密昇順、chunk数内、正のsamples_per_chunk、有効description indexを要求。全chunkと全sampleの対応を照合。
- stco/co64は一方だけ。各chunkの全sample size合計で実領域を検証し、ファイル内かつ単一mdat payload内を要求。chunk順が物理offset順でなくてもよい。正長chunkをoffset順に整列して重複を拒否する。空sampleのsize=0は許すが、chunk開始はmdat payload内を要求する。
- stsdは単一mp4a audio version 0を初期対応とする。entry拡張はesds/btrtだけを許可し、境界を検証する。drefは単一自己完結url entry、descriptionの参照index整合を要求する。
- elst v0/v1、editなし／単一・非負media_time・rate=1。primingと末尾切詰めの宣言を保持する。
- CTTSはv0/v1で全行countを検証し、全0だけcomplete。

複数description（途中変更を含む）、他codec/handler、audio entry v1/v2、外部参照、複数／empty／dwell／rate変更edit、nonzero CTTS、fragment、暗号化構造、sample group（rollを含む）、subs/sdtp/stsh/padb/stdp/cslg、未知sample table・track extension等はunsupported。既知container/entryの許可リスト外を推測しない。atom境界・重複必須box・table切断は破損。atom数50,000・深さ16の既存parser上限はlimitとする。

## I/Oとメモリ予算

対象tableはdref/stsd/elst/stts/ctts/stsc/stszまたはstz2/stcoまたはco64。payload長の合計をmax_table_bytes、処理する宣言entry数合計をmax_table_entriesで制限する。固定stszはsample数によらず1 entry、可変sizeはsample数、stz2はnibble数で数える。entry上限で停止したtableはheaderだけ読み得る。counts.table_entriesは走査用に受理したentry数、table_bytesは実際に要求したtable payload bytes（切断読取では成功bytesを意味しない）。bytes_read/read_callsは境界parser・必要header・tableを含む、この要求のRuby IO.read要求量／回数。OSの物理I/O、seek、stat、以前のinfo取得、Generationの検査用読取は含まない。

tableのprefixを一度読み、予算・長さ・件数を検証して残りを一度読む。media本文はseekで飛ばす。全sampleのRuby配列は生成せず、圧縮raw tableを予算内で保持して集約する。chunk区間は重複確認のためchunk数分だけ保持する。計算量は可変size entries + timing/mapping entries + chunks log(chunks) + chunks log(mdat数)。メモリはtable byte予算・entry予算・既存atom数上限で制約される。allocatorのRSS上限をbytes予算と同一とは扱わない。

通常`:stat`世代を読取前後に確認する。追加の全体SHAはない。明示`:sha256`モードでは既存契約どおり世代検査の全体読取が発生し、counts外となる。低I/OのA3は通常モードと同一open世代のinfo/境界を使う。

## MListNewへの接続

現時点ではMListNew側を変更していない。採用時には利用可能gem版を確認し、この確定schemaへadapterを接続する。completeだけを採用し、unsupported/limitは理由を記録して従来経路。例外は停止する。first/lastのoffset/sizeを限定ffprobe packetと照合し、edit原点・timescaleを揃えてDTS/PTS/duration/side dataを検証する。全packet oracleを製品へ流用しない。

ffmpeg生成AACにはsgpd/sbgpが付く実例があり、初期範囲ではunsupportedになる。これを無視して有効化しない。groupの意味を検証する追加仕様・実装、または入力条件の限定が別途必要。
