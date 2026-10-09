# 全chapter sampleの公開snapshot

## APIと取得契約

```ruby
TagLib::MP4::File.open(path, false) do |file|
  snapshot = file.chapter_sample_snapshot
  next unless snapshot # chap参照がない場合だけnil

  snapshot.samples.each do |sample|
    p [sample[:sample_index], sample[:start_ticks], sample[:duration_ticks],
       sample[:title], sample[:padding], sample[:payload_sha256]]
  end
end
```

`ChapterSampleSnapshot`はcapture専用で、復元・sample書込APIではない。snapshot、配列、Hash、文字列はfreezeされ、File handleを閉じても使用できる。保存済みファイルだけを読み、pendingタグ・chapter・参照／時間修復計画を反映も変更もしない。既存chapter_snapshotは変更しない。

| 属性／sampleキー | 型・単位・意味 |
| --- | --- |
| track_id | Integer、参照先chapter Track ID |
| source_track_id | Integer、唯一の参照元音声Track ID |
| media_timescale | Integer、1秒あたりmedia ticks |
| media_duration | Integer、mdhdのmedia ticks。stts合計との一致を要求 |
| samples | Array<Hash>、paddingを含む全sample、原表の順序 |
| sample_index | Integer、0始まりの論理sample位置 |
| start_ticks | Integer、sttsを累積したmedia時刻。movie/edit適用前 |
| duration_ticks | Integer、sttsの正のmedia duration |
| title | UTF-8 String、text sampleの長さprefixで指定されたtitle |
| padding | Boolean、下記規約による区分 |
| payload_size | Integer、title prefix・modifierを含む全payload bytes |
| payload_sha256 | String、全payloadのSHA256 hex |
| movie | Hash `{timescale:, duration:}`、mvhdのmovie ticks |
| edit | nilまたはHash `{version:, segment_duration:, media_time: 0, media_rate: 65536}`。durationだけmovie ticks、media_timeはmedia ticks、rateは16.16固定小数 |
| preservation_signature | String、下記v1保持契約のSHA256 hex |
| ffprobe_comparison | Hash `{status: :complete/:clipped, reason: nil/String, mapping: :identity, origin_ticks: 0}` |

全sample数が2以上で、最初のstart_ticksが0かつtitleが空の場合だけpadding=true。他の空title、および単一sampleの空titleはpadding=false。この区分は既存writer/論理readerとの互換規約であり、空titleを自動削除したり生成経緯を断定したりしない。

## 時間と照合範囲

整数ticksとtimescaleを保持する。浮動小数点への変換・ミリ秒丸めはしない。`start_ticks + duration_ticks`がmedia終端である。単一identity edit（media_time=0、rate=1）とeditなしだけを受け入れるため、対応範囲ではmovieへの原点写像は0で、秒への変換はmedia ticks / media_timescaleとなる。

短いidentity editを持つ修復前ファイルも全media sampleを取得できる。editのsegment_duration（editなしならmvhd duration）およびmovie durationがmediaの全期間を覆うかを整数の交差積で判定し、不足ならclippedを返す。これは不完全なsample読取ではなく、表示範囲の不足である。`require_ffprobe_comparable!`はclippedの場合にChapterSnapshotErrorを投げる。completeは対応するidentity写像の全期間を意味し、任意のffprobeバージョンの出力やcodec警告を保証しない。FFprobeが時刻を別のtime_baseに丸める場合は完全一致しないことを明示して扱う。

対応: 単一音声chap参照→text chapter、mdhd v0、mvhd v0/v1、elst v0/v1の単一identityまたはelstなし、stts/stsz/stsc/stcoまたはco64、自己完結dref、UTF-8 title、modifierなしまたは既存encd modifier。

拒否: 非音声参照、複数ID／複数参照（同じIDの重複も含む）、重複Track ID／chap／atom、NeroとQuickTime併存、非text、mdhd v1、ctts/stz2、外部data reference、trim・empty edit・rate変更・複数edit、fragmented moof、不正境界・表の件数不一致・mdat外／truncated payload・無効UTF-8/NUL・非対応modifier。順序が逆転する物理sample配置にも対応しない。最大10万sample、sample payload合計32MiBという既存readerの上限を維持する。

## 署名と保持比較

```ruby
before = file.chapter_sample_snapshot
file.repair_native_chapter_timing(track_id: before.track_id, profile: :taglib_full_movie)
file.save_chapters
after = file.chapter_sample_snapshot
raise 'sample changed' unless before.preserved_equal?(after)
after.require_ffprobe_comparable!
```

v1署名は、version=1・chapter/source ID・media timescale/duration・sample数をunsigned 64bit big endianで連結し、各sampleのindex/start/duration/payload_sizeと32bytesのpayload SHA256を同じ順序で追加し、全体をSHA256にする。payloadは長さprefix、title、encdを含む。titleとpaddingはこれらから一意に導出される。physical offset、moov位置、tref_index、tkhd、mvhd、elstは含めない。このため時間修復、offset移動、通常タグ保存で一致し、sample欠落・順序・時刻・payload変更では不一致となる。

`preserved_equal?(other)`はこの契約だけを比較し、snapshot全体の時間context一致を意味しない。signatureを永続化する場合はアプリ側でもschema version=1を記録する。参照元を意図的に変更した場合も不一致となる。全mdat・他track・タグの保持はこの署名の範囲外。

## 例外契約

