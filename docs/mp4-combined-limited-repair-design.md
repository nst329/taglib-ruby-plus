# QuickTime chapter限定削除と不正mdta index限定除去の併用設計

日付: 2026-10-20
状態: 実装済み。対象versionは2.3.2.38。

## 複数metadata contextへの拡張設計（2026-10-21、実装済み）

本節は設計probeの結果に基づく追加実装の記録である。公開APIの形は維持し、既存の限定修復経路へ安全なpair判定を統合した。

### 設計probeで確認したこと

`test/probes/mp4_metadata_context_pair_design.rb`をRuby 4.0.7、ローカルnative binding、FFmpegで実行し、5 tests / 45 assertions / 0 failures / 0 errorsを確認した。fixtureはFFmpeg生成AAC MP4へ、公開APIでNero chapterを追加し、独立fixture parserでcontextを注入したもの。

- 同一udtaの正常mdir→mdtaは公開metadata診断がcompleteでissuesなし、限定修復計画もunchangedになる。
- 別udtaへ分散したpairは親の絶対座標で区別され、multiple_metaとしてblockedになる。
- 正常mdta→mdirもraw保持を前提にcompleteと判定し、native側のunrepresented_itemだけでは拒否しない。
- meta直下の未知子atomはunsupported_childとして検出され、pairを成功扱いしない。
- 3 context、mdir+mdir、mdta+mdta、未知handlerはmultiple_metaまたは既存の構造理由でblockedになる。
- 両順序について、コピー上でindex 0だけを独立fixture editorで除去できた。期待するmoov全体のraw一致、mdir・mdtaのkeys/handler/free/対象外item・順序・track・Nero保持、mdat一致、原本不変、独立再openとFFmpeg decode成功を確認した。このfixtureではmoovがmdatより後にあり、chunk offsetの移動補正そのものの証明ではない。

このprobeは構造境界と保存保持の受入試験として実行する。独立候補編集だけでなく、公開apply/save経路のpair試験も追加した。

### 決定する内部構成と安全境界

汎用性は許可件数を増やすことではなく、context収集・検証・修復対象選択を分離することで確保する。ルール登録frameworkは導入しない。既存reader/editorが取得したatom記述を受け取る小さな共通検証器を置き、検証器自身はI/Oしない。

contextの内部記述には、原本世代、metaの開始/終了、親udtaの開始/終了、所属moovの開始/終了、兄弟順序、handler、子atom記述を持たせる。例として同じpathを持ってもudta開始位置が異なれば別親とする。内部情報の追加を公開issues/location/detailsの変更へ直結させない。

単一contextは既存契約を維持する。複数は正確に2個、handlerがmdirとmdtaで各1個、同一moov直下の同一udtaの直接の子である場合だけ次の個別検証へ進む。両順序を許可する。

- metaの通常header、FullBox、境界、hdlrの件数・長さ・flagsを検証する。
- mdirはhdlr/ilst/freeだけを許可し、既存の通常item構造検証を行う。未知・未保持の子や複数ilstは拒否する。
- mdtaはhdlr/keys/ilstが各1個、追加子はfreeのみとし、keys件数・namespace・文字列・重複と保持item構造を検証する。
- mdta_layoutの既存解釈を維持する。pairだからindexedとは推測しない。確定したindexの0またはkeys件数超過だけを除去可能とし、解釈不能・keys破損などは拒否する。
- 3個以上、同種pair、別udta、未知handler/子atom、境界や親が不明な入力はblocked。集合の拒否はmultiple_meta、個別の拒否は既存の適切な理由を使用する。

### 診断とsnapshot能力の分離

安全なpairの構造診断は両順序ともcomplete/issuesなし、正常計画はunchanged、除去可能な不正indexのみならrepairableとする。metadata reasonはmetadata_complete/invalid_indexを維持する。不正indexが残る入力の診断までcompleteにはしない。

native ItemMapに見えないこととrawで安全に保持できないことを同一視しない。pair時のmdirも共通のraw構造検証で直接検証し、native entriesの不足だけでunrepresented_itemを作らない設計にする。ただしissueを一括除外するfallbackは不可とし、値構造を検証できないitemは失敗させる。snapshot取得・完全復元の既存安全gateは緩和しない。構造診断がcompleteになったことだけを根拠に、nativeが取得できない後続mdir値を欠落snapshotとして返してはならない。この境界は製品化時の追加必須試験とする。

