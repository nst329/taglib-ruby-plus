# TagLib上流向けMP4 mdta保持・複数値API設計

- 日付: 2026-10-08
- 状態: 実装方針を確定。隔離native試作で主要機能を確認済み。提案パッチを隔離実装・検証済み。本体への取り込みは未実施。
- 設計基準: TagLib 2.3.2、commit `deadc2990767dfbda0701e0ab35fdeea653db08f`。
- masterの確認: `mp4tag.cpp`の取得結果にmdta処理・専用APIはなかった。同ファイルの確認時点の最終変更は `fd97c86bcb924bd23e4c99bd25ffdf85f3a162b8`。これはリポジトリ全体のHEADを示すものではない。

## 1. 目的と境界

MP4の通常タグを保存するときに既存mdtaを失わないこと、および一つのmdtaキーの全値を型・locale・バイナリ・順序・重複を保持して置換できることをTagLib本体の責務として設計する。

本設計は将来の本体取り込みを想定するが、今回の成果物は設計書・ADR、単独の提案パッチと隔離した検証コードである。TagLib C++本体のソースツリー、上流、インストール済みnativeへ適用しない。Ruby bindingは実装・結合検証対象であり、提案ライブラリを一時コピーでビルドして接続した。以下はnative公開APIで、Rubyでは既存のmdta_items/replace_mdta_itemsからadapterを通して利用する。

非対応構造を変更前に明示的に拒否する方針は利用者と合意済み。対応範囲を広げるための推測的な解析や、部分的に読めた値だけを使う復元は行わない。

上流向けの初期範囲は単一の編集可能なmdta metaに限定する。mdirのみのファイルへmdta metaを新設すること、複数metaを公開IDで編集すること、track-level metadata、汎用atom編集APIは別の拡張とする。初期範囲はローカル実装の利用要件を満たす構造と一致させる。

## 2. 実現性と完成条件

基準のTagLibは通常ItemMapからilstを再生成し、keys tableを参照するmdtaモデルを持たない。既存の単一値setterを値ごとに呼ぶ方法では前の値を上書きする。一括置換を内部の順序付き値列として実装する必要がある。

隔離した提案実装では19テスト、40ケース・369アサーションを確認した。値の完全一致、新規キー、同じFileでの連続保存、通常タグ・画像・字幕・チャプターの保持、非対応構造の拒否を確認し、初期範囲の実現方法は成立している。以前の試作で再現した書き込み破棄は、提案実装の再読込照合でfalseを返すことを確認した。ただし、一般IOStreamの全障害や永続化成功の保証ではない。

| 区分 | 結論・残作業 |
| --- | --- |
| 機能の実現性 | 一括置換・読み取り・構造拒否は試作で確認済み |
| 保存状態の確定 | 全metadata/chapter保存と照合後に確定。後段chapter失敗では編集を保持しFileを無効化。テスト済み |
| 長さの事前検証 | keys/item/ilst/metaと親サイズ・ファイル長・chunk offsetを検証。chapterは保守的な増分上限で検証。4GiB超のmetadata保存とQT offset拒否も確認済み |
| 通常APIの網羅 | 主なタグ・strip・ItemMapのinsert/erase/clearを確認済み。全未知atomの位置・順序は網羅済みとは扱わない |
| ABI | 原始公開ヘッダーでコンパイルした既存API/custom IOStreamクライアントを新ライブラリで実行し主要classサイズ一致を確認。正式な全ABI検証は将来の取り込み時に必要 |
| Ruby binding | grouped/legacy adapterとbinding用状態移送を実装済み。両backendのmdta対象30テスト、Minitest12件が成功 |
| 一般IOStream | 全I/O失敗の検出は現行契約では保証不能。独立設計とする |
| 上流取り込み | 将来の検討対象。基準HEAD、公開名、ABI方針、リリース番号は取り込み時に再確認 |

[隔離実装の結果と再現手順](Memos/2026-10-08-mdta上流向け隔離実装の検証.md)を現在の検証証拠とする。[先行試作](Memos/2026-10-08-mdta上流設計のnative試作検証.md)は原因検証の履歴として残す。ローカルRuby版の成功と、上流向け実装の完成判定は分ける。