取得失敗は`ChapterSnapshotError`で、`phase=:capture`、`style=:quicktime`、`code=:malformed`または`:unsupported`を返す。既存parser由来のI/O・境界エラーもこの例外に統一する。不正表を空配列や部分結果へ変換しない。nilはQuickTime chap参照が見つからなかった場合だけであり、参照先欠落は例外となる。失敗しても原本とpending状態は維持する。ffprobe適合要求の失敗は同じ例外のcode=:unsupported。

## MListNewでの利用手順

1. 一時コピーで欠落参照の除去を計画し、保存する。実際の公開APIは`remove_dangling_chapter_references`であり、このgemに`repair_chapter_references!`はない。
2. before=chapter_sample_snapshotを取得し、論理chapter_snapshotも別に保持する。
3. 利用者指定profileで時間修復を計画・保存する。afterとbeforeのpreserved_equal?、論理chapter保持を確認する。
4. after.require_ffprobe_comparable!で対応する全期間を確認する。
5. ffprobeの`-show_chapters -of json`を取得し、全sample数・順序・titleを比較する。先頭paddingも除外しない。
6. ffprobeの整数start/endとtime_base=a/bを使って有理数または交差積で照合する。表示用start_time/end_timeの小数は比較に使わない。
7. 通常タグ保存後にも新snapshotを取り、beforeとの保持比較およびffprobe照合を再実施する。backup・stage・復旧記録・公開・DB更新・cleanup・codec警告の採否はMListNewで行う。

```ruby
snapshot.require_ffprobe_comparable!
raise 'count mismatch' unless snapshot.samples.size == ffprobe_chapters.size
snapshot.samples.zip(ffprobe_chapters).each do |sample, chapter|
  a, b = chapter.fetch('time_base').split('/').map(&:to_i)
  raise 'invalid time_base' unless a.positive? && b.positive?
  raise 'start mismatch' unless chapter.fetch('start') * a * snapshot.media_timescale == sample[:start_ticks] * b
  finish = sample[:start_ticks] + sample[:duration_ticks]
  raise 'end mismatch' unless chapter.fetch('end') * a * snapshot.media_timescale == finish * b
  raise 'title mismatch' unless chapter.fetch('tags', {}).fetch('title', '') == sample[:title]
end
```

ffprobeのchapter出力はpayload全体を持たないため、payload保持はbefore/after署名で別に検証する。件数だけの比較では十分ではない。

## 検証

製品にFFmpeg依存は追加せず、テストではFFmpeg生成fixtureと独立parserによるatom編集、ffprobeを使用する。モックは全sample読取の成功判定には使わない。検証環境はmacOS arm64、Ruby 4.0.7、FFmpeg/ffprobe n9.0.2。

| 範囲 | 実施結果 |
| --- | --- |
| 最終追加テスト、legacy／grouped backend | 各14 tests / 220 assertions、失敗・エラー0、実ファイル未指定によるomit 1。padding有無、単一空title、途中／末尾空title、各ticks/duration/title/順序、不変値、pending維持、submillisecond、co64読取、editなしを確認 |
| 保持検証 | 時間修復前後、通常タグ保存、moov先頭移動、free不足を超える10万bytesタグ追加による実offset増加、co64変換後のmoov拡張で一致。sample削減・payload順序交換・title改変・titleを保ったencd除去で不一致 |
| 拒否／復旧 | stts数・zero delta・mdhd合計・stsz・stsc・stco/co64・二重offset表・truncated text／atom・mdat外payload、trim/rate/複数edit、複数tref参照、重複chap/Track ID、Nero併存。取得失敗後も保存済みbytesとpendingタグ／chapter／時間計画を保持 |
| 関連回帰、両backend | 全sample・論理snapshot・atom修復・参照修復の74 tests、legacy 1040／grouped 1038 assertions、失敗・エラー0、omit 2。最後のencd保持テスト追加分は上記14件で別途成功 |
| legacy全体TestUnit | 製品コードの最終状態で397 tests / 2597 assertions、失敗・エラー0、omit 13（実ファイル未指定と任意の独立設計probe）。その後の追加はencd保持テストだけで、製品コードは変更なし |
| Minitest | 12 runs / 24 assertions、失敗・エラー0、既存の任意probe skip 5 |
| 実ファイル010226_001、両backend | 一時コピーだけを編集。各12 tests / 265 assertions、失敗・エラー・omit 0。欠落参照除去後はsource=2/target=4、16 sample／15論理chapter。時間修復前clipped、修復後complete、署名一致。ffprobe全16件の整数start/endとtitleが一致し、最後のend=3640937ms。原本SHA256が前後一致 |
| 包装・構文 | Ruby構文確認、gemspecの新lib/test/doc収録確認、差分空白確認 |

実ファイルの通常タグ保存は今回の全sampleテストでは実施していない。この原本には未対応index=0 metadataが併存し、既存の通常saveは別の契約で拒否するためである。通常タグ保存の保持・ffprobe一致は正常metadataの合成fixtureで確認した。今回の変更でsave_preserving_unindexed_mdtaへ移行する処理は追加していない。

co64は64bit表の読取とsynthetic offset移動を確認したが、4GiBを超える物理offsetの実ファイルは未検証。既存論理chapter_snapshotのco64対応範囲を広げていないため、co64章の通常タグ保存・時間修復の適用可否は既存save側の制約に従う。co64 native保存の成功を今回の検証結果からは保証しない。

Windows/Linux・他Ruby ABI・他ffprobeバージョン、他形式のchapterやedit写像、同時外部書込、作品DB／stage／cleanupは未検証または対象外。write/rename/cleanup経路の変更はなく、既存の失敗回帰テストを実施した。新APIは読取のみであり、書込時の復旧契約は既存保存APIに残る。
