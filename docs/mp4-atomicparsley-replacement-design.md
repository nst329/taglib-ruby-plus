# MP4メタデータAPI設計

## 前提と結論

対象はMP4/M4Aとし、TagLib 2.3.2以上で提供する。今回の検証では、MP4の`covr` artworkとFFmpegのattached pictureは、JPEG/PNG/BMPについて実用上同じ画像データとして往復できた。一方、GIFはMP4のattached pictureとしてFFmpegで直接扱えないため、互換対象から除外する。

`-movflags use_metadata_tags`付きの字幕muxでは、入力に2枚あったattached pictureが0枚になった。したがって、TagLib APIを追加しても、字幕mux前の取得とmux後の復元は必要である。ただし、この取得・復元をAtomicParsleyからTagLibへ移行できる設計とする。

## 目的

- AtomicParsleyのiTunes系MP4タグ更新をRuby APIで置き換える。
- MP4の`covr`をRubyで取得・全削除・追加できるようにする。
- 複数artwork、未知のMP4 item、既存チャプターを意図せず削除しない。
- MListNewがFFmpegを使う範囲（字幕mux、stream判定、attached_pic検証）は変更しない。

## 非目的

- 任意のMP4 atomを高レベルAPIで完全に表現すること。
- FFmpeg/ffprobeのstream情報APIをTagLibで置き換えること。
- GIFのattached picture互換を保証すること。
- 通常の`save`で未知atomのバイト列を完全に保持すること。

## API案

### iTunes系プロパティ

`TagLib::MP4::Tag`に、AtomicParsley名を正規名とするAPIを追加する。

```ruby
tag.property("TVShowName")
tag.set_property("TVShowName", "Example Show")
tag.remove_property("TVShowName")

tag.set_properties(
  "title"       => "Example",
  "artist"      => "Artist",
  "TVEpisode"   => "01",
  "description" => "Description"
)
```

対応する正規名とMP4 itemは次のとおりとする。

| 正規名 | item |
| --- | --- |
| `title` | `©nam` |
| `artist` | `©ART` |
| `album` | `©alb` |
| `genre` | `©gen` |
| `comment` | `©cmt` |
| `description` | `desc` |
| `longdesc` | `ldes` |
| `grouping` | `©grp` |
| `TVShowName` | `tvsh` |
| `TVEpisode` | `tven` |
| `keyword` | `keyw` |
| `podcastURL` | `purl` |
| `year` | `©day` |
| `purchaseDate` | `purd` |
| `contentRating` | `----:com.apple.iTunes:iTunEXTC` |

`property`は単一値を返し、未設定なら`nil`とする。既存の複数値を失わないため、別途`property_values`で全値を返す。`set_property`は対象itemの既存値を置換し、`set_properties`は全値の検証後に反映する。未知の名前は黙ってatom化せず、`ArgumentError`とする。既存の`item_map`は低レベルの退避APIとして残す。

`contentRating`だけは単純な文字列itemではない。内部値は例えば`mpaa|R|400|`というreverse-DNS itemであるため、次の値オブジェクトで変換を明示する。

```ruby
rating = TagLib::MP4::ContentRating.new(system: :mpaa, rating: "R", id: 400)
tag.set_property("contentRating", rating)
```

既知のレーティングの短縮入力を追加する場合も、固定テーブルにない値は推測せずエラーにする。未知のwire値は`property_values`または`item_map`で読み書きできるようにする。

文字列プロパティは、入力の文字コードに従って`encode(Encoding::UTF_8)`で変換する。呼び出し元の文字列は変更しない。変換できない場合はRubyの`Encoding`例外をそのまま返し、文字の置換や文字コードの推測は行わない。String以外、不正なUTF-8、NUL文字は`ArgumentError`とする。変換も全値の検証に含め、失敗時はitemを変更しない。`ContentRating`とチャプターの入力仕様は変更しない。

### Artwork

SWIGが所有する`CoverArt`ポインタをRuby利用者へ返さず、Ruby所有の不変値オブジェクトを追加する。