### 保存とI/O

mdirはraw保持対象、mdtaだけを編集対象とする。既存のoffset指定raw置換でmdtaのilstだけを再構成し、handler/keys/freeと対象外itemをそのまま使う。contextの統合・削除・再配置やnative setterへの変換はしない。

保存後の既存独立構造解析へ共通検証器を接続し、安全な集合であることと不正indexが残らないことを確認する。原本絶対offsetは移動し得るため候補にそのまま要求せず、候補自身の親子境界と順序・保持signatureで照合する。media/track/chapter比較、chunk補正、session ownership、世代、別出力、publication_statusは既存経路を維持する。

計画時は取得済み構造を再利用し、追加の全体scan・media読込・コピーを導入しない。保存後は共通条件を再確認するためmetadata構造readerを一度だけ呼び、root/moov/udta/metaの境界とheaderだけを走査する。mdat payloadは読まない。検証器用の記述と上限内metadata検証にCPU/メモリを使う。製品化後のI/O回数・bytesは未計測であり、今回のprobeから削減の実測を主張しない。

### 製品化時の残る受入条件

公開plan→apply→save!→独立再openでunchanged、正常pairの無変更save-as、保存後のmdir/keys/順序改変検出、複数ilst・未知子・壊れたkeys・layout曖昧性の拒否を追加する。pairでの保存失敗・世代競合・別File plan・publication_status、moov先行ファイルのchunk補正、通常snapshotの欠落拒否を確認する。

既存limited repair製品テストは20 tests / 123 assertions / 0 failures / 0 errors。pair設計probeは5 tests / 45 assertions / 0 failures / 0 errors。実際に問題となったMP4のpathは提供されておらず、実ファイルコピーは未検証。別OS・配布gem・他native backendも未検証。CHANGELOGとversionの更新はリリース作業で行い、MListNew側はこの変更に含めない。

追加probeのRuby構文チェックとgit diff --checkも成功した。plus_mp4_api_test.rbはshoulda-context不足で起動できず、Bundler経由でもrake-compiler 0.9.9、shoulda-context 2.0.0、yard 0.9.45が未導入のため起動前に停止した。公開API全般の回帰成功とは扱わない。

## 前提と対象

当初受領した必須要件は1と2までで、その後の指示により不正index全般へ拡張し、設計probe後に実装した。
「metadata修復」は意味の復元ではなく、対応先のない不正mdta index itemの明示的な破棄とする。keysの推定対応、再採番、handler変更、通常タグの正規化は行わない。
原本を読み取り、利用側が指定する未作成の別出力へ保存する。backup、最終置換、ロック、容量方針、FFmpeg、作品JSON・DBは利用側の責務とする。

## 実装前の既存機能の確認

- `TagLib::Plus::MP4::File#plan_quicktime_chapter_removal`と`remove_quicktime_chapters(plan:)`、`save!(to:)`で、metadataを完全読取できる入力のQuickTime限定削除を行える。
- `read_chapters(style: :nero)`は壊れたQuickTimeと独立してNeroを読める。
- `metadata`の完全snapshotは不正indexを拒否する。`metadata.with`や完全置換で対象外のraw情報まで保持して不正indexだけを除去する契約はない。
- `Internal::File#save_preserving_unindexed_mdta`はindex 0を保存後に戻す内部機能である。限定除去APIとして公開されておらず、今回の目的とは異なる。
- 現行Plus保存は変更時に`load_metadata`を呼び、検証でも完全metadata snapshotを比較する。修復slotは一つで、metadata編集との同時保留も拒否する。
- 既存の逐次保存案はアプリ側metadata修復を必要とし、全面コピーと検証が各段で発生する。公開APIだけでは今回の要件を満たせない。

既存のQuickTime単独APIは維持する。通常タグ編集、chapter時間修復、欠落参照解除を今回の併用へ拡張しない。

## 公開境界

追加は診断計画と登録の二操作とし、保存は既存`save!`を使う。以下は通常fourcc混在の生成規約が既知である入力を前提とした使用例である。

```ruby
TagLib::Plus::MP4.open(source) do |file|
  plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
  # plan.statusと各領域のreason_codeを先に記録する。
  if plan.status == :repairable
    file.apply_limited_repairs(
      plan: plan,
      allow: [:remove_invalid_mdta_indices, :remove_broken_quicktime_chapters]
    )
    result = file.save!(to: stage)
  end
end
```

