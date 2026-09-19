# TagLib本体でのMP4 mdta対応設計（パッチ方式採用）

2026-09-19。ユーザー承認によりパッチ方式を採用。2026-09-20に第一実装を開始した。
既存の[保持設計](mp4-mdta-preservation-design.md)に対し、TagLib本体の変更を
このリポジトリで管理するパッチとして適用する。製品コードの変更は含まない。

## 採用方式と根拠

TagLib本体にmdtaの解析・保持・編集・シリアライズを集約し、Ruby拡張は値のコピー変換と
安全なファイル置換を担当する。既存案の「通常save後にRuby拡張でkeys/ilstを再構成する」
経路は、本体対応版では不要になる。二重のMP4 writerを維持しなくて済む。

前回の実ファイル検証対象はローカルTagLib 2.3.2。今回の変更箇所調査は上流masterの
ソースを参照した。両者のソース同一性は未確認であり、実装開始時には採用するTagLibの
commit SHAを固定して差分を再確認する。以下のファイル名・関数名はmaster側のもの。

- `mp4tag.cpp`: コンストラクタは最初に見つかる`moov/udta/meta/ilst`をItemFactoryで読む。
  `save()`はItemMapからilstを生成し、`saveExisting()`または`saveNew()`へ渡す。
- `mp4itemfactory.cpp`: `parseItem()`はatom名で分岐する。mdtaの解釈に必要な、親metaの
  handlerとkeys tableを引数に持たない。Factoryへの数値名追加だけでは解決しない。
- `mp4atom.cpp`: `find()`は最初の一致を返す。複数metaの保持には子atomの列挙が必要。
- `mp4file.cpp`: 通常saveはtag保存後に変更されたchapterを保存する。
  IOStreamから開くAPIもあり、全Fileにファイルパスを前提としたrenameは導入できない。

## 変更箇所

| 場所 | 変更案 |
|---|---|
| `mp4tag.cpp/.h` | meta列挙、通常item/mdtaの振り分け、専用API、save/strip/isEmptyの契約 |
| 新規のmdta用クラス | keys、itemグループ、data、opaqueな子atom、変更状態の管理 |
| `mp4atom.cpp/.h` | 実header長・payload位置と親境界の検証、更新後のatom treeの整合性 |
| `mp4tag.cpp`の保存補助 | keysとilstを含むmeta更新計画、サイズ・offset計算、失敗の伝播 |
| `mp4file.cpp` | tag保存後のchapter処理と再保存時の整合性、失敗時の戻り値 |
| TagLibのMP4テスト | C++単体で保持・読み書き・異常系を検証 |

`mp4atom`の全体書き換えは不要。既存の通常item parser、artwork、freeform、chapter処理は
再利用し、mdtaを解釈する入口と出力の組み立てを追加する。

## 第一実装の確定内容

`patches/taglib/0001-mp4-mdta-preservation.patch`をTagLib v2.3.2の固定commitへ適用する。
本体には`MP4::MdtaItem`、`MdtaItemList`、`Tag::mdtaItems()`、既存キーを更新・削除する
`setMdtaItem()`／`removeMdtaItem()`、`Tag::copyStateTo()`を追加した。`Tag`はmdtaの数値
itemを通常`ItemMap`へ入れず、キーindex、型、locale、生payloadと元atomを保持してから、
通常itemと同じ`ilst`更新で再出力する。未解釈の4-byte itemもopaque bytesとして保存する。

Ruby側の公開APIは`mdta_items`、`mdta_item`、`set_mdta_item`、`remove_mdta_item`であり、
通常`item_map`とは別である。`MdtaItem#text`はdata type 1かつUTF-8が有効な場合だけ値を
返す。通常itemがあるtitle／artistは通常itemを優先し、無い場合だけmdtaのUTF-8値へfallback
する。`show`と`description`もproperty APIから同じfallback規則で読める。

通常`save`と`save_chapters`は同一ディレクトリの一時コピーへ保存し、独立再読込、metadata
比較、通常save時のmdat payload SHA-256比較を通過してからrenameする。metadata変更を伴う
`save_chapters`は`ChapterSaveError`で拒否する。rename後の再open失敗は`committed: true`
の`MdtaSaveError`とし、旧wrapperを再利用しない。

