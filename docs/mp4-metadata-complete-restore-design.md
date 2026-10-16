# 公開MP4 APIのmetadata完全復元設計

状態: 実装済み。2.3.2.21の作業ツリーで受入probeと回帰テストを通過。
対象: 配布済み2.3.2.21、およびmainのeb6182c。

## テストで確認した問題

`test/probes/plus_mp4_metadata_contract.rb`は公開APIでの操作と独立fixtureだけを使う。
FFmpegで短い映像・音声・mov_text字幕を生成し、字幕を2本へ再muxした単一mdtaを復元先にする。
通常itemのraw型・locale・画像はテスト用の独立parserで入力fixtureへ追加する。
使用側の操作にはInternal、旧File、native Tagを使わない。

| ケース | 配布済み2.3.2.21 | 実装後 |
| --- | --- | --- |
| 復元先snapshotへitems/mdtaをマージ | ffprobe titleが`元のタイトル;元のタイトル` | 既存の部分編集として同じ。完全復元はsnapshot直接代入を使用 |
| mdir snapshot直接代入 | `metadata verification failed`、code=save、phase=verify | 通常item・保存先専用値を完全置換 |
| titleだけのsnapshot直接代入 | verify失敗 | 保存先専用値を除去 |
| 任意の型付きmdtaの直接代入 | verify失敗 | 型・locale・bytes・順序・重複・空keyを保持 |
| purl付きsnapshotのwith/without後の直接代入 | raw不足ではなくverify失敗 | purlをmdtaへ配置し、値を保持 |
| purl itemだけを復元先へマージ | raw不足。公開codeはsaveへ潰れる | `:purl_raw_missing` とissuesを返し原本不変 |
| JPEG / PNG / BMPのartworks読取 | 整数13 / 14 / 27をsymbolと解釈できず失敗 | 公開symbolへ変換し順序・重複を保持 |
| 未対応artwork形式 | 公開Errorではなく旧UnsupportedArtworkError | `:unsupported_artwork` の公開Error |
| 不正chunk offset | 原本SHAは不変だが具体的code/issuesが不足 | preflightで拒否しissuesを返す |
| mdir同士の通常item完全置換 | 成功 | 成功 |

要求をassertする15ケースは実装後に98 assertionsすべて成功する。
失敗を隠すためのomitやfallbackは入れていない。FFmpegを使うため通常の`*_test.rb`には含めず、受入probeとして明示実行する。

完全置換でのverify失敗には、復元先の空mdta keyが構造上残ることを、snapshotの厳密比較が値の残存と区別していない問題がある。
一方、mainの通常item移行経路には、元の型付きitemを別領域へ変換する問題と、少数itemの場合だけ復元先値を保持する問題がある。
比較条件を緩めるだけでは解決しない。

## 公開契約

完全復元は既存の直接代入を使う。新しいrestore APIや互換層を増やさない。

```ruby
require 'taglib_plus'

source = TagLib::Plus::MP4.open(source_path) { |file| file.metadata }
edited = source.with(properties: { comment: '復元時の注記' }).without(properties: [:genre])

TagLib::Plus::MP4.open(muxed_path) do |file|
  file.metadata = edited
  file.save!
end
```

この例が完全復元の使用例である。
`with(items:, mdta:)`はキー単位の部分編集である。完全復元へ使うと復元先だけの値が残る。
直接代入は通常item・mdta・artwork全体を置換し、元にない値を除去する。
ソースに元から両表現のtitleがある場合まで勝手に重複排除しない。

## 保存構造

通常itemを別の意味のmdta keyへ一律変換しない。purlに限らず、全item・全mdta値を対象にする。

| snapshotの内容 | 作成するmetadata context |
| --- | --- |
| 通常itemのみ | 単一mdir |
| mdtaのみ | 単一mdta |
| 両方 | mdir、mdtaの順に各1個 |
| 両方とも空 | 空の単一mdir |

metadataを変更して保存する場合、保存先のmetadata領域をsnapshotから構成し直す。無変更保存は既存のまま扱う。
空snapshotも空の単一mdirとして出力し、contextを省略する別経路は設けない。
これによりpurlの通常itemを数値mdtaへ移す必要もなく、普通のitemとして型とrawを保持できる。
同一意味のtitleを復元先から持ち越すこともない。
mdirを先に置く理由は、FFmpegがmdta解析状態を後続metaへ持ち越す既知の挙動を避けるため。

構造probeでは、実FFmpeg再mux先のmetaを一時領域だけで上記の2 contextへ置換した。
公開APIの再読込で通常itemと全mdta値が一致し、通常itemのwire bytesも一致した。
purlの型1、locale 1041/7、同じURLの重複、3画像形式とJPEGの重複を含む。
原本のmdat、track ID、offset以外のmdia、非空Nero章が不変で、ffprobeのtitleは1件だった。
製品writerでも同じ構造を生成し、独立再読込で検証する。

## 値とwire情報の所有