`allow`は必須で、既知の操作名だけを受け付ける。診断には許可設定を渡さず、実際に必要な操作を確定する。許可リストは必要操作との包含関係だけを確認する。metadata許可があるだけでmetadataを書き換えたり、QuickTimeだけの修復を拒否したりしない。
必要操作の一部が未許可なら全体を拒否し、部分登録しない。`blocked`でも安全な側だけを暗黙保存しない。

計画は凍結した所有値とし、公開値は次を持つ。

- `status`: `:unchanged` / `:repairable` / `:blocked`。
- `required_operations`: 順序付き操作名。判定不能時は部分診断であることを領域statusに残し、実行可能一覧として使わない。
- `metadata`、`quicktime`: 各`status`（`:not_needed` / `:required` / `:blocked`）、`reason_code`、`issues`、除去候補。
- metadata候補: atom path、元offset、size、SHA-256、順序、件数、元index値、keys件数、不正理由（zero / out_of_range）。raw payloadは業務ログへ渡さない。
- QuickTime候補: source/target track ID、元参照位置、除去track、既存のreason code。

正常QuickTimeと不在は両方not_neededだがreasonで区別する。正常metadataとmetadata不在も区別する。読取失敗、未知構造、上限超過はblockedまたは公開Errorであり、not_neededに変換しない。共有構造が読めない場合は両領域に解析不能を残す。

| metadata | QuickTime | 全体 | 必要操作 |
|---|---|---|---|
| 不要 | 不要 | unchanged | なし |
| 必要 | 不要 | repairable | metadata除去 |
| 不要 | 必要 | repairable | QuickTime除去 |
| 必要 | 必要 | repairable | 両方 |
| blockedを含む | 任意 | blocked | 実行拒否 |

計画は同じFileインスタンスと原本世代に束縛し、最後に発行した計画だけを登録できる。古い候補を蓄積せず、保存計画のメモリ寿命を限定するためである。別インスタンス、改変、古い世代は登録前に拒否する。未保存の他編集・他修復があれば従来どおりpending_changes。未変更計画の登録はno-opとし、出力を作らない。既存`save!(to:)`を明示的に呼んだ場合の無変更コピー契約は変えない。

## metadata限定profile

不正indexの判定は、正常に解析したkeys件数Kとitemの符号なし32bit big-endian index iに対し、`i == 0 || i > K`とする。`1 <= i <= K`は正常参照として保持する。値0、先頭連続、特定のproducerに限定しない。

- 単一moov/udta/meta、通常8byte header、meta version/flags=0。
- 単一hdlr/keys/ilst、handler=mdta。子はhdlr/keys/ilst/freeだけ。
- keysは件数・境界・namespace・UTF-8・重複を検証する。既存の件数上限を継承する。keysの欠落・破損をK=0と解釈しない。正常な空keys（K=0）は数値indexすべてが不正となる。
- 不正indexはilst内の任意位置・任意件数・重複を許す。正常index、複数の不正値、既知の通常fourcc itemとの混在を扱い、元順序で不正itemだけを除去する。
- 正常indexのitemは型付き値へ変換せずraw保持する。値型がnative非対応でも、境界と参照が確定し、今回対象外として保持できれば除去しない。正常indexの重複も勝手に統合しない。
- 複数meta、未知構造、異常境界、extended/zero-size headerはこの構造profileではblocked。index値の一般化と、任意の破損構造への対応は分ける。
- 不正indexがなくても、構造解析不能をnot_neededにしない。

数値indexと通常fourccの識別は診断・計画・検証で共通化する。現行readerの「先頭byteが0ならnumeric」という判定だけでは32bit全域を扱えないため、修復設計ではこの制約を引き継がない。mdta contextの数値itemは4byte全体をindexとして検査し、既存の許可リストにある通常fourccは通常itemとして保持する。未知fourccや既知fourccと数値indexの両解釈が成立する場合は、推測で削除せず`ambiguous_item_type`でblockedとする。単に4byteを整数化できることを除去根拠にしない。今回のprobeでは、既知通常fourccを保持し、未知のASCII可視4文字を曖昧として拒否し、残りを数値として扱う試作を検証した。ただし「非ASCIIなら必ずindex」という証明にはならない。fixtureの成功だけでproducerの意図を確定してはならない。