## 読み込みとデータモデル

`moov`直下の`udta`とその直下の`meta`を列挙し、文書IDを割り当てる。track-level metaは
初期の編集対象外とする。各文書はhandler、子atom順序、keys、ilst、未解釈bytesを持つ。

キーの実体識別子は`(document ID, key index)`。namespaceとキー名は生bytesも保持する。
同名キーが重複してもHashにまとめない。数値itemごとに子atomの順序を保持し、dataの
型を示す32-bit wire field、locale、payload、未知の子atomを欠落させない。
文字列表示は既知のUTF-8形式かつ妥当なbytesの場合だけ提供する。

通常itemは既存ItemFactoryへ渡し、出自のmetaとilst内の位置を別途記録する。
mdta数値itemはItemFactoryへ渡さない。分類はhandler・keys参照・既知通常atomを使い、
「先頭byteが0なら数値」といった簡易probeの規則を製品コードへ移植しない。
未知名と数値参照の区別が曖昧な場合は生bytesを保持し、そのitemの編集を拒否する。
壊れた参照や境界を検出したファイルは保存前検証で拒否する。

専用API名は仮に`mdtaDocuments()`、`setMdtaString()`、`setMdtaValue()`とする。
低水準APIは文書IDとkey indexを指定できるようにし、名前による便利APIは一意に
解決できる場合だけ許可する。既存Ruby案の複数meta時のsetter拒否と両立できる。
key削除による再採番は、その文書の全item参照へ一括反映する。再採番対象を安全に
解釈できない場合は削除を拒否する。

`ItemMap`は公開用の通常item viewであり、保存の正本にはしない。Tag内部の編集モデルは
meta childの順序と、各childのlive/deleted状態を持つ。通常itemを削除した場合は明示的な
deleted状態として扱い、元atomを一時Fileへコピーするだけで削除が復活しないようにする。
未編集のopaque childはraw bytesで再利用し、編集対象になった`keys`または`ilst`は、
残す通常item・mdta item・未知itemを明示的に合成して出力する。

一時Fileへの保存では、Rubyが公開配列から状態を再構成しない。TagLib本体に
`MP4::Tag::copyStateTo(Tag&) const`相当の、公開C++宣言だがSWIGからは隠す操作を追加する。
この操作はsourceの編集モデルをdestinationへ複製し、ItemMapに表現されない未知atom、
削除、meta所属、mdtaのkey-only entryも移送する。Ruby bindingはこの操作を一つのprivate
native operationとして呼び出す。private実装だけでは別translation unitのSWIG wrapperから
呼べないため、`TAGLIB_EXPORT`されたC++境界にする。

`MP4::Tag::isModified() const`相当はフラグだけに依存させない。通常ItemMapの現在値と
読み込み時の独立snapshotを比較し、mdta編集状態との論理和を返す。比較対象には全キー、
Itemの型、全値、artworkの形式とbytes、未知payloadを含める。共有データの浅いコピーを
snapshotとしない。比較できないItem型の編集は保存前に拒否する。

`copyStateTo`とsaveの直前にも同じ差分計算を行い、Mapから消えたキーを内部モデルの
deleted状態へ、追加・変更をlive状態へ反映する。既存bindingの`clear/erase/insert`もこの
境界で検出する。metaへの所属が一意に解決できない編集は拒否する。通常setterのフラグは
補助とし、直接Map編集による変更を見逃さない。snapshot更新は保存処理全体の成功後だけ
行い、一時コピー保存の成功で元Fileの未保存変更を解除しない。

## 保存

1. 編集済みモデルを検証し、変更対象metaの出力bytesとサイズ差分を先に確定する。
2. 未変更mdtaはraw bytesを再利用し、通常タグだけの変更でkeysを作り直さない。
3. mdta編集時はkeysとilstを同じmetaの更新計画に含める。片方を先に書いてから
   もう片方を旧offsetで更新する方式は採用しない。
4. 通常itemとmdtaが同居するmetaは位置関係を保って合成し、未知の子atomも保持する。
   新規通常itemの挿入先は既存の通常itemを持つmeta、なければ一意な編集可能mdta meta、
   それもなければ新設mdir metaとする。候補が複数で曖昧なら保存前に拒否する。
