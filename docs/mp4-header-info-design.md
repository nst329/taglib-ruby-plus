# MP4 header情報と検証済みsnapshotの再利用

対象: v2.3.2.23を基点とするPlus公開API。判断理由は[ADR](ADR/2026-10-16-header情報共有と保存snapshotの再利用.md)、実測・回帰テストは[検証記録](Memos/2026-10-16-headerと保存snapshotの再利用検証.md)を参照する。

## 読取専用info

```ruby
require 'taglib_plus'

TagLib::Plus::MP4.open(path) do |file|
  info = file.info # movieとtracksだけ。nativeや外部コマンドを開かない
  movie = info.fetch(:movie)
  seconds = movie[:duration_ticks] && Rational(movie[:duration_ticks], movie[:timescale])

  # 選択した領域だけを追加取得する。sample本文はどの場合も解析しない。
  summary = file.info(sections: [:chapters])
  artwork_headers = file.info(sections: [:artwork])
end
```

戻り値はネストしたArray/Hash/Stringまで不変。`sections`は `:movie / :tracks / :chapters / :artwork` の重複しない配列で、省略時は `[:movie, :tracks]`。同じ選択は同じsnapshotを返し、別の選択でも取得済みsectionを共有する。tracksはmovie timescaleを必要とするためmovie headerも内部取得するが、未選択sectionを返却Hashへ追加しない。

infoは**保存済み原本のheader宣言**を返す。未保存候補を混ぜない。通常モードでは媒体全体hash・sample payload読取・外部probe起動を行わない。厳密モードを明示した場合は既存契約どおり世代照合の全体SHAが発生する。取得前後の世代確認、変更時の拒否、原本保存成功時のcache失効は既存Fileと共通。

atom境界のindexを同じ原本世代でchapter読取・参照検証と共有する。完全なchapter readerの観測値もgetterと診断で共有する。sample用の観測は別に遅延し、native/IO handleをcacheへ残さない。info(sections: [:chapters])から完全なchapter readerは起動しない。

### movie

| 項目 | 意味 |
| --- | --- |
| version | mvhdのv0/v1 |
| timescale | mvhdの整数time units/second |
| duration_ticks | mvhd宣言値。all-ones sentinelはnil |
| raw_duration | sentinelを含む元の整数 |
| creation_time / modification_time | mvhdの日時raw情報 |
| status | 通常はdeclared。moof/mvexがある場合はfragmented |

秒値は整数ticksとtimescaleから有理数として導出できる。同じheader解析を再実行するduration APIは追加しない。mvhd値はデコード・sample走査で確かめた実再生時間ではない。fragmented MP4はfragment側のtimelineを集計しない。

### tracks

track順の不変配列。配列位置を外部ツールのstream indexとして扱わない。

| 項目 | 取得元・意味 |
| --- | --- |
| id / handler | tkhdのtrack ID / mdia.hdlrのfourcc |
| sample_entries | stsd各entryのfourccとdata_reference_index。codec名は推測しない |
| enabled | tkhdのenabled flag |
| language | mdhdのraw整数・packed ISO言語code・status。旧QuickTime言語値等はcode=nil、unknown |
| name / track_name | trak/udta/nameのUTF-8値とraw/source/status。未知encodingはname=nil、rawを保持 |
| handler_name / handler_name_raw | hdlrの名前とraw。track名の代用品として混ぜない。旧QuickTime等の不明encodingは名前をnilにする |
| chapter_target_ids / chapter_source_ids | chap参照の送信先／自分を参照する送信元のtrack ID。存在・対応形式を検証した修復選択行ではない |
| role | status/value/evidence。resolvedのvideo/audio/subtitle/chapter、unknown、根拠競合時ambiguous |
| header_duration | tkhd duration、movie timescale、source=tkhd |
| media_duration | mdhd duration、media timescale、source=mdhd |
| presentation_duration | elstのsegment duration合計とmovie timescale。elstなしはtkhd宣言。未対応rateではticks=nil、unsupported |
| raw_header_duration / raw_media_duration | sentinelを含む整数宣言値 |
| edits | elstのsegment_duration、符号付きmedia_time、rate整数部/小数部。elstなしはnil、空elstは[] |
| creation_time / modification_time | tkhd日時 |
| media_creation_time / media_modification_time | mdhd日時 |
| width / height | videのtkhd表示幅・高さ。16.16を有理数で保持。非映像やzero宣言はnil |
| raw_width_fixed / raw_height_fixed | tkhdの16.16 raw整数 |
| matrix / rotation_degrees / rotation_status | tkhd行列raw。正規の0/90/180/270度だけを表示し、反転・非正規scale/shear等を推測しない |

`*_duration` は `{ ticks:, timescale:, source:, status: }`。sentinel不明値はticks=nilでunknown。elstの空編集（media_time=-1）の長さもmovie timelineに含める。media_timeはmedia timescale、segment_durationはmovie timescaleであり、直接加算しない。rate=1.0以外は適用後timelineの解釈を保留する。これらはheaderに基づく宣言であり、sampleの実際の長さやデコード可否の証明ではない。

sample_entriesの音声v0/v1ではsample entry headerのsample_rate（16.16有理数）とchannelsを返す。zero宣言や未対応の音声entry versionはnilとしraw/version/statusを保持する。これらはcodec固有設定やデコードで確認した値ではない。映像entryではheaderにあるwidth/heightも保持し、tkhd表示寸法と区別する。未知codecでもfourccは失わない。