## 3. 公開API案

`MP4::Item`は通常iTunes metadata向けに維持する。mdtaの値をStringListや既存AtomDataType enumへ変換しない。data atom先頭の32-bit型フィールドを全ビット保持し、localeも32-bit、payloadはByteVectorとして扱う。

### 公開型の責務

| 型 | 責務 |
| --- | --- |
| `MdtaValue` | 型フィールド、locale、payloadの一値。key/indexを持たない |
| `MdtaValueList` | 一キーの値の順序と重複を保持する `List<MdtaValue>` |
| `MdtaItem` | 読み取り用のキー名・現在のkeys index・全値のsnapshot |
| `MdtaItemList` | 読み取り用のキー一覧。keys tableの順で返す |
| `MdtaStatus` | mdtaの不在・編集可能・非対応を区別する |

公開クラスはTagLibのItem/CoverArtに合わせ、`TAGLIB_EXPORT`とPrivate実装へのポインタを用いる。公開フィールドを増やす方式は採用しない。標準のコピー、代入、swap、破棄、等値比較を定義する。取得するByteVector/Listは値として返し、利用者の変更がTag内部へ伝播しないようにする。

主要宣言の概略。コピー・破棄などの定型宣言は省略している。

```cpp
namespace TagLib::MP4 {
  // A single typed mdta payload; independent of keys table identity.
  class TAGLIB_EXPORT MdtaValue {
  public:
    MdtaValue(unsigned int dataType, unsigned int locale, const ByteVector &data);
    unsigned int dataType() const;
    unsigned int locale() const;
    ByteVector data() const;
    bool operator==(const MdtaValue &other) const;
  private:
    class MdtaValuePrivate;
    std::shared_ptr<MdtaValuePrivate> d;
  };

  // Ordered values for one key; duplicates and empty payloads are meaningful.
  using MdtaValueList = List<MdtaValue>;

  // A read snapshot; the keys table index is observable but cannot be assigned to Tag.
  class TAGLIB_EXPORT MdtaItem {
  public:
    MdtaItem(const String &key, unsigned int keyIndex, const MdtaValueList &values);
    String key() const;
    unsigned int keyIndex() const;
    MdtaValueList values() const;
  private:
    class MdtaItemPrivate;
    std::shared_ptr<MdtaItemPrivate> d;
  };

  // Keys table order, including valid keys that currently have no values.
  using MdtaItemList = List<MdtaItem>;

  enum class MdtaStatus {
    Absent,
    Editable,
    Unsupported
  };
}

// Non-virtual additions to MP4::Tag; no change to the existing virtual table.
MdtaStatus mdtaStatus() const;
MdtaItemList mdtaItems() const;
bool replaceMdtaItems(const String &key, const MdtaValueList &values);
bool removeMdtaItem(const String &key);
```

`MdtaItem`を利用者が生成しても、setterはMdtaValueListしか受け取らないためindexの改変はできない。StringとListの比較による暗黙の整列、重複排除は行わない。

### 使用例

```cpp
using namespace TagLib;
MP4::File file("temporary-copy.mp4", false);
if(!file.isValid() || file.tag()->mdtaStatus() != MP4::MdtaStatus::Editable)
  return false;

MP4::MdtaValueList values;
values.append(MP4::MdtaValue(1, 0, ByteVector("first", 5)));
values.append(MP4::MdtaValue(1, 1041, ByteVector("second", 6)));
values.append(MP4::MdtaValue(1, 0, ByteVector("first", 5)));
values.append(MP4::MdtaValue(33, 7, ByteVector("\0\xff", 2)));
values.append(MP4::MdtaValue(1, 0, ByteVector()));
if(!file.tag()->replaceMdtaItems("com.example.restore", values))
  return false;
return file.save();
```

この例は一時コピーの保存を示す。native `save()`のboolだけで原本保護や永続化を保証するものではない。

### 読み取りとエラー契約

