# MP4 mdta metadata 保持・読み書き設計

## 状態

TagLib本体パッチによる第一実装あり。責務整理の再設計・再レビューを追記（2026-09-20）。
以下には実装前の調査記録と、実装後の責務整理を含む。実装済み範囲は末尾に明記する。

## 目的

FFmpeg の `-movflags +use_metadata_tags` が生成する MP4 の `mdta`
metadata を、taglib-ruby-plus の通常のMP4タグ保存後も保持する。

対象とする代表的なキーは次のとおり。

- `title`
- `show`
- `artist`
- `description`
- `audio_normalization`
- `audio_normalization_target`

FFmpeg は実行時依存に追加しない。

## 前提と確認結果

`/Users/nasu/Bin/h265-conv.sh` が直接付与するmetadataは、現状では次の2項目である。

```text
audio_normalization=loudnorm
audio_normalization_target=-16-LUFS
```

`title`、`show`、`artist`、`description`は入力ファイル由来またはテスト用に追加される場合がある。

FFmpegで短いH.265/AAC MP4を生成して確認した構造は次のとおり。FFmpeg自身が
`encoder`も付与するため、対象キー以外のmdtaキーも存在する。

```text
moov
└── udta
    └── meta
        ├── hdlr (handler_type = mdta)
        ├── keys
        │   ├── 1 = mdta:title
        │   ├── 2 = mdta:show
        │   ├── 3 = mdta:artist
        │   ├── 4 = mdta:description
        │   ├── 5 = mdta:audio_normalization
        │   ├── 6 = mdta:audio_normalization_target
        │   └── 7 = mdta:encoder
        └── ilst
            ├── item name = 1 → data type 1 → title
            ├── item name = 2 → data type 1 → show
            ├── item name = 3 → data type 1 → artist
            ├── item name = 4 → data type 1 → description
            ├── item name = 5 → data type 1 → loudnorm
            ├── item name = 6 → data type 1 → -16-LUFS
            └── item name = 7 → data type 1 → Lavf...
```

実際には7番目の`mdta:encoder`も確認できた。`keys`のインデックスは1始まりで、
`ilst`の数値atom名と対応する。`ilst`には数値atomだけでなく、同じmeta内に
通常の4バイトatom名を持つitem（例: `©nam`、`©ART`）が混在する場合もある。
`data` atomはdata type、locale、生payloadを持つ。今回確認した値はdata type `1`
（UTF-8）だった。

比較用に`-use_metadata_tags`なしで生成した通常MP4も確認した。そのmetaの
`handler_type`は`mdir`で、`ilst`には`©nam`、`©ART`などの通常itemが入った。

さらに、mdta MP4へAtomicParsleyでtitle/artistを追加したfixtureでは、別のmetaを
新設せず、既存の`handler_type=mdta`の`ilst`へ`©nam`と`©ART`を追加した。このため、
「通常ilst」と「mdta ilst」は物理的に必ず別boxになるとは限らない。

TagLib 2.3.2のMP4 Tagは`moov/udta/meta/ilst`をhandlerのnamespaceと分離せず
`ItemMap`へ変換する。`keys`とmdtaの数値インデックスは意味的には扱わない。
保存時にはItemMapから`ilst`を再構築するため、mdtaの数値itemが失われる。
現行bindingでfixtureを読むと`title`は空、`properties`も空で、mdtaの数値itemは
通常のItemMapから取得できなかった。
実際にtitleだけを変更した保存後は、`keys` boxは残ったが`ilst`は`©nam`だけになり、
`show`、`artist`、`description`、normalization、`encoder`はffprobeから消えた。

参考:

- [TagLib mp4tag.cpp](https://raw.githubusercontent.com/taglib/taglib/master/taglib/mp4/mp4tag.cpp)
- [TagLib mp4atom.cpp](https://raw.githubusercontent.com/taglib/taglib/master/taglib/mp4/mp4atom.cpp)

Ruby bindingだけでなく、TagLib C++ APIを直接使った場合にも同じ挙動を確認した。

## 現在のTagLib対応範囲

既存のTagLib/taglib-ruby-plusは次を扱う。

- 通常のiTunes形式`ilst`
- `ItemMap`と既知の`Item`型
- `covr` artwork
- `----` freeform item
- `stem`
- Nero／QuickTime chapter

chapter専用の`save_chapters`は通常の`MP4::Tag::save()`を呼ばないため、mdta通常保存とは
別経路として維持する。

mdta対応後もこの境界を維持する。`save_chapters`はmetadata writerを実行せず、未保存の
通常tagまたはmdta変更がある場合は、Ruby側の一時File再openで変更を失わないよう
`ChapterSaveError`で拒否する。

## 採用するデータモデル

mdtaを既存の`ItemMap`へ混在させない。`keys` tableと`ilst` item群は別の集合として
保持する。keysに存在するがdataを持たないキーを、空payloadのitemとして表現してはならない。

Ruby側には、例えば次の値オブジェクトを追加する。

```ruby
MdtaKey
  .index
  .namespace
  .key

MdtaItem
  .item_ordinal # 元の数値ilst itemの順序
  .key_index
  .namespace
  .key
  .data_type
  .locale
  .data # Encoding::BINARYの生payload
  .text # data_type=1かつ有効なUTF-8の場合だけ
```

`mdta_keys`はkeys tableの順序を、`mdta_items`はdata atomの順序を配列で返す。
`mdta_items`は同じkeyの複数dataと未知型を失わないためHashにしない。
各値の`item_ordinal`で、同一数値item内の複数dataと、同じkey indexを持つ複数itemを
区別する。未変更の数値itemはitem単位の生bytesを保持して再利用する。

想定API:

```ruby
tag.mdta_keys
tag.mdta_items
tag.mdta_item("audio_normalization", namespace: "mdta") # 最初の値。値がなければnil
tag.set_mdta_string("audio_normalization", "loudnorm", namespace: "mdta")
tag.remove_mdta_item("audio_normalization", namespace: "mdta")
```

未知のdata typeは型番号、locale、payloadをそのまま保持し、UTF-8文字列へ暗黙変換しない。

## 通常プロパティとの優先順位

`title`、`artist`、`TVShowName`（mdtaの`show`）、`description`は次の優先順位とする。

1. 通常4バイトatom名のitem（物理的に`mdir` meta内か`mdta` meta内かは問わない）に対応する
   itemが存在すれば、それを通常ilstとして使用する。
2. 通常itemが無く、mdtaに有効なUTF-8値があればmdtaへフォールバックする。
3. mdtaが非UTF-8または未知型の場合は文字列化しない。生値はmdta APIから取得する。

通常の`title=`、`artist=`等は通常itemだけを変更する。mdta値は自動同期しない。
mdta setterはmdtaだけを変更する。これにより、同名キーが両方にある場合も意図しない上書きを防ぐ。

`audio_normalization`と`audio_normalization_target`はmdta APIで扱う。

通常titleとmdta titleが同時に存在する場合、taglib-ruby-plusの`title`は通常itemを
返す。ffprobeのformat tagは実装上、同名値を連結して表示する場合があるため、ffprobeの
検証では単一文字列を期待せず、通常itemとmdta itemの両方が保持されていることを確認する。

## TagLib本体に必要な変更

採用した[TagLib本体へのパッチ方式](mp4-mdta-taglib-core-proposal.md)を参照する。
固定したTagLibソースへ本リポジトリ管理のパッチを適用し、専用prefixへビルドする。
parser/writerは本体へ集約し、Ruby拡張による保存後のatom再構成は採用しない。

正式対応としてTagLib本体へ提案する範囲は次のとおり。

- mdta handlerの検出
- `keys`の解析
- 数値インデックスとキー名の対応
- data type、locale、生payloadの保持
- 同一`ilst`内でも通常itemとmdta itemを分離するデータモデル
- 未知mdtaキー・未知型の保存
- 複数data atomの保持
- 通常save時のmdta保持

NI STEM対応のPR #1は、今回のmdta対応そのものではないため、解決策として流用しない。

## taglib-ruby-plus側の実装範囲

`/opt/homebrew`を変更せず、パッチ適用版TagLibへ`TAGLIB_DIR`でリンクする。
このリポジトリでは次を担当する。

- TagLibパッチ、適用順、固定ソースとchecksumの管理
- vendor/CIでのパッチ適用・専用ビルド・機能検出
- mdta専用C++ APIのbinding
- Ruby値オブジェクトとのコピー変換
- 一時コピーを修正版TagLibで保存・検証して置換する処理
- C++直接テストとRuby APIテストの接続、パッケージ検証

Ruby側ではmdta専用APIと、通常プロパティのフォールバックを追加する。

## 内部データモデル

C++側では、TagLibの`MP4::Item`とは別に次の値を管理する。

```text
MdtaDocument
├── keys[]
│   ├── index     : uint32 (1-based)
│   ├── namespace : raw bytes
│   └── key       : raw bytes
└── items[]                 # 数値ilst item単位の順序を保持
    ├── key_index : uint32
    ├── raw_atom  : raw bytes (未変更時に再利用)
    └── data_atoms[]        # 同一item内での順序を保持
        ├── data_type : uint32
        ├── locale    : uint32
        └── data      : raw bytes
```

同じキーに複数の`data` atomがある場合も、同じindexの数値itemが複数ある場合も、
item境界とdataの所属を維持する。
`keys`に存在するが値を持たないキーは`keys`だけに保持する。

RubyとC++の境界では、keysとitemグループを別配列にする。

```ruby
[
  [key_index, [[data_type, locale, binary_data], ...]],
  ...
]
```

この形式は`ItemMap`を直接公開せず、キーだけの存在、item境界、型情報、locale、
生payloadを失わない。Ruby公開値はdata atomごとのimmutable copyとし、`item_ordinal`を
併せて返す。

## 通常ilstとmdtaの混在

物理的なmetaのhandlerだけでなく、同じ`ilst`内のitem名も判定する。

- handler=`mdta`かつitem名が1始まりの数値atom: `MdtaDocument.items`
- 4バイトatom名の通常item（`©nam`、`©ART`など）: 通常`ItemMap`
- keysにない数値atom、壊れたkeys参照: 保存前に`MdtaSaveError`

実測したAtomicParsley fixtureでは、mdta metaの同じ`ilst`に数値itemと`©nam`／`©ART`
が混在した。したがって、通常itemを必ず別の`mdir` metaへ移す設計は採用しない。
通常itemは元のmeta位置を保ち、mdtaの数値itemを同じ`ilst`へ戻す。

`handler=mdir`の通常metaは通常`ItemMap`として扱う。複数metaがある場合も、meta単位の
handlerとitem名を保存し、出力時にmetaの順序を勝手に変更しない。

handlerを解釈できないmetaは、可能な範囲でatom bytesをそのまま維持する。

ここでの「4バイト」はMP4ファイル上のatom名の幅を指す。Rubyの`ItemMap`キー長では
判定しない。例として`©nam`はファイル上では`a9 6e 61 6d`の4バイトだが、Rubyの
UTF-8文字列では5バイトになる。freeform itemはraw atom名が`----`であり、
`ItemMap`では`----:com.apple.iTunes:iTunEXTC`のような長いキーになる。

## Ruby APIの詳細案

`TagLib::MP4::MdtaKey`と`TagLib::MP4::MdtaItem`をRuby管理下のimmutable value object
として公開する。`MdtaItem`はdata atomに対応し、key-only entryは`mdta_keys`から取得する。

```ruby
item = TagLib::MP4::MdtaItem.new(
  namespace: "mdta",
  key: "audio_normalization",
  data_type: 1,
  locale: 0,
  data: "loudnorm"
)
```

公開する操作は次のとおり。

```ruby
tag.mdta_items                    # 順序を保持したMdtaItem配列
tag.mdta_item("title", namespace: "mdta") # 最初の一致、無ければnil
tag.set_mdta_item(item)            # 同一namespace/keyの値を置換
tag.set_mdta_string(key, value, namespace: "mdta") # data_type=1のUTF-8 API
tag.remove_mdta_item(key, namespace: "mdta")       # keyと値を全削除
```

`MdtaItem#text`は`data_type == 1`かつ有効なUTF-8の場合だけ返す。
それ以外は`nil`とし、`data`を暗黙に文字列化しない。

`MdtaItem#key_index`は読み取り専用の解決結果とし、setterの指定値にはしない。
既存のnamespace/keyを更新すると、そのkeyの全data atomを1件に置換し、既存のkey indexを
維持する。新規keyはkeys tableの末尾へ追加する。`set_mdta_item`も同じ置換規則を使い、
`data_type`、`locale`、生payloadをそのまま保存する。

`set_mdta_item`は既存のmdta `keys`／`ilst`がある場合、新規キーをkeys table末尾へ追加する。

`remove_mdta_item`は指定keyの全data atomとkeys tableの項目を削除し、後続のkeys indexと
数値ilst item名を1つずつ繰り上げる。読み出したkey-only entryを保持したい場合は、明示的な
変更を行わず通常保存する。未知型の値を文字列setterで更新する操作は提供しない。

数値itemのraw atomを再利用できるのは、key index、item ordinal、data atom列が変わらない
場合だけとする。keyの削除・追加、値の置換、indexの再採番が発生したitemは新しいatomを
生成する。

文字列setterは、既存のMP4文字列プロパティと同じくUTF-8へ変換可能な値を受け付け、
変換不能な値、NULを含む値、無効なUTF-8値は変更前に拒否する。

## 保存トランザクション

`File#save`は次の段階を持つ。

### 準備

1. TagLib保存を呼ぶ前に、TagLib本体の編集モデルとして元MP4の全meta atom、keys、
   mdta数値item、通常item、削除状態、構造上の位置（`udta`内のmeta順、handler、
   ilst内の順序）と生bytesをsnapshotする。
2. snapshotから編集可能なworking modelを複製する。通常`ItemMap`、chapter状態、
   mdta状態の変更はこのworking modelへ適用する。公開ItemMapとmdta配列から再構成しない。
3. mdtaのkeys/items/data_atomsと削除状態を検証し、working modelから出力可能なbyte列へ
   変換する。
4. 同一ディレクトリに一時ファイルを作り、元MP4をコピーする。

この時点では元MP4を変更しない。

### 一時ファイルの生成

1. 一時ファイルを新しいTagLib `MP4::File`で開く。
2. TagLib本体の状態複製操作で、通常item、mdta、未知atom、削除状態、meta所属を一括して移す。
3. 現在変更されているNero／QuickTime chapterを移す。未保存tag変更を失う再構成はしない。
4. TagLibの通常`save()`を一時ファイルへ実行する。
   このsaveはパッチ適用版を使い、通常ItemMapに加えて編集済みmdta状態も事前に移す。
5. 通常itemとmdtaの合成、keys/ilstの整合性、親atomサイズとchunk offsetの更新は
   TagLib本体のwriterが担当する。Ruby側で保存後のatomを再構成しない。
6. 一時出力を独立に再読込し、後述の検証へ進む。

TagLibが誤認識したmdta数値itemは、通常`ItemMap`へ移さない。通常item、既存の`zzzz`、
新規の未知item、長いRubyキーを持つfreeform itemは、TagLib本体の編集モデルから同じ
meta所属と順序で出力する。分類には元atomのraw名とhandlerを用い、Rubyの文字列長を
判定条件にしない。
keysにない数値itemや参照範囲外のindexを検出した場合は、元MP4を置換せず
`MdtaSaveError`にする。

snapshotの識別にはbyte offsetを使わない。TagLib保存でmetaの大きさが変わるため、
構造上の位置から一時ファイル内のmetaを再特定する。再構成で`moov`と`mdat`の相対位置が
変わる場合は、`stco`／`co64`のchunk offsetを更新し、変換後のatom境界を再検証する。

### 検証とcommit

1. 一時ファイルを新しいTagLib Fileで再読込する。
2. 通常ilstのtitle、artist、artwork、freeform、chapterを確認する。
3. mdtaのkey、data type、locale、payloadを確認する。
4. ファイルサイズ・atom境界・chunk offsetの整合性を確認する。
5. 通常metadata保存では全mdat payloadの順序・長さ・SHA-256一致を確認する。chapter変更時は
   chapter以外の全trackのsample bytesと長さを比較する。対応不能なレイアウトは拒否する。
6. 書込み側をflush/closeし、I/Oエラーとfsync結果を確認してからrenameで元パスへ置換する。
7. 元パスを新しいTagLib Fileで開き直す。
8. SWIGのFileポインタを新しいFileへ差し替える。

rename前に失敗した場合、元MP4は変更しない。
rename後の再openまたはwrapper再接続失敗では旧Fileと全借用wrapperを無効化し、Fileを
使用不能にする。例外は`committed=true`と失敗phaseを持ち、出力は置換済みであることを示す。
rename前の失敗は`committed=false`で元Fileと未保存編集を維持する。I/O失敗の検出を
再openだけに依存させず、TagLib本体のエラー報告を必須とする。

## SWIG wrapperの寿命

保存成功時は、古いFile native objectを破棄し、新しいnative Fileを同じRuby File wrapperへ関連付ける。
rename後の失敗時も古いnative objectを使用不能にする。古いオブジェクトへ戻してはならない。
古いFileが所有していた次のborrowed wrapperは無効化する。

- `Tag`
- `ItemMap`
- `Item`
- `Properties`

保存後は必ず`file.tag`、`file.tag.item_map`、`file.audio_properties`を再取得する。
これは今回、既存wrapperの互換性よりも元MP4を壊さない保存を優先する決定による。

## エラー契約

次の例外を追加する。

- `TagLib::MP4::MdtaItemError`: mdta entryの型、キー、payloadが不正
- `TagLib::MP4::MdtaSaveError`: 一時保存、atom再構成、検証、rename、再openの失敗

保存失敗時は`false`を返さず、`MdtaSaveError`を送出する。
既存のchapter専用`ChapterSaveError`の契約とは分離する。

保存例外には`committed`と`phase`を持たせ、chapter専用保存も同じ置換状態を通知する。
ItemMapの直接clear/erase/insertは、本体の読み込み時snapshotとの差分で検出して内部モデルに
反映する。`isModified`をsetterフラグだけで実装しない。詳細と失敗系の検証結果は
[本体設計](mp4-mdta-taglib-core-proposal.md)の2026-09-20レビュー検証を参照する。

## 検証マトリクス

| fixture | 操作 | 検証 |
|---|---|---|
| mdtaのみ | 通常title変更 | mdta全entryと新しい通常title |
| mdtaのみ | mdta title変更 | mdta titleと通常ilstの不存在 |
| mdtaのみ | mdta normalization変更 | UTF-8型、値、他のmdtaキー |
| 通常ilstのみ | 通常save | 既存テストと同じtitle、artist、artwork、freeform |
| 通常ilst + mdta | 両方にtitle | 通常ilstを優先し、mdtaも保持 |
| mdta未知型 | 通常save | data type、locale、生payloadの一致 |
| chapter付きmdta | `save_chapters` | mdtaと通常ilstの非変更 |
| mdta無し | 通常save | 既存MP4テストの全通過 |

Ruby APIと同じfixtureに対して、TagLib C++ APIを直接呼ぶテストも追加する。

## 設計見直しに使った簡易検証

実装前のatom確認用に、依存関係のない
[`test/mp4_mdta_atom_probe.rb`](../test/mp4_mdta_atom_probe.rb)を追加した。
`--check`は`moov`の存在と`moov/udta/meta`内のmdta `ilst`の数値indexを検査する。
`--expect-mdta`はmdta metaの存在も要求し、`--require-value=KEY=TEXT`は指定keyの
UTF-8値まで要求する。`--json`はitemごとのdata所属と、data type、locale、payload hex、
UTF-8文字列を出力する。
TagLibを通さないため、保存前後のatom構造を独立に確認できる。artwork、chapter、通常
ItemMapの意味的な一致は、TagLibを再読込する別テストの責務とする。

確認結果:

- 合成fixtureでは同じkey indexの数値itemを2個作り、1個目にdata atomを2個置いた。
  probeはitem境界とdata個数`[2, 1]`を区別し、未知型`33`のpayloadを文字列化しなかった。
- data payload headerが8 bytes未満の短い`data` atomは`truncated data atom`として拒否し、
  key index `0`の数値itemもkeysの範囲外として拒否した。壊れたfixtureを正常値として
  扱わない境界を固定した。
- keysだけ残って値がないfixtureは`--require-value=title=...`で拒否された。FFmpeg fixtureの
  title、show、artist、description、normalization 2項目は必須値検査を通過し、現行TagLib
  保存後fixtureはkeysが残っていても必須値検査に失敗した。
- `moov/udta`以外のtrack-level mdta metaを持つ合成fixtureは、
  `--expect-mdta`で対象外として拒否した。空ファイルは`--check`で拒否した。
- FFmpeg fixtureは`handler=mdta`、keysは`title`、`show`、`artist`、`description`、
  `audio_normalization`、`audio_normalization_target`、`encoder`の7件だった。
- 7件すべてdata type `1`、locale `0`のUTF-8 payloadだった。
- 通常metadataだけのFFmpeg fixtureは`handler=mdir`で、`©nam`、`©ART`などの
  通常itemだった。
- mdta fixtureにAtomicParsleyでtitle/artistを追加すると、別metaではなく同じ
  `handler=mdta`の`ilst`に`©nam`／`©ART`が追加された。
- keysにないindex `256`を持つ検証用fixtureでは、probeの`--check`が終了コード1で
  `has no keys entry`を報告する。
- data typeを`33`へ変更した検証用fixtureでは、payloadのhexは表示されるが`text`は
  出力されず、型をUTF-8へ暗黙変換しない方針を確認できた。
- 現行TagLib 2.3.2でtitleだけを保存すると、keysは残るが数値itemが消え、`©nam`だけが
  mdta metaの`ilst`に残った。ffprobeからmdtaの他キーも消えた。
- `mp4_mdta_direct_baseline.cpp`でも、読み込み時のtitleは空、保存は成功するが、保存後の
  必須mdta値検査は失敗した。Ruby bindingだけの問題ではないことを再確認した。
- 既存MP4テストの実行は`shoulda-context`未インストールで停止した。依存gemの追加は行わず、
  Ruby構文、probe専用テスト、実fixture、C++コンパイルとbaseline実行までを確認した。

この結果により、当初案の「通常metaとmdta metaを必ず分離する」は撤回した。
meta handlerとitem名を組み合わせて分類し、keys tableは独立して保持する設計へ変更した。

## 保存安全性

TagLibの通常保存は同一ファイルを直接変更するため、保存処理の安全化が必要である。

採用する方式は次のとおり。

1. 同一ディレクトリへ一時出力を作る。
2. 通常ilst、chapter、mdtaを一時出力へ保存する。
3. 新しいTagLib Fileで保存結果を再読込する。
4. ffprobe相当のatom検証とmdta検証を行う。
5. 成功後にrenameする。
6. SWIGのFileポインタを新しいFileへ更新する。

保存前に取得したTag、Item、Propertiesの借用wrapperは無効化する。保存後は`file.tag`等から再取得する。
互換性維持のために同一ネイティブFileを使い続ける方式は採用しない。

## 互換性

- 通常ilstの`ItemMap` APIは変更しない。
- artworkは通常ilstの`covr`として保持する。
- freeform itemは通常ilstのまま保持する。
- `save_chapters`はmdta通常保存と干渉させない。
- 未保存の通常tag/mdta変更を伴う`save_chapters`は拒否し、先に通常`save`を要求する。
- mdtaの読み書きは通常`ItemMap`とは別APIにする。
- 既存の通常MP4を可能な範囲で保持するが、保存後のborrowed wrapperの寿命は保証しない。
- 保存後のTag、Item、Propertiesは再取得を必須とする。
- UTF-8文字列の入力は既存のUTF-8変換・検証方針に合わせ、変換不能値は拒否する。

## 検証計画

実装時に次を追加する。

- FFmpeg生成のmdta fixture
- 保存前後のffprobe確認
- 保存前後のTagLib Ruby確認
- C++直接APIの保存前後確認
- title変更後もmdtaが残ること
- mdta変更後もtitle、artist、artwork、chapterが残ること
- mdta無しMP4の既存テスト
- `save_chapters`との非干渉
- 未知キー・未知型・locale・生payloadの往復
- Ruby構文、C++コンパイル、既存MP4テスト、実ファイルfixtureテスト

実装前のbaseline確認には次を使う。

```sh
ruby test/generate_mp4_mdta_fixture.rb /tmp/mdta-fixture.mp4
test/mp4_mdta_atom_probe.rb --expect-mdta \
  --require-value='title=MDTA Title' \
  --require-value='show=MDTA Show' \
  --require-value='artist=MDTA Artist' \
  --require-value='description=MDTA Description' \
  --require-value='audio_normalization=loudnorm' \
  --require-value='audio_normalization_target=-16-LUFS' \
  /tmp/mdta-fixture.mp4
clang++ -std=c++17 -I/opt/homebrew/opt/taglib/include \
  test/mp4_mdta_direct_baseline.cpp \
  -L/opt/homebrew/opt/taglib/lib -ltag -o /tmp/mp4_mdta_direct_baseline
/tmp/mp4_mdta_direct_baseline /tmp/mdta-fixture.mp4 /tmp/mdta-fixture-saved.mp4
```

`generate_mp4_mdta_fixture.rb`は`FFMPEG`環境変数でFFmpegの場所を変更できる。
これらは開発時のfixture生成・現状確認用であり、taglib-ruby-plusの実行時依存にはしない。

## 実装前に固定する制約

- 通常保存では`udta`内の複数mdta metaをsnapshotして全て保持する。
- mdta APIの更新対象は、同一`udta`内にmdta metaが1つだけの場合に限定する。複数ある
  場合はkey indexの所属が曖昧になるため、mdta setterは`MdtaSaveError`を送出し、
  明示的な変更を行わない通常保存だけを許可する。
- keysが壊れている、数値itemがkeys範囲外、data atomが切れている場合は、通常保存でも
  元パスを置換しない。

## 未解決点

- TagLib本体へ提案する公開APIの最終的なC++型名と、既存`MP4::Item`との責務分離は、
  上流レビューで確定する。taglib-ruby-plus側では先に`MdtaKey`／`MdtaItem`相当の内部
  モデルを実装できるが、上流APIを独自に確定したものとは扱わない。
- `udta`内に複数のmdta `meta`があるファイルは、通常保存で全て保持する一方、mdta setter
  の対象選択規則は未確定である。当面は曖昧さを避けてsetterを失敗させる。
- `moov`の再配置で`stco`から`co64`への切替が必要になる境界は、実装時に大容量・faststart
  以外のfixtureで追加検証する。保存前の元ファイルを置換しない契約は変更しない。
- ffprobeが同名の通常itemとmdta itemをどう表示するかはffprobeの出力仕様に依存するため、
  APIの優先順位判定には使わない。検証ではatom単位の値を正本とする。

## 決定事項

固定TagLibソースと本リポジトリ管理のパッチを採用し、専用ビルドをRuby拡張へ接続する。
mdtaの解析・保持・編集・出力は本体、API接続と安全なファイル置換はRuby側の責務とする。
第一実装を開始し、TagLib v2.3.2固定commit向けパッチ、C++直接テスト、Ruby API、
temp+rename保存、再open検証、通常saveのmdat payload hash検証、`save_chapters`の
未保存metadata拒否までを実装した。TagLibパッチは`patches/taglib/`で管理し、vendor
タスクが適用済みのTagLibだけをRuby拡張へ接続する。

第一実装のRuby APIは`mdta_items`／`mdta_item`／`set_mdta_item`／`remove_mdta_item`。
`MdtaItem#text`はtype 1の有効UTF-8だけを返し、その他は生binary `data`から暗黙変換しない。
通常title／artistは通常ilst itemを優先し、通常itemが無いときだけmdta UTF-8値へfallbackする。

TagLib本体には`IOStream::hasError()`と`File::ioError()`を追加し、短いwrite、seek、truncate、
flushの失敗をsave結果へ伝播させた。chapter変更時の保存検証はtrackのsample tableを読み、
元ファイルに存在する非chapter trackのsample payloadをtrack ID単位で比較する。
chapter trackの追加・削除によるmdatの増減は許可し、sample tableを解釈できない対象は
成功扱いにしない。

互換性よりも保存安全性を優先し、temp + rename + SWIG Fileポインタ再生成を採用する。
保存後に古い`tag`、`Item`、`Properties` wrapperを再利用できないことは仕様とする。

### 保存処理とCIの責務整理

一時保存・再読込検証のハンドル寿命は既存の`FileOpenable.open`に集約する。
保存後のmetadata snapshotは再初期化時に一度だけ取得する。再open失敗の通知は
`MdtaSaveError`の`committed`と`phase`で行い、参照されない状態フラグを持たない。
metadata比較とmdat検証は保持安全性のため継続する。

CIのRuby MP4 APIテストは`rake test`の全件実行に集約し、C++直接テストと
配布gemのsmoke testはそれぞれ別の経路を検証するため維持する。
TagLibキャッシュはインストール成果物だけを対象とし、パッチとビルド定義の
ハッシュをキーに含めて、変更前のTagLibを再利用しない。

保存API名と検証規則を分離する。`save`はmetadataと保留中chapterを保存し、
`save_chapters`はmetadataの未保存変更を拒否してchapterだけを保存する。
いずれも保留中chapterがある場合は非chapter trackのsample payload保持を検証し、chapterが
無変更ならmdat列の完全一致を要求する。chapter用mdatの増減の許容を
`save_chapters`という呼出名に結び付けない。これにより通常`save`でも
metadataとchapterを一回のファイル置換で保存できる。

## 責務整理の再設計と再レビュー（2026-09-20）

この節は次のリファクタリングの設計と、その実装結果を記録する。
保存対象とchapter編集有無の分離などを採用済みである。
目的は安全性の検証を減らすことではなく、状態の正本と判定箇所を減らすこと。

### 初案

1. パッチ済みTagLibを必須にし、未対応環境向けfallbackを除去する。
2. chapter編集状態をRubyに集約し、C++へは保存時だけ反映する。
3. snapshotを必要なときに取得し、一時保存・検証の無駄な変換を減らす。

### 再レビューでの修正

| 初案への指摘 | 最終方針 |
| --- | --- |
| バージョン2.3.2だけではmdta対応を識別できない | MP4拡張の構築時に必要なC++ APIをコンパイル・リンクして確認する |
| Rubyにchapter状態を移すだけではC++ setterの入力検証が消える | 既存のchapter変換・検証を副作用のないbindingへ切り出し、検証後だけRubyの状態を確定する |
| snapshotを最初のsaveまで遅延すると、それ以前の直接ItemMap編集を見落とす | 公開Fileのopen直後のbaselineを維持する。内部openの重複取得だけを除去する |
| chapter setter呼出しがあるだけでmdat検証を緩めるのは広すぎる | 変更対象の表現と期待chapterを記録し、再openでchapterの値と存在を検証する |
| Rubyでmetadata全部を編集モデル化するとC++の保持モデルを重複する | ilst/mdtaの編集状態と不透明atomはC++を正本に据え置く |

### 採用する責務分担

| 層 | 所有する状態・責務 | 所有しない責務 |
| --- | --- | --- |
| TagLib本体 | ilst/mdtaの解析・編集・不透明データ保持、atom出力、I/O失敗通知 | Ruby APIの編集セッションやパス置換 |
| C++ binding | 型変換、chapter入力検証、保存用native状態への適用 | 第二の永続的なchapter編集状態 |
| Ruby MP4::File | metadata baseline、chapter編集要求、コピー・検証・置換の順序 | mdta atomの再構成 |

汎用Transaction、Repository、Strategyなどの新しい階層は導入しない。
既存Fileの非公開メソッドと小さな状態で表現する。将来ほかの形式にも共通の
保存契約が必要になった場合にのみ、別クラスへの抽出を再検討する。

### 1. 対応環境は一つにする

MP4拡張のextconfで`mdtaItems`、`setMdtaItem`、`removeMdtaItem`、`copyStateTo`を
確認する。ヘッダー検査だけでなくリンクまで行い、未対応なら
専用TagLibのビルド方法を示して構築を止める。バージョン番号による推測はしない。
実行時のヘッダー／共有ライブラリ取り違えも対象として、拡張ロードのsmoke testを行う。

Rubyでは`mdta_items`の未対応時空配列と、`copy_tag_state_to`のItemMapだけの
fallbackを削除する。未対応をmetadata空集合として扱わない。古い拡張がロードされた
場合の入口検査は一箇所に置き、個々のsetterの能力判定を重複させない。
gemspec・READMEの「通常TagLib 2.3.2以上でよい」という案内も同時に更新する。

### 2. chapterはRubyの編集要求を正本にする

未編集の表現はディスクから読む。変更要求は`:nero`／`:quicktime`ごとのHashに保持する。
キーなしは未変更、空配列は削除、非空配列は置換を意味する。全表現を毎回コピーして
書き戻さず、指定された表現だけを一時ファイルのnative setterへ適用する。

setterはstyleと入力全体を検証し、独立した配列へ正規化した後に要求を確定する。
不正入力では既存要求もnative状態も変えない。検証は既存bindingの変換処理を再利用し、
Rubyに同じ検証ロジックを複製しない。元ハンドルのnative chapter setterは呼ばない。
保存前の読取りは、変更要求がある表現だけ要求を返し、それ以外をディスクから読む。
`:preserve`とNero/QuickTime競合検知は、この合成した状態を対象に判定する。
空chapter atomの存在とchapter件数は別概念として扱い、未編集表現を勝手に正規化しない。

一時ファイルへの適用は非公開native setterを直接使い、公開Ruby setterを再帰的に
呼び出して第二の編集要求を作らない。旧`_save_chapters`経路は呼出元を調べた上で、
不要ならhelperごと削除する。C++のchapter書込み能力そのものは残す。

### 3. snapshotは用途を限定する

公開Fileのbaselineはopen時に一度取得し、成功後の再初期化で更新する。
これによりItemMapの直接insert/erase/clearも`save_chapters`で検知できる。
setterのdirtyフラグへの置換や、最初の保存までの遅延は採用しない。

一時書込み・再読込検証用の内部openにはbaselineが不要である。
非公開の内部openでnative初期化とensure-closeだけを行い、公開コンストラクタに
利用者向けのskipオプションは追加しない。検証時のactual snapshotは一度だけ取得する。
期待値はrename前まで保持する。未知型の値を省略したsnapshotを完全な保持証明とは
扱わず、不透明データはC++直接テストとatom比較でも検証する。

### 保存時の契約

保存対象決定 → 元ファイルをコピー → C++ metadata状態とchapter要求を適用 →
native saveとclose → 再openしてmetadata・chapter・mediaを検証 → 置換 → 再open。

`save_chapters`はmetadata変更があれば拒否し、`save`は両方を保存する。
metadata比較とchapter比較は別に実施する。chapter比較は順序・時刻・タイトル・
表現の存在を対象とし、変更しない表現も期待値に含める。
変更なしならmdat列を完全一致で検証する。chapter変更時も元mediaの保持は必須とする。
ただし、元mdat列の部分列一致だけでは追加mdatがchapter由来かまでは証明できない。
この制約は現実装にもあり、今回の整理で「chapter追加だけを保証」と強く主張しない。
追加mdatの所属検証や特殊レイアウトの許否は別の安全性実装課題として残す。

rename前の失敗では元ファイルと未保存要求を維持する。成功後だけ要求を消す。
rename後の再open失敗は`committed=true`を通知し、旧ハンドルへ戻さない。
fsync、同時更新検知、一時ファイルの排他的作成は既存実装との差分を別途確認する。
本再設計はそれらが実装済みという主張ではなく、コピーとハッシュの削除も行わない。

### 実装順と必須検証

1. 能力検査とfallback除去：パッチ有無、ヘッダー／ライブラリ不一致、空mdtaを検証。
2. chapterの検証／適用分離：不正入力で状態不変、片方だけ更新・削除、競合、
   preserve、metadata同時保存、保存失敗後の再試行を検証。
3. 内部openの整理：直接ItemMap編集の検知、連続保存、例外時close、保存後再open失敗を検証。
4. 呼出しのなくなった旧経路を削除し、SWIG生成物を同期する。

各段階でRuby/C++の既存回帰テスト、通常MP4、mdta fixture、配布gem、Ruby 3.2/4.0の
CIを確認する。設計契約テストのスキップを成功の代わりにせず、必要なC++ probeを
構築して実行する。

実装済みの範囲は、TagLib mdta APIのビルド時リンク検査、Ruby側のmdta fallback除去、
chapter変更要求の遅延適用、通常saveとchapter saveの原子置換・再読込検証、既存の
Ruby/C++ mdta回帰テストである。TagLibパッチなしの環境は拡張ビルド時に拒否する。

### 再レビュー結論

採用するのは能力判定の集約、chapter編集状態の単一化、内部baselineの省略である。
削減量に対して新しい抽象化が増える全面的な保存フレームワーク化は採用しない。
本整理のためのTagLib上流API追加は不要で、既存パッチとbinding/Rubyの責務整理で進める。
既存mdtaパッチ自体の上流提案は別途必要である。なお、現時点ではローカルの
TagLibパッチが依存契約であり、上流へ取り込まれるまでは通常TagLibとの互換性を
要求しない。