公開snapshotの型付き値を正本とする。現実装のMetadataItemは型・値を所有し、purlのrawだけはlegacy snapshotの復元情報として保持する。
mdtaは保存時にkeys/ilstを候補値から再構成し、通常itemは一時mdir contextへnativeで生成する。
MetadataItem単位で全item rawを所有する設計は将来の整理対象であり、現状は不足するrawを推測しない。

| 操作 | wire情報の扱い |
| --- | --- |
| 読み取り | 型・locale・bytesを公開値へ変換し、purl rawはsnapshotの復元情報へ保持する |
| 未変更itemのwith/without | 型付き値を引き継ぐ。purl rawは同じsnapshot内だけで引き継ぐ |
| 別snapshotのMetadataItemをwithへ渡す | 値は引き継ぐが、rawが必要なitemは保存前に不足を拒否する |
| item値を変更する | native stagingまたはmdta serializerで生成する |
| 必要情報が不足する手作りitem | 公開Errorのcode/issuesで拒否する |

復元元パスやoffsetへ依存せず、対象をpurlだけに限定しない。未知構造をrawコピーで迂回しない。
保存前には公開値と保持しているpurl rawの整合を確認する。

現実装ではpurl rawはsnapshot内部の復元情報として保持する。別snapshotのMetadataItemへ手作業で移した場合はrawが不足するため、公開APIが`:purl_raw_missing`で拒否する。
MetadataItem単位で全item wire情報を所有する整理は残課題であり、使用側にInternalアクセスを要求するfallbackは追加しない。

## artwork

`metadata.artworks`は形式整数をライブラリ内で`:jpeg` / `:png` / `:bmp`へ変換する。
値順・重複・画像bytesをそのまま返す。未対応形式や不正画像は公開Errorで拒否し、配列から省略しない。

書込みは既存のwithに1つだけ引数を追加する。

```ruby
image = TagLib::Plus::MP4::Artwork.new(format: :jpeg, data: File.binread('cover.jpg'))
edited = source.with(artworks: [image, image])
cleared = edited.with(artworks: [])
```

使用側にcovr形式整数やnative定数の変換を要求しない。itemsとartworksの両方でcovrを指定した入力は、優先順位を推測せず拒否する。

## 保存と検証

内部の責務は次の3つに分ける。新しい公開APIや、責務ごとのクラス追加は必須としない。

| 責務 | 入力と成果物 |
| --- | --- |
| snapshotの編集・検証 | 不変値とwire情報を管理し、入力全体の整合を検証する |
| contextの構成 | snapshotからmdir/mdtaを構成し、期待snapshotとatom置換計画を返す |
| Fileの保存 | 世代確認、一時コピーへの適用、独立検証、公開を担当する |

context構成はitem数によってmergeへ切り替えず、完全置換だけを扱う。
既存atom editorのmoov再配置・stco/co64補正を再利用し、metadata context集合の追加・削除を明示的に計画する。

1. `metadata=`で候補全体、wire整合、保存先context、chapter/media構造をpreflightする。成功時だけ候補を採用する。
2. `save!`で原本世代と現在の全編集候補を確認し、最終的な置換計画を作って一時コピーへ適用する。
3. 独立再読込でmetadata全値とwire情報を照合し、chapter・media・対象外atomの保持を検証する。
4. 原本SHAを再確認し、成功時だけ一度renameする。

代入時のpreflight結果を保存計画として持ち回らない。代入後のchapter編集などを、古い計画で保存しないため。
期待snapshotは候補から作り、保存後の実測値を期待値として採用しない。

値比較ではmdta key indexとcontext位置を無視する。各key内の値順・重複は無視しない。
新しいcontextを構成するので、期待しない空keyの残存も不要になる。元snapshotにある空keyは保持する。
比較差分とraw不一致はissuesへ記録し、単なる`metadata verification failed`だけで終わらせない。

## エラーと制限

全て`TagLib::Plus::MP4::Error`で返し、元のcode/issuesを外側saveエラーで潰さない。
preflightはphase=prepare、画像入力検証はphase=validate、独立再読込の不一致はphase=verify。
公開前はcommitted=false、rename後の失敗はcommitted=trueを維持する。

issuesにはarea相当のpath、原因code、説明、必要なら期待型・実際型やbytesの長さ/digestを載せる。
画像・バイナリ本体はログへ出さない。

断片化MP4、曖昧な複数同種context、未知namespace/子atom、壊れたkeys/index、mdat外offsetなど、
既存parser/editorが保持を証明できない構造は拒否する。chapter_snapshotの制約を緩めない。
`UDTA parsing failed retrying raw`は字幕track由来として、mux直後と保存後の警告を別に比較する。

## 実装状況と残課題

1. 全metadataのcontext生成と完全置換計画、preflight、独立検証を実装済み。
2. artworkの公開読書きとError変換を実装済み。
3. 15ケースの受入probeと既存回帰テストを追加・更新済み。
4. MetadataItem単位の全item wire所有、逆方向mdta→mdir、metadata contextがない入力の生成計画は残課題。

逆方向のmdta→mdir、metadataなしの復元先、複数contextへの生成計画、未知itemの拒否は、
構造を保持できる証拠が不足するため引き続き明示拒否する。rename直前/後の障害契約は既存Plus回帰テストで確認する。
