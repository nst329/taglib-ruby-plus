# AtomicParsley置換候補の検証結果

設計は[MP4メタデータAPI設計](mp4-atomicparsley-replacement-design.md)を参照。

## 結論

TagLib 2.3.2の既存の`MP4::ItemMap`、`Item`、`CoverArt`、チャプターAPIを使えば、今回の対象に含まれるMP4メタデータの多くはRuby側へ移行できる見込みである。

MP4 property/artworkの高レベルAPIを追加した。通常の`File#save`について、未知atomを含む`ilst`のバイト単位保持は保証しない。

## 環境と方法

- ブランチ: `investigate/mp4-atomicparsley-replacement`
- TagLib: 2.3.2
- taglib-ruby-plusのローカルネイティブ拡張を使用
- `test/data/mp4.m4a`のコピーを使い、保存後にTagLibとAtomicParsleyで再読込
- 既存ファイルは変更していない

標準テストは`shoulda-context`が未導入のため、この環境では起動できなかった。`kramdown`はGitHub Actions専用の依存として扱い、同じ検証をローカルネイティブ拡張へ明示的にロードするプローブで実行し、追加した回帰テストとして固定した。

## 確認できた対応

AtomicParsleyで設定した値は、TagLibのitemとして次のキーで読める。

| AtomicParsleyの項目 | MP4 item key | TagLibの値 |
|---|---|---|
| description | `desc` | `StringList` |
| long description | `ldes` | `StringList` |
| grouping | `©grp` | `StringList` |
| TV show name | `tvsh` | `StringList` |
| TV episode | `tven` | `StringList` |
| keyword | `keyw` | `StringList` |
| podcast URL | `purl` | `StringList` |
| purchase date | `purd` | `StringList` |
| content rating | `----:com.apple.iTunes:iTunEXTC` | `StringList` |
| artwork | `covr` | `CoverArtList` |

既存のtitle、artist、album、genre、comment、yearは、従来の`Tag` setterまたは対応する`©nam`、`©ART`、`©alb`、`©gen`、`©cmt`、`©day` itemで扱える。

`contentRating`は`contentRating`というitemではなく、`----` reverse-DNS atomとして保存される。TagLibでは`----:ドメイン:名前`形式のitem keyとして取得でき、同じキーへ`mpaa|R|400|`のような値を書いて保存できた。

## 保存保持性

通常の`File#save`で次を同一コピー上で確認した。

- 未知の`zzzz` itemの値が保持される。
- reverse-DNSのcontent ratingと独自itemが保持される。
- `covr`の複数artworkが保持される。
- `covr`を削除して保存すると、再読込後にitemが存在しない。
- `set_chapters`後に通常保存しても、Nero／QuickTime両形式のチャプターが保持される。

この結果はTagLibが認識・再構築できるitemの意味的保持を示すものであり、未知atomを含む`ilst`のバイト単位保持を示すものではない。チャプターだけを変更し、`ilst`を変更しない要件には、既存の`save_chapters`を使う必要がある。

## attached_picとcovr

FFmpeg 9.0.1で同じJPEG 2枚を使い、次の2種類のMP4を作成して比較した。

- FFmpegへ`-disposition:v attached_pic`を指定してmuxしたMP4
- TagLibで`covr`へ`CoverArtList`として保存したMP4

今回のMP4 muxerでは、FFmpegの`attached_pic`指定がMP4内部の`covr`として保存された。両方のファイルについて、次を確認できた。

- AtomicParsleyが`covr` 2枚として認識する。
- ffprobeが2本のMJPEG video streamを`attached_pic=1`として報告する。
- TagLibが2枚の`CoverArt`として認識する。
- 2枚の画像データのformat、サイズ、SHA-256が一致する。
- TagLibで作った`covr`をFFmpegでstream copy再muxしても、2枚の`attached_pic`が保持される。

したがって、今回確認したFFmpeg 9.0.1のMP4入出力経路では、JPEG、PNG、BMPについては`attached_pic`と`covr`を実用上相互利用できる。ただし、これはMP4 muxer／demuxerの組み合わせに対する検証であり、すべてのFFmpegバージョンやコンテナ形式に対する一般保証ではない。FFmpegが`covr`をstreamとして見せていることも、MP4内部に独立した通常のvideo trackが存在することを意味しない。

形式別の結果は次のとおりである。

| 形式 | TagLibの`covr`保存 | FFmpegの`attached_pic` | 備考 |
|---|---|---|---|
| JPEG | 成功 | 成功 | バイト列一致 |
| PNG | 成功 | 成功 | バイト列一致 |
| BMP | 成功 | 成功 | バイト列一致 |
| GIF | 成功 | そのままのcopyは失敗 | TagLibでは`covr`として保存できるが、ffprobeの画像streamにならない。JPEG再エンコードならFFmpegで扱える |

### `use_metadata_tags`付き字幕mux

2本の`attached_pic`と音声を持つMP4へ`mov_text`字幕を追加し、入力streamを明示mapしたうえで`-movflags use_metadata_tags`を指定した。この結果、字幕は残ったが`attached_pic`は2本から0本になった。同じmuxから`use_metadata_tags`だけを外すと、字幕と`attached_pic` 2本が保持された。

このため、`covr`と`attached_pic`がMP4入出力上で相互利用できても、`use_metadata_tags`付き字幕muxでattached pictureを保持できることは意味しない。現行のMListNew設計どおり、字幕mux前後で画像を別途抽出・復元する経路は必要である。

未検証の範囲:

- Plexや各プレイヤーでの表示差異
- MListNewで使用する実ファイルに含まれる全メタデータとの同時保持

## 実装判断

1. `set_property(name, value)`は、上表の固定マッピングを持つRuby APIとして実装した。
2. `set_artwork`はRuby所有の`Artwork`配列を受け取り、`covr`を全置換するAPIとして実装した。対応形式はJPEG/PNG/BMPである。
3. `contentRating`は通常文字列itemと異なるreverse-DNS形式なので、`ContentRating`値オブジェクトで変換するAPIとして実装した。
4. `stik`、数値フラグ、`trkn`など今回の対象外の項目まで汎用化する場合は、Ruby値からMP4 item型への変換規則を別途設計する必要がある。
5. MListNew側でAtomicParsleyを削除する前に、実際の入力ファイルで、TagLib保存後のPlex・プレイヤー表示、複数artwork、チャプター、字幕／attached pictureの動作確認を追加する。

今回の検証範囲では、MP4タグ更新とartwork復元は「TagLib側に高レベル薄型APIを追加する」候補として進められる。一方、AtomicParsleyが扱う全iTunes atomやFFmpegのattached pictureを完全に同等置換できるとはまだ結論できない。
