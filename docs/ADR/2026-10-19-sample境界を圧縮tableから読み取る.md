# sample境界を圧縮tableから読み取る

状態: 採用・実装済み（未リリース）

## 背景

MListNewの字幕・音声統合mux A3ではheader durationだけで物理的な最終packetを証明できない。TagLibでsample tableの整合性を検証し、外部packetとの照合をMListNewへ分担する。

既存infoは宣言のみ、構造診断は時刻と全件数対応を保証せず、chapter sampleは本文読取・章固有のedit制約・全sample配列がある。いずれも必要な契約の代用にならない。

## 決定

Plus Fileへsample_boundariesを追加する。[公開仕様](../mp4-sample-boundaries-design.md)を正本とする。既存HeaderReaderを継承してatom parser・世代index・timing解釈を共有する。sample table整合検証は章やwriterを起動しない独立readerへ置く。native ABI・バージョン・保存APIは変更しない。

raw media時間軸の境界とedit宣言を分け、ffmpegの時刻丸め、復号、packet照合は含めない。complete/unsupported/limitと破損/I/O/世代競合例外を区別する。対応外group等の意味を推測しない。

## I/O・メモリと選択肢

media payloadを一切読まず、共通parserで8/16 bytesのatom headerを読みseekする。tableはprefixと残りをそれぞれ一度読み、合計bytes/entriesの予算を検査する。全体SHA・コピー・書込は追加しない。明示sha256世代モードの既存走査は維持する。

全sample配列案よりメモリを削減するため圧縮table bytesを保持する。全てをblock streamにする案はseek/read回数と複数table cursorの複雑さが増すため初期実装では採用しない。保持量は合計8MiB/100万entryが既定で、利用者が明示変更できる。固定sizeはsample数に比例する走査も不要。chunk重複の確実な検出にはchunk区間を保持してsortするためO(chunks log chunks) CPUとO(chunks)補助メモリが必要。mdat範囲検索はbinary searchする。atom indexは従来の50,000件・深さ16制約を共有する。

結果・table本文はcacheせず、要求中だけ所有する。繰返し要求のtable再読込は発生するが、長期cacheの寿命・予算・失効管理を追加しない。infoと境界取得は同一open世代のatom indexを共有する。

## 検証と限界

[検証記録](../Memos/2026-10-19-sample境界APIの検証.md)に実測を記載する。合成fixtureで固定/可変/stz2、時刻、edit、破損・上限・障害・競合、巨大固定sample countを検証する。実ffmpeg生成AACのpriming editとpacket位置も照合するが、roll sample groupを含むためstatusはunsupportedである。group対応の追加なしにA3の一般入力対応が完成したとは扱わない。

原本・既存未コミット変更を保持し、コミット・push・releaseは行わない。MListNew製品への接続・実作品／実ストレージの速度検証は別工程とする。