### テスト後の見直し: 解釈profileを明示する

`zzzz`と整数`0x7a7a7a7a`、`covr`と整数`0x636f7672`は同じbytesであり、keys範囲外という事実だけでは「通常itemか不正indexか」は決まらない。従来案の「文脈から自動的に32bit全域を識別する」は撤回する。

計画の`mdta_layout:`で次を区別する。

- `:indexed`: 呼出側がmdtaのilstを数値index表として扱うことを明示する。全item名を32bit indexとして判定し、0またはK超過を位置によらず除去する。既知fourccに見える値も例外にしない。gemはkeys・境界・保持・offsetの安全性を検証し、この明示を値の意味復元の証拠にはしない。
- `:mixed_known_fourcc`: 呼出側が既存通常itemとの混在規約を明示する。既知通常fourccを予約してraw保持し、その他を数値として判定する。未知fourccを含まないことがこのprofileの適用条件である。
- 未指定: 既存の数値／fourcc識別を超える解釈が必要なら`ambiguous_item_type`でblockedにし、profileを暗黙選択しない。無条件に非ASCII値を削除しない。

profile選択は利用側の許可方針の一部であり、対象indexの列挙・raw patch・offset計算をアプリへ戻すものではない。許可設定と要否判定は引き続き独立する。profileを明示してもkeys破損や境界不明は拒否する。設計probeでは解釈の差を検証し、その後の製品実装でこの選択を公開APIへ反映した。

削除するのは不正index item全体だけ。残りのilst item、keys、hdlr、free、context順序はraw bytesで保持する。空になったilstや未使用keysも保持する。item数とkeys件数が一致しても意味を推定せず、再採番しない。不正item内は値へ変換せず、親内の境界と削除範囲を確定する。

既存`UnindexedMdtaPlan`はindex 0保持用として変更せず、境界・keys検証等の共通部分だけを再利用する。sanitizeはkeys削除・mdir化を伴うため流用しない。

## 計画・offset・保存世代

1. Generationのatom indexを共有し、metadataとQuickTimeを独立診断する。片方の異常をもう片方の正常値へ変換しない。
2. QuickTimeは既存の専用text track判定、正常／不在Nero、他用途参照、data reference、境界・上限検査を維持する。
3. 同じ元moov座標で、metadata item削除と専用track・chap参照削除を収集する。編集範囲の重複・矛盾を拒否する。
4. 一つの内部atom編集計画としてmoovを生成する。二つの完成済みreplacementや旧offset付き保存計画を順番に適用しない。
5. 合成後のmoovサイズから移動量を決め、残存stco/co64を一度補正する。既存のfree/padding規約を使い、overflowは拒否する。mdat内相対位置を不変とする。
6. 登録前、copy前後、独立検証後・公開直前に世代確認する。通常stat／厳密SHAモードの既存契約を維持し、外部writerとの完全排他とは扱わない。

内部は既存ChapterReferencesとMP4AtomEditorの解析・render・逐次copyを再利用する。metadataを丸ごと保持比較から除外するだけの実装は不可。修復対象の生bytesと対象外signatureを同時に確定する。

## 独立保持検証

修復経路では不正metadataの完全snapshot取得を保存前条件にしない。原本からraw保持基準を作り、出力を別Generation・別readerで再読込して比較する。

- metadata: 出力metaが「原本から指定した不正index item群だけを除いた期待bytes」と一致する。keys/hdlr、通常item、画像のbytes・順序・重複を保持する。除去後の診断で全数値indexがkeys範囲内にあることを確認する。
- QuickTime除去時: 対象trackと対象chap参照が不在。Neroの時刻・名称・順序とchpl payload SHA、不在なら不在を確認する。
- QuickTime非除去時: 正常QuickTimeの値・sample・track・参照を保持する。metadataのみ修復時にもchapterを再生成しない。
- 非対象track、字幕、他種tref、colr等は既存signatureとraw leaf比較で保持を確認する。構造上変更が必要な親sizeと絶対chunk offsetだけを正規化し、offsetは同じmdat内相対位置を比較する。
- 全mdatのsize・順序・SHA-256を原本copy中と出力独立scanで比較する。削除trackのsample bytesもmdatへ残す。
- 原本／出力全体digestを記録する。出力digestと保持hashは実際の出力から取得し、期待値で代用しない。