5. 既存のpadding・親サイズ・chunk offset更新処理を利用しつつ、meta単位の置換に
   適合させる。更新後のtreeと位置情報を再構築してから次の更新・chapter保存へ進む。
6. 連続saveとsave後のchapter変更を検証する。旧Atomポインタを保持する処理は再取得する。

32-bit offsetのoverflowを黙って切り捨ててはならない。初期版では`stco`から`co64`への
変換が必要な入力を書き込み前に拒否し、自動変換は別変更として追加する。
断片化MP4のoffset構造など、正しく更新できると確認できないレイアウトも同様に拒否する。

`strip()`はmdtaを含むタグ削除の範囲を明示し、`isEmpty()`はmdta値の有無も見る。
`removeUnsupportedProperties()`から未知mdtaを暗黙削除しない。

### chapter専用保存との境界

`save_chapters`はTagの`ItemMap`、mdta model、通常metadataのwriterを呼ばず、chapter atom
だけを更新する。chapter更新によるatomの移動で必要になる親サイズとchunk offsetの更新は
行うが、`keys`、metadata `ilst`、artwork、freeformの内容は入力・出力で一致させる。

tagまたはmdtaに未保存の変更がある状態で、Ruby側が一時ファイルを再openする
`save_chapters`を実行すると、その変更を失う可能性がある。この状態は保存前に検出し、
`ChapterSaveError`で拒否する。利用者は通常の`save`を先に実行する。これにより、
chapter専用保存と未保存metadataの扱いを暗黙に混ぜない。

## 通常プロパティと安全な置換

通常title/artist等の優先、mdtaへのUTF-8フォールバック、通常setterがmdtaを同期しない
規則は既存設計を引き継ぐ。ただし上流提案は保持と専用APIを先行させ、通常getterや
PropertyMapの変更は別パッチで議論する。上流で不採用ならRuby側にフォールバックを置く。
削除後にmdtaが再び見える挙動、空の通常item、重複キーの規則もテストで固定する。

本体の直接saveはIOStreamにも対応するため、原子的なパス置換を保証しない。
書き込み前の不正入力拒否と、書き込み中のI/O失敗による原本保護は別の責務である。
taglib-ruby-plusは同一ディレクトリの一時コピーを修正版TagLibで保存・再読込検証し、
成功時に置換する。通常saveとsave_chaptersの双方で原本保護を検証する。
本体の修正だけで電源断・書き込み失敗時の保護まで完了したとは報告しない。

TagLib本体の`IOStream`は現行APIで書き込み成否を返さない。再open・atom検査だけでは
書き込み成功を証明できないため、エラー状態の取得を初期パッチの必須範囲に変更する。
パスベースのFileStreamでread/write/seek/insert/remove/truncate/flush/closeの失敗を
記録し、移動用読み込みの短縮や部分書き込みも検出する。正常な短いreadとの区別は必要な
バイト数を知る呼出側が行う。flush/closeの失敗も取得してから保存成功を返す。
カスタムIOStreamはエラー報告能力を明示させ、能力不明のものは安全保存で書込み前に拒否する。
検出結果はTagLibの保存結果からRubyの保存例外へ伝播し、一時出力の置換を禁止する。

これに加えて、通常metadata保存は全mdat payloadの順序・長さ・SHA-256を元ファイルと
一時出力で比較する。offsetだけが移動した場合もpayloadは一致しなければならない。
chapter変更がある場合はchapter以外の全trackについてsample tableから各sampleの長さと
bytes列を比較し、chapter領域の追加・削除だけを許可する。未対応レイアウトは拒否する。
この比較はメモリ上の全読込ではなくストリーミングで行い、大容量入力の追加I/Oも仕様とする。
タグ値・未知atom・構造・offsetの検査も併用し、メディア一致だけを成功条件にしない。

rename成功後に再openまたはwrapper再接続が失敗した場合、旧Fileと全借用wrapperを
必ず無効化し、File wrapperを使用不能状態にする。例外に`committed=true`と失敗phaseを
付ける。rename前の失敗は`committed=false`で元Fileと編集状態を維持する。旧Fileの
解放はflushを伴う可能性があるため、rename前にそのI/O完了を確認しておく。

