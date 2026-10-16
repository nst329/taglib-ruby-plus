# RTP hintを含むMP4のchapter参照診断・解除

## 対応範囲

`chapter_reference_diagnostics`と明示的な`remove_chapter_references(references:)`を、検証済みRTP hint v1を含む非fragmented MP4に拡張する。既存の欠落参照除去も同じ検証を通す。通常読込・保存でchapを自動解除しない。

`hmhd`はpayload 20 bytes、version/flags=0、末尾reserved=0に限定する。統計値は保持し、値の大小やゼロから通信品質を推測しない。handlerはhint、media headerはhmhd一つとする。

`stsd`は単一の`rtp ` sample entry、data reference index=1、version/compatible version=1のみ。拡張は4-byte値を持つ`tims`（必須・非ゼロ）、`tsro`、`snro`のみ。重複・未知拡張を拒否する。既存の単一自己完結dref検証も必要。

`udta/hnti`は一つの`sdp `、または`sdp `識別子で始まる一つの`rtp `に限定する。内容はASCII（TAB/CR/LFを含む）のSDPテキストとして保持し、URLへのアクセスやbase64内容の再解釈・書換を行わない。未知の子atom・protocol・不正境界を拒否する。hnti全payloadを保存後にhash比較する。

## hint sampleと位置の安全性

hint参照表は単一の既存トラックIDで、自分自身を指さないものに限定する。全トラックのstsz/stsc/sttsとstco/co64を検証し、全sampleが一つのmdat payload内に収まることを確認する。stscはdescription index=1に限定する。stz2は未対応。全トラック合計100万sample、hint合計64 MiBを上限とし、巨大な固定サイズstszの展開にも先に上限を適用する。

hintの全packetを解析し、次だけを認める。

- constructor 0（no-op）、1（最大14 bytesの即値）。
- constructor 2の参照index=0、単一media sample番号とsample内offset/length。compression block比は0または1のみ。参照先sampleと範囲を検証する。
- packet flagsの既知下位3 bits、追加情報は12-byte `rtpo`のみ。各packet・constructor・追加情報の境界を検証する。

自己sample参照、複数参照、sample description参照（mode 3）、未知constructor/TLV、追加data領域、圧縮block比の変換は未対応として拒否する。既存ファイルにある未知構造を例外の抑制で通さない。

RTPのsample参照はファイル絶対位置ではなく、hint参照先・sample番号・sample内offsetである。chap解除では全トラックIDと順序、hint参照表、stsd、stsc、stsz、stts、全mdat bytesを保持する。moov拡張で後続mdatが移動する場合は全トラックのstco/co64を既存処理で補正する。このため参照先sampleのbytesとsample内位置は変わらない。`rtpo`は時刻補正でありfile offsetではない。

保存後は別handleで同じ厳密検査を繰り返し、対象chap以外のpayload hashと構造、mdat番号とchunk相対位置を比較する。未知形式・不正参照・保持不一致は置換前に失敗させる。失敗時は原本と保存待ち計画を維持する。

## 映像からtextへのchap

映像201からtext 3への参照は、text/textの組なら`:chapter_candidate`として診断し、選択した関係だけを解除できる。候補は有効な章であることの保証ではない。textトラックや章sampleそのものは削除しない。

`chapter_snapshot`は単一音声参照の既存制約を維持し、映像参照に対して`ChapterSnapshotError`を返す。nativeの`quicktime_chapters`も変更しない。全sampleの読み取り専用APIは既存`chapter_sample_snapshot`の範囲に従う。この変更はnativeのchapter書込・論理snapshotの対応拡張を意味しない。

## 根拠

Appleの[Data modes](https://developer.apple.com/documentation/quicktime-file-format/data_modes)はsample番号・sample内位置とhint参照番号を定義する。[Packet entry](https://developer.apple.com/documentation/quicktime-file-format/packet_entry)と[追加TLV](https://developer.apple.com/documentation/quicktime-file-format/packet_entry/extra_information_tlvs)にpacket構造・rtpoの時刻補正を規定する。hmhdの固定フィールドは[GPACの実装](https://github.com/gpac/gpac/blob/master/src/isomedia/box_code_base.c)でも確認した。

[ADR](ADR/2026-10-16-RTP-hintを検証してchapter参照解除を許可.md)

## 内部の責務

`ChapterReferences`はatom構造・chap編集・保存計画を担当し、RTPの形式検証は非公開クラス`HintValidator`へ委譲する。検証器は解析中のfile/IOを明示的に受け取り、hnti検査と、トラック情報・検証済みoffset表・mdat範囲を渡した全hint検査を行う。`ChapterReferences`のインスタンス変数やprivateメソッドは利用しない。検証器は解析呼出し内のローカル変数で所有し、保存計画や解析結果に保持しない。

検証器の入口は、対象hintの特定、全トラックのsample配置構築、各hintのheader・参照先・全sample検証を順に実行する。配置構築はサイズ表の検証とchunk offsetの展開を分離する。全トラックのsample数と全hint bytesの残量は解析呼出し内で引き継ぎ、配列生成・読込の前に上限を確認する。リファクタリングで公開API、対応範囲、例外契約は変更しない。