rotation_degreesはraw行列のa/b成分の角度を0/90/180/270へ表した規約で、[a,b,c,d]=[0,65536,-65536,0]を90度とする。外部ツールの正負規約との同一性を仮定せず、必要ならraw matrixを使う。

rolesはhandlerを基本根拠とする。chapで参照されるtext trackはchapterの宣言、audio/video等がchap targetにもなっている場合はambiguous。未参照textや未知handlerはunknownとし根拠を返す。JPEG/PNGのvideo trackをartworkと推測しない。

### 日時

日時情報は `{ raw:, epoch: '1904-01-01T00:00:00Z', unit: :seconds, status: }`。raw=0はunset、その他はdeclared。v1の64-bitを切り捨てない。raw=0を1904年の実日時やUnix epochとして表示しない。ファイルmtimeとは別であり、誤った基準時刻で書かれたファイルの日時を推測補正しない。タイムゾーン情報も追加推測しない。

### chaptersとartwork

`:chapters` はNero/QuickTimeそれぞれ `{ present:, count:, status: }`。Neroはchpl count、QuickTimeはchap参照先とstsz/stz2の宣言数だけを使う。不在はpresent=false、count=0、absent。参照の欠落・競合や未対応形式ではcount=nil。declaredはsampleの読取完了を意味しない。タイトル・時刻・payload署名は既存 `chapters / diagnose(:chapters) / chapter_samples` を使う。修復に必要な位置付き行は引き続き `diagnose(:chapter_references)` から取得する。

`:artwork` はcovrのdata headerにある形式整数・locale・bytesizeと既知形式名のみ。画像dataを返さず、hash・コピー・デコードしない。不明形式はformat=nilでraw data_typeを保持する。metadata imageはtrackではないため偽のtrack IDを与えない。画像bytesの取得・編集は既存のmetadata.artworksを使う。

header readerはatom数50,000、深さ16、単一の取得payload 1 MiB、選択処理のheader payload合計8 MiBを上限とする。sample数が多くてもsample表本文は読まない。境界不正は明示的なError、未知header versionはunsupportedとし、不明値を0や空文字で作らない。

## 保存の追加契約

```ruby
source = TagLib::Plus::MP4.open(original) { |file| file.metadata }
TagLib::Plus::MP4.open(destination) do |file|
  file.metadata = source # 未取得の旧metadataは値変換しない。構造・保持領域は検証する
  next unless file.changes[:changed]

  result = file.save!(to: stage, snapshots: [:chapters])
  actual_metadata = result.fetch(:snapshots).fetch(:metadata)
  actual_chapters = result.fetch(:snapshots).fetch(:chapters)
end
```

stageは事前コピーせず、未作成のpathを指定する。既存stageや公開時に競合した出力は上書きしない。原本から候補へ一回出力し、独立検証後に排他的linkでstageを公開する。失敗時の原本維持・Error情報は既存契約どおり。

metadata完全代入では、旧metadataの値や画像をnativeへ変換せず、atom境界・context・data header・chunk offset・対象外保持条件を検証する。置換する旧meta/画像はmoov再構成用にも読み込まない。保持するleafと新しいmetadataから候補を作る。旧値の文字列や画像自体が保存可能かを検証する目的ではない。

取得済みのmetadata baselineがあれば同値代入を無変更として扱う。未取得baselineへの完全代入は同じ値か不明なので「置換予定」とする。無変更判定のためだけの旧値読取は行わない。`changes`は保留領域の情報であり、未読baselineとの値一致を証明するものではない。取得済みsnapshotのwith/withoutでは従来どおり厳密な値比較を使う。

save!返却Hashの既存キーを維持し、`snapshots` を追加する。これは独立した実ファイル読取から得た値だけを含む不変Hash。

| 保存 | snapshotsの内容 |
| --- | --- |
| 変更保存（原本・別path） | metadataは必須検証済みなので常に返す。chapterは変更した場合だけ返す |
| `snapshots: [:chapters]` | 追加で実chapter snapshotを独立読取して返す |
| 無変更保存・既定 | {}。getter用の期待値を検証済みと偽って返さない |
| 無変更保存・明示選択 | 選択領域だけ実ファイルから読む。別pathコピーでは出力から読む |

`snapshots` optionは `:metadata / :chapters` の重複しない配列。未選択で不要なchapter/sample解析は起動しない。返却Hashにchaptersキーがないことと、実際に章不在のChapterSnapshotを区別する。原本保存後のgetterはこの実読取値をcacheへ採用し追加I/Oを発生させない。未選択で未変更の旧chapter cacheは原本置換時に失効するため、後で章が必要なら明示取得する。別path保存後も返却値は同様に再利用できるが、Fileの原本や編集候補は切り替えない。

凍結済みbinary bytesはsnapshot間で共有する。可変な入力Stringは所有コピーするため、元Stringを後から変更してもsnapshotは変わらない。with/withoutは未変更MetadataItemも共有し、大きいartworkのbytesを複製しない。保存時のnative変換・atom生成に必要な出力bytesまでゼロcopyとする契約ではない。

## 独立probeの位置づけ

header情報は外部probeの全機能を置き換えない。音声変換後の実codec・stream、sample payload・実測bitrate・デコード可否等の確認には独立probeを残す。製品APIは外部コマンドを起動せず、受入probe側で別に検証する。

track名の `trak/udta/name` は[FFmpegのwriter](https://ffmpeg.org/doxygen/8.1/movenc_8c_source.html#l04247)がUTF-8で出力する形を扱い、hdlr名とは別に返す。movieの別形式の[tnam](https://developer.apple.com/documentation/quicktime-file-format/track_name_atom)等をこのfieldへ黙って混ぜない。