- `Absent`: 対象スコープにmdtaがない。`mdtaItems()`は空。通常のmdirのAPIは従来どおり動作する。
- `Editable`: 初期範囲で完全に解析でき、編集可能。`mdtaItems()`は独立snapshotを返す。値がない有効なキーも空のvalues付きで返す。
- `Unsupported`: mdtaがあるが初期範囲外または構造が不正。`mdtaItems()`は空を返し、部分的に解析した一覧を完全な退避データとして公開しない。元bytesは内部保持する。
- `replaceMdtaItems`: 入力不正、非対応、不在の場合はfalse。全入力と構造を検証してから変更し、失敗時はTagの全編集状態が不変。
- `removeMdtaItem`: Editableの場合、キー不在は成功するno-op。Absent/Unsupportedの場合はfalse。値のないkeys entryも削除できる。
- 空の値配列は置換で拒否する。空payloadは有効。削除には専用APIを使う。
- 失敗条件はDoxygenに記載し、実際の拒否理由は既存debug経路に出力する。新しい汎用例外階層やTag全体のlastError状態は追加しない。

mdtaがないことと、非対応構造で一覧を返せないことは `mdtaStatus()` で必ず区別できる。退避する利用者は状態を確認してから一覧を読む。

## 4. 入力検証と一括置換

キーは非空のString、UTF-8出力にNULがないことを要求する。入力ファイルのキーbytesはUnicode変換前に検査し、UTF-8が不正またはStringへ変換・再出力するとbytesが変わる場合はUnsupportedとする。namespaceは初期範囲で `mdta` のみ。

values全体を検証し、個々のdata atom長、numeric item長、keys atom長、metaの増分、indexの割当を桁あふれなしで計算する。長さ計算は広い整数型を使い、出力形式の範囲外なら変更前にfalseを返す。符号なし32-bitの型・localeは未知の値も許可し、既知型の解釈を置換条件にしない。

処理順序:

1. mdtaStatusと入力全体を検証する。
2. 編集モデルの候補コピーを作る。
3. キーがあればそのkeys indexを使い、なければkeys末尾に一度だけ追加する。
4. 指定キーの全値を入力の順で置換し、変更キーを記録する。
5. 候補の整合性を検査し、成功時だけTagPrivateへswapする。

入力不正と構造不正はboolで返す。標準のメモリ確保失敗を成功扱いにしたり、途中までの更新をコミットしたりしない。確保失敗時もswap前の元状態を残す。メモリ確保失敗をboolへ一律変換するかはTagLibの例外方針に従う。

既存キーのindexは置換で変わらない。新規キーのindexは出力ファイルのkeys末尾であり、退避元のindexを指定・復元する機能ではない。removeは残りのkeysとnumeric参照を同じ候補内で再採番する。再採番できないopaqueなnumeric参照がある場合は削除も拒否する。

繰り返し同じ値配列を設定しても値数は増えない。単一値の設定も一要素のMdtaValueListで行えるため、上流の初期APIには別の `setMdtaItem` を追加しない。ローカルの既存単一値setterはadapterで維持する。

## 5. 内部モデルと保持

公開snapshotと保存の正本を分ける。新しい汎用writerや編集フレームワークは作らず、既存TagPrivate/FilePrivateへ以下の責務を配置する。表中の名称は内部の役割であり、独立した公開classを追加する指定ではない。

| 内部の役割 | 所有・責務 | 持たせない責務 |
| --- | --- | --- |
| 構造判定 | Tag読込時に全関連metaを調べ、状態と一意な保存先を確定 | 曖昧な構造の救済・書き込み |
| `MdtaState` | TagPrivateがkeys、順序付きitem、raw、変更キーを所有 | I/O・公開Atomポインタ |
| 候補編集 | Stateコピーを全体検証してswap | ディスク更新 |
| 保存計画 | 通常itemとmdtaを合成し、長さ・参照・書込対象を確定 | 書込中の構造解決 |
| File保存調整 | metadata→tree更新→chapter→tree更新→状態確定 | setterの値変換 |
| Ruby保存境界 | 一時コピー・独立照合・原本置換 | nativeの部分書込の巻き戻し |

編集状態の正本と、最後に成功した保存状態を区別する。treeを更新する処理はAtom参照を更新するだけで、未保存変更の解除を兼ねない。これにより途中のchapter失敗で変更を保存済み扱いにしない。