### レビュー結果

簡易C++検証で、現行TagLibはmdta-only fixtureを読むと`title`が空である。通常titleを設定
して保存すると、Fileを破棄してから再openした`title`は更新値を返す。一方、atom上のmdta
数値itemは失われる。したがって、通常itemの保存自体は既存処理を再利用できるが、mdtaを
通常ItemMapへ混ぜず、通常itemとmdta documentを別モデルとして読み、同じsave計画から
両方を出力する設計を採用する。

また、公開ItemMapとmdta配列を別々に一時Fileへ移す方式は、削除・未知atom・meta所属を
失うため採用しない。TagLib本体の編集モデルを複製してから保存する方式へ変更した。

## 開発・配布と順序

上流TagLibのcommit SHAを固定し、このリポジトリで管理するパッチを適用して、
リポジトリ内の隔離prefixへビルドする。ビルド入力の正本は固定ソースとパッチ列とし、
forkの可変ブランチへ依存しない。forkは上流提案時の作業・提出先として使う。
既存`TAGLIB_DIR`でRuby拡張をそのprefixへリンクする。HomebrewのTagLibは変更しない。
実装時にはvendorタスクとCIのcache keyへpatch revisionを含める。
バージョン番号だけで判定せず、mdta APIのコンパイル・リンク試験と実行時リンク先確認を
行い、ヘッダだけ修正版で実行時に未修正版をロードする状態を防ぐ。

1. 上流テストへ最小fixtureと「title保存でmdtaが消える」失敗テストを追加。
2. 通常保存で既存mdtaを保持する内部モデルとwriterを追加。公開APIは最小化。
3. 型付きmdta専用API、新規キー・更新・削除、未知型・重複dataのテストを追加。
4. 通常プロパティのフォールバックを別パッチとして提案。
5. 修正版をRubyに接続し、実fixture・artwork・freeform・両chapter形式・save_chapters・
   連続save・未保存metadataを伴うsave_chaptersの拒否・I/O失敗時の原本ハッシュ不変を確認。

上流採用を待つ間も、このパッチ適用版を利用する。NI STEMは別atomを読み書きする構成の参考に限り、
keys参照・型付きpayload・複数metaを扱うmdta実装の代用にはしない。
今回PR #1本文は取得できておらず、上流masterのstem保存分岐だけを再確認した。

### パッチ管理とビルドの契約

実装時の配置は`patches/taglib/`とし、READMEにベースSHA・取得元・ソースのSHA-256・
適用順・各パッチの目的を記録する。パッチは保持、編集API、プロパティ連携などの
意味単位に分け、対応するC++回帰テストを含める。現時点ではパッチファイルを作成しない。

vendor処理はソースのchecksum検証、クリーンな展開先への順次適用、ビルド、テスト、
隔離prefixへのインストールを行う。適用失敗を無視した継続や未修正版への自動切替はしない。
再実行時に同じソースへ二重適用せず、入力の一致する成果物だけを再利用する。
cache keyにはベースSHA、パッチ列のhash、platform、主要ビルド設定を含める。

Ruby拡張のビルドではmdta APIのコンパイル・リンクを確認する。未修正版TagLibが指定された
場合は明示的なエラーにする。source gemにはパッチと必要なビルド資材を収録し、native gemは
配布形態に応じたライブラリの同梱・リンク設定を行い、隔離環境でロードと保存を検証する。
上流採用後は同じ回帰テストを通してから固定ソースを更新し、不要になったパッチを除く。

初期のsource gemは専用TagLibを事前ビルドし、`TAGLIB_DIR`指定を必須とする。
gem install時の自動取得・ビルドは行わない。パッチの収録だけで自動ビルドされるとは扱わない。

## 参照