```ruby
artworks = tag.artwork
artworks.first.data       # binary String
artworks.first.format     # :jpeg、:png、または :bmp
artworks.first.mime_type  # "image/jpeg"、"image/png"、または "image/bmp"

tag.set_artwork(artworks) # covrを全置換
tag.remove_artwork        # covrを全削除
```

`Artwork`は`format`とバイナリ`data`を保持し、getterではデータをコピーする。setterは入力をコピーしてからC++の`CoverArt`へ変換する。artworkの順序と画像バイト列は保持する。

高レベルAPIの対応形式はJPEG/PNG/BMPとする。これらはFFmpeg 9.0.1でのattached picture往復とバイト列一致を確認済みだが、Plex等のプレイヤー表示までは未検証である。GIFは`UnsupportedArtworkError`とし、既存の低レベル`CoverArt` APIを使う場合だけ利用可能とする。

## 保存と保持性

- APIの変更はTagオブジェクト上に反映し、`MP4::File#save`で通常保存する。
- 通常の`save`は意味上の保持（未知item、複数artwork、チャプターが読み直せること）をテスト対象とする。
- 未知atomのバイト単位の完全保持は保証しない。これは既存のチャプターAPI設計とも一致する。
- チャプターだけを変更する場合は既存の`save_chapters`を使い、タグ/artwork変更と混在させない。
- 保存失敗時のファイル置換までTagLib側で行わない。呼び出し側が一時ファイルへ保存してから置換する。

## MListNew移行フロー

```text
入力MP4
  └─ TagLibでcovrをRuby値へコピー
       └─ FFmpeg字幕mux（use_metadata_tags、attached_picは失われる）
            └─ TagLibでartworkとiTunes系タグを一度に保存
                 └─ ffprobeでattached_pic、codec、字幕、chapterを検証
```

移行初期は次の安全策を置く。

1. mux前にTagLibのartwork数・format・SHA-256を取得する。
2. mux後にJPEG/PNG/BMP artworkをTagLibで復元する。
3. ffprobeでattached_pic数と画像codecを確認し、TagLibの画像データとも照合する。
4. TagLibが読めない形式、件数不一致、保存失敗の場合はAtomicParsleyへフォールバックするか、元ファイルを残して処理を失敗させる。

このため、AtomicParsleyを直ちに削除するのではなく、実ファイルとPlex等の表示確認が完了するまでフォールバックを残す。ffprobeはstream判定とmux後検証に引き続き必要である。

## テスト計画

### taglib-ruby-plus

- 全プロパティのread/write/removeとreverse-DNS `contentRating`。
- 未知item、複数artwork、QuickTime/Nero両形式のチャプターを通常保存後に保持。
- artwork 0/1/複数枚の順序、バイト列、JPEG/PNG/BMP形式。
- getterで返した値をGC後も使用できること、setter後に入力Stringを変更しても保存値が変わらないこと。
- 不正なproperty名、GIF、空データ、形式不一致のエラー。

### MListNew統合

- `use_metadata_tags`付き字幕muxで、TagLibによるartwork復元後にattached_picが元の件数へ戻ること。
- JPEG/PNG/BMPのsha256、字幕stream、音声・映像stream、チャプター、既存メタデータの保持。
- JPEG/PNG/BMPを検証し、GIFは拒否またはフォールバックを確認する。
- Plexおよび主要プレイヤーで複数artworkと字幕mux後の表示を手動確認する。

## 実装順序

1. Ruby所有`Artwork`とMP4プロパティ名の変換表を追加する。
2. `contentRating`の値オブジェクトとItemMap変換を追加する。
3. TagLib 2.3.2以上のビルド・APIテストを追加する。
4. MListNewでfeature flag付きのTagLib取得・復元を実装し、AtomicParsleyフォールバックを残す。
5. 実ファイル・プレイヤー確認後、AtomicParsleyのMP4タグ更新とartwork復元を段階的に削除する。