正常indexの値型がnative非対応の場合もraw保持検証で修復可能とするが、`snapshots: [:metadata]`の明示要求には完全読取できた実値が必要であり、取得できなければ公開前に拒否する。`:chapters`の要求で残存chapterを完全読取できなければ保存を拒否し、空値にしない。修復検証はsnapshot要求の有無に依存しない。

## 結果・失敗契約

新経路の`save!`は別出力`to:`を必須とし、原本と同じpathやaliasは拒否する。既存ファイル・symlinkへの上書きも拒否する。
既存resultのoutput_path/changed/source_digest/output_digest/verification/snapshotsを維持し、新経路では`operations`、`removed`、`committed: true`を付加する。登録結果と保存成功を区別し、除去対象は原本座標と件数・digestで報告する。
公開は既存の排他的linkとcleanupを使う。verify完了前には出力を公開しない。`committed`はgem出力公開済みを意味し、利用者原本の最終置換済みを意味しない。
失敗は既存Errorのcode/area/issues/phase/committed/output_path/temporary_pathで返す。公開前は原本と計画を維持し再試行可能。公開後のresult/cleanup失敗はcommitted=trueとし、Fileはclose以外再利用不可。原因不明のfallback保存は追加しない。

## I/O予算

Nを原本サイズ、N'を出力サイズ、Mを上限内moovサイズとする。
計画はheader・moov・必要chapter sampleを読み、mtimeだけでmetadata正常と推定しない。moov解析を二重化せず、必要範囲のhashを共有する。メモリはO(M＋既存上限内のtable/sample情報)で、mdat全体は保持しない。
保存は原本から候補へ一回の逐次copy（概ねN読取・N'書込）。原本全体digestとmdat hashをここで計算する。独立出力scanはN'読取で全体digestとmdat hashを兼用する。構造・値の独立再読込は追加の範囲読取である。
strictモードの世代確認SHAは既存仕様どおり別走査になり得る。全I/Oが上記二走査だけとは保証しない。
二段階の全面stage保存を一段階へ減らし、metadataのnative書込・再挿入を不要にする。hashと保持検証のCPU、およびmoov候補メモリが必要。保存コピー回数と計画／検証の解析回数は製品テストで計測した。併用修復の総bytesは未計測で、構造診断等の比較計測とは区別する。
無変更時は利用例のように保存を呼ばず書込ゼロ。別出力保存では候補N'分の一時領域を必要とする。容量判定の運用責務は利用側に残す。

## 受入検証項目と追加検証の範囲

1. 正常／metadataだけ／QuickTimeだけ／両方／blockedのfixtureと、許可リスト全組合せ。metadata許可あり・不要の場合にQuickTimeだけを実行できること。
2. index 0、K、K+1、0x00ffffff、0x01000000、0xffffffff、K=0、任意位置、正常／不正indexの交互配置、重複、通常item混在、画像、空ilst、keys保持を検証する。正常itemの順序・bytesが不変であること。keys破損、fourccとの曖昧性、未知構造、上限、短いread、I/O障害を成功にしないこと。
3. 音声／映像参照、共有track、字幕source、欠落target、複数target、未知handler、Nero異常、正常QuickTimeを既存条件どおり扱うこと。
4. moov前後のmdat、複数mdat、stco/co64、padding、offset幅上限。合成編集後の相対offsetとmedia bytesを独立oracleで比較すること。
5. 保存中に対象外metadata・画像・Nero・字幕・他参照・mdatを改変する故障注入を検証が拒否すること。期待値生成と独立oracleで編集コードを共用しない。
6. 古い／他File／偽造計画、外部更新、copy/verify/publish/result/cleanup障害、出力競合、再試行、committed、原因連鎖を検証すること。
7. 全面copy一回、原本copy中hash、独立出力scan、無変更書込ゼロを計測する。strict追加scanと範囲再読取を分けて報告する。
8. test:plus_mp4とtest/README.md指定の関連内部テスト、metadata contract probeを実行する。別backendでのfixture検証は追加検証事項とし、今回の現在のbindingでの成功と混同しない。

## 今回の確認結果

設計に関連する公開API、内部修復、QuickTime限定削除・metadata保持設計、共用atom編集ADR、公開失敗契約ADR、テスト構成を確認した。
既存QuickTime限定削除テストは13 tests / 134 assertions、失敗・error・omitなし。これは既存単独機能の検証であり、併用案の動作検証ではない。
これは設計段階の確認記録である。以降の製品実装・検証は下記と検証メモを参照する。