- [TagLib mp4tag.cpp](https://raw.githubusercontent.com/taglib/taglib/master/taglib/mp4/mp4tag.cpp)
- [TagLib mp4itemfactory.cpp](https://raw.githubusercontent.com/taglib/taglib/master/taglib/mp4/mp4itemfactory.cpp)
- [TagLib mp4atom.cpp](https://raw.githubusercontent.com/taglib/taglib/master/taglib/mp4/mp4atom.cpp)
- [TagLib mp4file.cpp](https://raw.githubusercontent.com/taglib/taglib/master/taglib/mp4/mp4file.cpp)

参照先masterは可変。実装開始時に固定SHAへ置き換える。

## 簡易C++検証と設計見直し

`test/mp4_mdta_direct_baseline.cpp`は入力fixtureをコピーしてからTagLib C++ APIだけで
titleを変更し、save後に同じファイルを再openする。現在のTagLib 2.3.2では次を確認する。

```text
before_title=
before_has_normal_title=false
save=true
after_title=Changed via direct C++
```

保存後のatomには`©nam`が残り、TagLibで再openした通常`title`も読める。一方、独立した
atom probeではmdta数値itemが消えている。この結果から、修正の最小責務は通常itemの
保存ではなく、Tagの内部で通常itemとmdta documentを別モデルとして読み込み、同じsave
計画から両方を出力することと確定した。修正版ではこのbaselineを、title変更後のmdta
全entry保持をassertするC++回帰テストへ置き換える。

このプログラムで検証できないものは、未知型payload、複数meta、chapter、artwork、
原子的renameである。それらはatom probe、TagLib回帰テスト、Ruby統合テストへ分ける。

## 2026-09-20 レビュー指摘の検証

`test/mp4_mdta_design_contract_test.rb`と`test/mp4_mdta_io_fault_probe.cpp`で、未修正版
TagLibと現行Ruby binding、OSのファイル操作を検証した。5 tests / 30 assertions成功。

| 指摘 | 実行した検証 | 結果と設計への反映 |
|---|---|---|
| C++成功判定 | close後のtitle検査、違うtitleと無効MP4の拒否 | 期待値不一致を非ゼロ終了へ変更 |
| I/O失敗 | FileStreamの書込み系を捨てる派生クラス | save成功でも元bytes不変。エラー報告を必須化 |
| メディア破損 | mdat payloadの1 byte反転 | TagLibとatom検査は通過、payload hash比較は不一致 |
| Map直接編集 | 実Ruby bindingでerase/insert/clear | Tag getterへ即反映。保存前snapshot差分を採用 |
| rename後失敗 | 実rename直後に再open失敗を注入 | パスは新内容、旧FDは旧内容。旧FD close後のreadは拒否 |

最後の実験はOSハンドルの寿命を確かめるもの。将来のSWIG無効化実装を検証したものではない。
Map実験も現行経路の確認であり、実装前は`isModified`や`copyStateTo`の正しさを証明しない。
破損注入は一時fixture限定。原本のSHA-256不変も確認した。

再現手順（成果物は一時ディレクトリ）:

```sh
probe_dir=$(mktemp -d /tmp/mdta-contract.XXXXXX)
clang++ -std=c++17 -Wall -Wextra -I/opt/homebrew/opt/taglib/include \
  test/mp4_mdta_direct_baseline.cpp -L/opt/homebrew/opt/taglib/lib -ltag -o "$probe_dir/baseline"
clang++ -std=c++17 -Wall -Wextra -I/opt/homebrew/opt/taglib/include \
  test/mp4_mdta_io_fault_probe.cpp -L/opt/homebrew/opt/taglib/lib -ltag -o "$probe_dir/io-fault"
MDTA_BASELINE="$probe_dir/baseline" MDTA_IO_FAULT="$probe_dir/io-fault" \
  ruby test/mp4_mdta_design_contract_test.rb
```

実行にはこのcheckoutのRuby base/MP4拡張と開発用FFmpegが必要。製品への依存追加はしない。
この設計検証は未修正版TagLibに対するbaselineであり、TagLibパッチ、snapshot比較、
SWIGの`copyStateTo`接続後の受入試験とは分ける。第一実装ではTagLibパッチ、snapshot比較、
一時保存、再open、mdat hash、`save_chapters`拒否を実ファイルfixtureで検証済みである。
IOStreamには`hasError()`／`File::ioError()`を追加し、短いwrite、seek、truncate、flushの
失敗をTagLibのsave結果へ反映した。Rubyのchapter専用保存では元の全mdat payloadを出力側の
mdat列中に順序を保って検証し、chapter用mdatの追加だけを許可する。sample table単位での
track分類が必要な入力は、現時点ではmdat列検証を越えて成功扱いにしない。