Tagと公開ItemMapオブジェクトの同一性は維持する。内部Atom参照は再構築後に全て再接続し、旧treeへのポインタを残さない。ByteVector/Listを含む公開snapshotは独立した値である。

- keysにはnamespace、元のキーbytes、1-based indexを保持する。
- numeric itemには元位置、参照index、順序付きdata子atom、元bytesを保持する。
- 同じindexの複数itemと、一item内の複数dataは、公開valuesに出現順で連結する。
- 公開一覧はkeys table順。全キーを跨ぐdataの並び順は公開一覧から復元できるとは保証しない。
- 未変更numeric itemは元bytesを再利用し、元の親グループと順序を保つ。
- 変更したキーは最初のnumeric itemの位置へ全値をまとめた一itemを出力し、同じキーの残りのitemを除く。新規キーはilst末尾に出力する。
- 変更後のdata子atomは入力順。型・locale・payload・重複・値数の一致を保証する。変更対象の元atomグループ分けやpaddingのbytes一致は保証しない。
- 通常iTunes item、freeform、画像、未知の非numeric itemは通常モデルまたはopaque bytesで保持する。知らないatomを黙って捨てない。

handler欠落時もkeysの存在をmdta構造の証拠として扱い、Absentへ落とさない。混在ilstのnumeric判定はhandler、keys index、既知通常item名を使う。ItemFactoryは未知fourCCも文字列として受理するため、isValidだけでは判定せず既知handler/property登録を確認する。先頭byteが0であることだけを判定基準にしない。既知通常itemでなく、数値参照か未知fourccかを安全に区別できない子atomがある場合はUnsupportedにする。将来この判定を広げる際はfixtureを追加する。

## 6. 初期対応範囲

| 構造 | 読み取り状態 | 編集・metadata保存 |
| --- | --- | --- |
| mdtaなし、通常mdirのみ | Absent | 通常API維持。mdtaの新設はfalse |
| 単一の有効な `moov/udta/meta`、mdta、keys、ilst | Editable | 対応 |
| 上記ilst内の通常iTunesタグとの混在 | Editable | 両方を保持して対応 |
| 同じキーの複数data・複数numeric item | Editable | 順序・重複を保持 |
| keys countが0、空のilst | Editable | 新規キー・値を追加可能 |
| 有効なkeys entryに値がない | Editable | indexを保って値を設定可能 |
| 別metaにmdir/mdta併存、複数mdta、複数udta | Unsupported | 初期版はmetadata保存を拒否 |
| keys/ilst/hdlrの欠落・重複、壊れた参照・境界 | Unsupported | metadata保存を拒否 |
| 重複キー名、不正UTF-8、異なるkey namespace | Unsupported | metadata保存を拒否 |
| numeric itemの未知の子atom、曖昧なilst child | Unsupported | metadata保存を拒否 |
| moov直下・track内のmdtaのみ | Unsupported | metadata保存を拒否 |
| 64-bit atom、非FullBox meta、断片化など未検証レイアウト | Unsupported | 初期版はmetadata保存を拒否 |

パーサーがmdtaを検出したのに編集対象として完全に扱えない場合、`save()`は書き込み前にfalseを返す。通常タグだけの変更でもmdtaを落とす保存は許可しない。この変更は「以前はsave成功でも情報が失われたファイルが、今後は明示的に失敗する」という互換性上の影響を伴う。

非対応構造のraw保持は、ファイルを安全に再保存できる保証ではない。初期版では安全な更新計画を作れない状態を保存成功にしない。通常 `MP4::File::save()` はTag保存から始まるため、この状態では後続のchapter保存にも進まない。chapterだけなら保存可能、と暗黙には約束しない。

STEM編集の併用は初期提案の対象外として保存前に拒否する。metadata祖先/関連treeのextended-size atomも保存前に拒否する。

32-bit長の通常FullBox metaを最初の受入範囲とする。atom header長やFullBoxの有無は実構造から判断し、誤った固定offsetで読み取らない。読めない形式を「mdtaなし」と扱わない。非対応検出のための列挙は `moov/udta` 以外のmetaも含めるが、編集スコープは拡張しない。