## 2026-10-20 設計probeの結果

[test/probes/mp4_invalid_mdta_repair_design.rb](../test/probes/mp4_invalid_mdta_repair_design.rb)を追加し、構文確認後に単独実行した。7 tests / 41 assertions、failure/error/omitなし。

- 0、K+1、0x00ffffff、0x01000000、0xffffffffと正常indexを交互配置し、正常item・keys・hdlrのraw bytes、順序、重複の保持と除去の冪等性を確認した。
- K=0、正常のみの無変更、keys欠落／件数不一致、未知ASCII fourccの拒否を確認した。
- 現行MetadataStructureReaderでは0x01000000と0xffffffffがfourcc扱いになり、invalid_indexに含まれないことを再現した。製品reader改訂時はこの観測テストを新契約のテストへ置き換える。
- 不正metadata＋壊れたQuickTimeの合成入力は、現行公開APIで計画を作れてもsave!が拒否することを確認した。
- 一時コピーで両編集を一つのmoov候補へ反映し、原本不変、正常mdtaの製品再読込、QuickTime不在、Nero chpl bytes、全mdat payload、残存trackのraw bytesとmdat内相対chunk位置の一致を確認した。

独立fixture editorと公開save!の両方で確認した。検証環境の現在のbindingのみで実行し、別backend、実ユーザーファイル、巨大入力、任意fourcc識別の安全性は未検証。

## 製品実装とI/O見直し

`LimitedRepairEditor`は一回の構造解析からmetadataとQuickTimeを独立判定し、同じmoov座標で編集を合成する。`plan_limited_repairs`はnativeを開かずHeaderReaderを読取sourceにする。原本moovは一回だけ読み、そのbytesをmetadata判定・leaf hash・stsd部分解析で共有する。解析済みの章・参照・時間情報も同じFile世代の診断で再利用する。

保存は`save!(to:)`の既存copy・scan・公開フローを使う。旧metadata完全snapshotは保存前条件にせず、原本から生成したraw保持signatureと独立出力のsignatureを比較する。出力構造解析も一回とし、対象track不在検証へ同じ解析結果を渡す。任意snapshot要求時の完全読取検証は別に維持する。

通常mdirのmetadataも、保持対象のraw境界・既知item・data headerを取得済みmoovで検査し、不要なnative診断・画像変換を避ける。不正index item内部の値は解釈せず親内境界を確認して除去する。保持するitemの構造不明はblockedにする。metadata全体で50,000 atoms、keys 50,000件、moovは既存64MiB上限を適用する。

cleanup失敗後のGCによる一時link削除が公開出力のctimeを変える問題を、GC finalizerのない明示管理Fileで解消した。公開後cleanup失敗は既存のcommitted=trueと一時pathを保持し、GC後もそのpathが勝手に削除されないことを検証する。

実行結果、I/O比較値、未検証範囲は[検証メモ](Memos/2026-10-20-限定修復と全体I-O見直しの検証.md)、全体の判断理由は[重複I/O削減ADR](ADR/2026-10-20-診断と保存検証の重複I-Oを削減する.md)を参照する。


## 非対象titlの保持と共通構造失敗

movieとtrackのudta内のtitlは、個数・track ID・同一payloadの重複で制限せず、各atomの境界・FullBox・言語・文字列表現を検証する。配置・順序・headerを含むraw bytesを保持し、保存時の独立再読込でもraw署名を比較する。削除対象のchapter track内にある場合は保持不能としてblocked。通常metadata setterの保持保証には拡張しない。

全体構造の解析に失敗した場合はmetadata/quicktimeを両方blockedとし、同一issuesのdetailsにscope=shared_structure、affected_areas、diagnosis=incompleteを残す。未診断領域をnot_neededにしない。titl由来の拒否では実際の番号付きatom path・絶対offset・header込みsizeを伝播し、固定のmoov/udta/titlへ置換しない。

対応条件・対象実ファイルの調査結果・制限は[主資料のtrack内titl対応](mp4-chapter-plan-safety-design.md#track内titlの保持対応2026-10-21)、理由は[ADR](../Docs/ADR/2026-10-21-track内の複数titlをraw保持する.md)を参照する。