## 7. 保存フローと失敗時の状態

既存のItemFactory、padding、親サイズ・chunk offset更新を再利用する。File側の一つの調整処理がmetadataとchapterの順序を管理し、tree更新と編集状態の確定を別の処理にする。

### 書き込み前

1. Unsupportedなら即座に拒否する。通常タグだけの変更やchapter保存でも迂回しない。
2. 通常ItemMapの直接操作を含め、現在の編集状態から保存計画を作る。
3. keys/ilst、残存meta child、全親サイズ、ファイル長、chunk offsetを桁あふれなしで計算する。計算できない構造とstco→co64昇格が必要な変更は拒否する。chapterの増分は既存writerの固定box overheadを上回る1MiBと、QT値一件あたり512 bytes＋UTF-8 title長×4の上限で見積もる。Neroの255件/255 bytes、QT titleの65535 bytes、時刻の表現条件を事前検証する。上限による保守的な拒否を許容する。
4. 一意な保存先と出力bytesを確定する。書き込み中にfindで別のmetaを再探索しない。

mdtaはkeys変更の有無にかかわらずmeta全体を一つの更新計画として扱う。keysとilstを旧offsetに基づいて別々に書き換えない。paddingの吸収を行わず、正確な増分を既存の親サイズ・offset更新へ渡す。拒否は最初の書き込みより前に行い、編集状態とディスクを保持する。

### 書き込み開始後

1. 計画したmetadataを保存する。
2. atom treeを再構築し、同じTag/ItemMapを維持して内部参照だけを再接続する。未保存変更はまだ解除しない。
3. 更新済みtreeでchapterを保存する。
4. treeを再構築し、metadataとchapterの再読込結果を予定した保存状態と照合する。
5. 呼出し全体が成功した場合だけ、最後に成功したsnapshotを更新し、変更記録を解除する。

公開Tag::saveだけの呼出しはmetadataを責務範囲とする。File::saveから呼ぶ内部処理は確定を延期し、File側がchapterまで成功したときに一度だけ確定する。別の公開transaction APIは追加しない。

### 状態の契約

| 結果 | 編集状態 | Fileの再利用 | ディスク |
| --- | --- | --- | --- |
| 入力・構造・長さの事前拒否 | 保持 | 可能 | 不変 |
| 全保存と照合成功 | 新snapshotへ確定 | 同じFileで連続保存可能 | 保存結果 |
| 書込開始後の検出可能な失敗・再読込不一致 | 成功snapshotへ確定しない | 無効化し再openを要求 | 部分更新の可能性あり |
| IOStreamが報告しない障害 | 完全検出の保証なし | 成功判定を信頼する保証なし | 第8節の保存境界で保護 |

同じFileでの連続3回保存、metadata→chapter、chapter→metadataの双方を受入条件とする。毎回Fileを開き直す検証で代用しない。co64への自動昇格とnativeディスク更新の巻き戻しは初期実装に含めない。

## 8. I/O失敗とABI

上流基準の `IOStream` はwrite/insert/remove/truncateの成否を返さず、今回のローカルパッチにある `hasError()` は上流APIではない。virtualメソッドの追加は既存のカスタムIOStreamとvtableの互換性評価が必要なため、mdtaパッチへ混ぜない。

初期mdta APIが保証する原子性は、setterによるメモリ上のキー単位の変更と、構造・長さ不正をディスク変更前に拒否すること。nativeのin-place保存中に発生するI/O障害、flush/close失敗、電源断に対する原本保護は保証しない。

I/Oエラーを確実に返す上流APIがない状態で、一般のIOStreamに対して「すべての保存失敗を検出できる」とは記述しない。I/O機能の拡張は独立の設計・パッチとして、ABI方針とカスタムstreamの契約を承認するまで保留する。保存失敗の検証も、事前拒否と書き込み中のI/O障害を別の結果として扱う。

再読込でmetadataとchapterの予定値を照合し、検出可能な書込不一致をfalseにする。flush/closeや耐久性の証明には使わない。

MListNewの原本保護は既存Ruby側の一時コピー・独立再読込・metadata/メディア比較・renameで維持する。上流APIへ接続してもこの保存境界を取り除かない。

追加するTagメソッドは非virtual、内部状態は既存TagPrivateへ追加する。公開値クラスはPrivateポインタでレイアウトを固定する。これはABIを守るための方針であり、ABI互換性の証明ではない。実装時には共有ライブラリのsymbolとclass/vtable変更をツールで比較し、上流方針に従って確認する。

## 9. 通常API・strip・プロパティ

- ItemMapへnumeric mdtaを混ぜない。既存通常itemの公開型とキーを変えない。
- title/artist等のmdta fallback、PropertyMap正規化、通常setterによるmdta同期は初期提案へ含めない。
- `removeUnsupportedProperties()`からmdtaのキーや値を削除しない。
- `isEmpty()`は通常itemまたはmdtaの値があればfalse。空payload一値も値として数える。値のないkeys entryだけならtrue。
- 不明なmetadataがあるUnsupported状態では、保守的に `isEmpty()` はfalseとする。
- `Tag::strip()`は編集可能な対象ilst内の通常itemとmdta値を全て除く。keys entryは残してよい。呼出後の `isEmpty()` はtrueとなり、保存後も値は復活しない。
- `File::strip()`の既存meta削除との関係を既存テストで固定する。未知のscopeまで削除範囲を広げない。Unsupported構造のTag::stripは初期版では事前拒否する。

## 10. ローカル実装との差分と移行

| 現在のローカルAPI/処理 | 上流向け案 |
| --- | --- |
| scalarの公開struct MdtaItemにkey/index/type/locale/data | MdtaValueとキー単位snapshotのMdtaItemへ分離 |
| setterが値内のkey/indexを無視する | 値型にkey/indexを持たせない |
| `setMdtaItem`と`replaceMdtaItems`を両方公開 | 上流は一括置換だけ。単一値は一要素リスト |
| 最初のmeta探索を前提に非対応を拒否 | 読込時にスコープを分類し、保存先を実体で固定 |
| Ruby専用の `copyStateTo` / `applyChanges` | 初期上流提案には含めない |
| mdtaによる通常プロパティfallback | 独立の提案へ分ける |
| IOStream `hasError()` / File `ioError()` | 独立のABI設計へ分ける |

Rubyの `replace_mdta_items` と既存 `set_mdta_item` の公開契約は変えない。adapterでHashからMdtaValueListへ変換し、キー単位snapshotを現在のflatなRuby MdtaItem列へ展開する。

現在の安全な一時保存は `copyStateTo` に依存するため、0001単独を既存bindingへリンクしない。実装済みの [binding用0002](../patches/taglib/proposals/0002-ruby-mdta-state-transfer.patch)を別管理する。extconfが両レイアウトと状態移送APIをリンク検査し、共通adapterを選択する。未知atomや削除状態を公開一覧だけで再構成しない。

Rubyのmdta_statusはgrouped版で三状態を返し、legacy版はunknownとする。title/artist fallbackはRubyで従来互換を維持する。実装・結合検証は [記録](Memos/2026-10-08-mdtaのRubyBinding結合検証.md) と [ADR](ADR/2026-10-08-mdtaのRubyBinding接続.md) を参照する。

上流の必要バージョンは未定。現在のローカル実装の必要バージョン **taglib-ruby-plus 2.3.2.7＋同改訂のTagLibパッチ** とは区別する。

## 11. 提案用パッチの分割案

実装成果物は [単独の提案パッチ](../patches/taglib/proposals/0001-mp4-mdta-api.patch)。基準の原始ソースに対して、隔離コピーでのみ適用・ビルドした。既存Ruby版パッチの代替として自動適用しない。将来の上流レビューでは以下の単位に分割できる。

| 順 | 内容 | レビューの目的 |
| --- | --- | --- |
| 1 | mdta fixture、通常title保存でmdtaが消える回帰テスト | 現象と期待する保持契約を固定 |
| 2 | 内部mdta保持モデル、構造分類、既存保存への接続 | 通常APIでの損失を防ぐ |
| 3 | MdtaValue/MdtaItem/statusと一括置換・削除API | 公開型と編集契約を確認 |
| 4 | 保存後tree再構築と連続保存・chapter互換テスト | 同じFileの寿命内での整合性を確認 |

公開APIを追加する段階で保存後の整合性が必要になるため、2〜4を統合した受入検証を通すまで配布可能とは扱わない。テストだけの変更は単独の完成修正とせず、レビュー用の問題再現として位置付ける。

IOStreamエラー報告、mdta→通常プロパティ連携、複数meta編集、mdir-onlyへの新設、汎用atom公開はこの列から分離する。

## 12. 受入テスト計画

上流のC++テストへ小さな合成fixtureを追加する。FFmpegはfixture作成時だけ用い、通常の上流テスト実行時には依存させない。fixture生成手順と由来を記録し、原本動画を変更しない。

| 対象 | 必須確認 |
| --- | --- |
| 値の完全性 | 同じ/異なるlocale、重複、複数型、未知32-bit型、NUL、空payload、全値の順序 |
| 入力と原子性 | 空配列、不正キー、後半の不正値/長さoverflowで全状態不変 |
| keys | 既存index維持、新規キー、値なしkey、空keys table、削除後の全参照整合性 |
| 元の表現 | 複数data子、繰り返すnumeric item、未編集itemのraw一致 |
| 通常API | title・artist・freeform・artwork、ItemMap直接insert/erase/clear、strip/isEmpty |
| メディア | 動画・音声・字幕のtrack情報、sample/packet bytes、offsetが指す位置の一致 |
| chapter | Nero/QuickTime、双方併存、mdta保存後のchapter保存、chapter保存後のmdta更新 |
| 保存寿命 | 同じFileで3回の設定/save、別Fileへ再読込、値数が増えないこと |
| 構造 | mdir-only、混在ilst、別meta併存の両順序、複数mdta/udta、誤index、不正境界 |
| 非対応形式 | 異namespace、不正UTF-8、重複キー、未知numeric child、64-bit/非FullBox/断片化の事前拒否 |
| 失敗 | 読取専用、無効File、構造/overflowの事前拒否でstream内容不変 |
| I/O別設計 | 書き込み破棄、途中write/insert/truncate失敗、flush/close失敗。保証可能になるまで未達として明記 |
| ABI | 既存公開class/vtableの比較、追加symbol、既存クライアント・カスタムIOStreamのロード |

再読込後に `(key, keyIndex, value count, dataType, locale, data bytes, value order)` を比較する。独立atom parserでもkeysとnumeric参照を検査し、TagLib同士だけの一致でwriter/parser共通の誤りを見逃さない。失敗テストは変更前の編集状態とディスクbytesの両方を比較する。

試作済み範囲と未達事項は第2節を正本とする。同じnative Fileでの連続保存と全保存後の状態確定は実装・テスト済み。ABIは互換クライアントの限定した確認を行った。既存SWIG追跡数テストの既知失敗は上流C++設計の成否へ混同しない。

完成実装の受入では、追加していない処理まで試作結果から推定しない。chapter保存の後段失敗、長さ事前拒否、ItemMap直接操作、既存APIの互換クライアントを確認した。正式取り込み前には全ABI検証と追加構造の回帰確認が必要。一般IOStreamの全障害検出は初期完成条件へ混ぜず、制約の公開とRuby保存境界の検証を必須とする。

## 13. 参照

- [TagLib 2.3.2基準commit](https://github.com/taglib/taglib/tree/deadc2990767dfbda0701e0ab35fdeea653db08f)
- [基準のMP4 Tag実装](https://github.com/taglib/taglib/blob/deadc2990767dfbda0701e0ab35fdeea653db08f/taglib/mp4/mp4tag.cpp)
- [基準のIOStream](https://github.com/taglib/taglib/blob/deadc2990767dfbda0701e0ab35fdeea653db08f/taglib/toolkit/tiostream.h)
- [汎用MP4 atomアクセスの要望 #1245](https://github.com/taglib/taglib/issues/1245)。今回のAPIはこの要望の実装ではない。
- [ローカル一括置換の実装設計](mp4-mdta-replace-design.md)
- [上流向け設計のADR](ADR/2026-10-08-mdta上流向け公開API設計.md)
