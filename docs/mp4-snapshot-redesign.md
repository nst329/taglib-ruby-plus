# MP4 snapshotのRuby API再設計

2026-10-11。状態: 設計案・未実装。現在の動作説明ではない。

2026-10-16追記: [Plus独自API全体の再設計](taglib-ruby-plus-api-redesign.md)を上位案として追加した。File直下の入口、pending状態、保存計画の扱いは上位案で再検討している。本書の純Ruby値・名前付き値・比較と保存保持の分離は、その設計材料として引き継ぐ。

## 前提と範囲

オリジナルのtaglib-rubyが公開するAPIの互換性は維持する。このforkで追加したRuby APIは、名前・引数・戻り値・比較規則を変更できる。native ABIやTagLib本体のwriterは今回の変更対象に含めない。

対象はmetadata、論理chapter、保存済みchapter sampleのsnapshotと、その取得・編集・復元・保存検証への接続。未知atomの完全保存、字幕の一般的なmanifest、修復profile、ファイルの永続化保証は拡張しない。

安全性の契約はAPI互換性とは別に維持する。部分読取を完全snapshotとして返さず、候補全体を検証してから一度だけ反映する。保存時は別出力の独立再読込・保持確認後に原本を置換する。失敗時のpending状態とcommittedの区別を保つ。

## 現状の問題

- `mp4_metadata_snapshot.rb`に不変値、差分、atom構造診断、native変換、Tag/Fileへの接続が同居する。
- `Tag#metadata_snapshot`は公開の型付き値、privateな`File#metadata_snapshot`は保存比較用Hash。名前が同じでも比較の目的が異なる。
- `items`と`mdta`の位置依存配列を、構築・編集・差分・native変換の各所で分解している。
- chapterや診断のコピーも`MetadataSnapshot.copy`に依存する。
- `File#tag`がTagへパス・有効性・原本のitem型をinstance variableとして注入する。診断には原本構造と編集中のnative値が混在する。
- `with_properties`は値編集のAPIだが、更新計画の作成にnative Itemを使う。

## 決定する責務

| 層 | 責務 | 依存・禁止事項 |
| --- | --- | --- |
| snapshot値 | 入力検証、所有コピー、不変化、キー単位編集、比較と差分 | Ruby標準ライブラリのみ。native、File、writerを呼ばない |
| MetadataUpdate | propertyから型付き更新計画を生成し、snapshotへ適用する | native setterを実行しない。原本を読まない |
| MetadataCodec（内部） | native ItemとRuby値の相互変換、writer候補の検証 | 行配列への変換はnative境界に限定する |
| MetadataAccess（内部） | Fileを文脈としてcapability確認、診断、取得、一括復元 | 原本の観測とpending状態を区別する |
| ChapterReader（内部） | 完全読取と形式別診断、論理値とsample観測の生成 | snapshot値やFileのprivate parserに依存しない |
| 保存検証（内部） | 保存前期待値、独立再読込、用途別の保持照合 | 公開snapshotの一致だけで原本保持成功としない |
| File | 公開入口、native/pending状態の所有、既存保存トランザクション | snapshot自身へnative handleを渡さない |

共通のsnapshot基底クラスや汎用Repositoryは作らない。metadata、chapter、sampleで意味・時刻単位・復元能力が異なるため、型を分ける。

## 値モデル

以下の名前はすべて`TagLib::MP4`内。通常のRubyクラスで実装し、属性と検証を明示する。Struct/Dataを使う場合も浅いfreezeだけでは受け入れない。

| 型 | 属性・意味 |
| --- | --- |
| MetadataItem | `kind`, `atom_data_type`, `value`。9種の既存native Itemを表現 |
| MdtaValue | `data_type`, `locale`, `data`。dataは所有するbinary String |
| SnapshotArtwork | `format`, `data`。観測した整数formatとbinaryを保持 |
| MetadataSnapshot | `items: Hash<String, MetadataItem>`, `mdta: Hash<String, Array<MdtaValue>>`, `source_layout` |
| ChapterSnapshot | `nero`, `quicktime`。不変のChapter配列。両形式を独立に保持 |
| ChapterSampleSnapshot | 保存済みsampleの観測値、media時計、movie/edit、保持署名 |

通常itemキーはUTF-8/NULなし。mdta値内のbinaryはNUL・空bytes・未知の型番号を保持する。全String・Array・Hashは入力からコピーしてfreezeする。既に検証済みの不変値は内部で共有できる。

SnapshotArtworkは高水準Artworkと統合しない。高水準Artworkの署名・既知形式制約は、rawの観測値を完全に表現する契約と異なる。

MetadataItemの`value`はscalar、2整数配列、文字列配列、binary配列、SnapshotArtwork配列のいずれか。9種類のItem subclassは作らない。キーと型の組・writerの保存幅は復元時にnativeで検証し、値の構築成功を保存可能の証明としない。

`source_layout`は取得元の配置とkeys順序/indexを表す不変の観測情報。編集後も取得元の情報であり、復元先の予測ではない。構造情報は現行の名前付きHashを整理して使い、不要な値クラスは増やさない。手動構築時はnilを許し、観測なしを空構造と区別する。

MdtaValueにはキー・indexを持たせない。キーはHashのキー、indexはsource_layoutに集約する。値なしキーは`mdta[key] == []`、キー不在はnil、空payloadは値1件以上として区別する。

sampleのHashは属性名が既に明確なため、現段階で全sampleをクラス化しない。constructorに許される属性を明示し、任意キーをinstance_variable_setで追加しない。payload保持の署名仕様とticksは維持する。

## 公開API

### Fileから取得・復元する

```ruby
original = source.metadata_snapshot
expected = original.without(items: ['©cpy']).with(
  mdta: {
    'gain' => [TagLib::MP4::MdtaValue.new(data_type: 1, locale: 0, data: 'new'.b)]
  }
)

candidate.restore_metadata_snapshot(expected)
candidate.save
actual = candidate.metadata_snapshot
raise 'metadata differs' unless expected.same_values?(actual)

chapters = source.chapter_snapshot
candidate.restore_chapter_snapshot(chapters, styles: [:nero])
samples = source.chapter_sample_snapshot # 保存済み値だけを取得。不在はnil。
```

metadata取得・復元・診断・capabilityの公開入口をFileへ移す。旧`Tag#metadata_snapshot`/`restore_metadata_snapshot`/`metadata_diagnostics`/`metadata_capabilities`は移行後に削除し、互換aliasは残さない。native Tag/ItemMapは従来どおり使える。

`File#metadata_snapshot`はpending metadata込み、chapter_snapshotはpending chapter込み、chapter_sample_snapshotは保存済み値のみ。sampleにpendingを混ぜるオプションは追加しない。Fileを閉じた後は取得済みsnapshotを使えるが、Fileに対する再取得・復元は拒否する。

`items`と`mdta`をそのまま名前付きの不変値として取得する。旧`item`/`mdta_values`はHash参照へ統合する。`artworks`はcovrの観測値を返す補助APIとして残せる。

`with`は指定キーの全値置換・追加、`without`はキーの削除。暗黙merge・append・型推測はしない。新mdtaキーの物理indexはsnapshot編集時に採番せず、復元時に保存先nativeで決める。既存bindingに行配列が必要な場合は、MetadataCodecがキー列挙順に一時的な有効indexを付けて渡す。保存先の既存indexを維持する処理はnativeに任せ、source_layoutのindexを強制しない。

### property更新計画

```ruby
update = TagLib::MP4::MetadataUpdate.properties(title: '', show: '番組')
expected = update.apply(original)
candidate.apply_metadata_update(update)
```

MetadataUpdateは不変の`set_items`、`remove_items`、`clear_mdta`を持つ。同じ通常itemの設定と削除の競合は構築時に拒否する。applyは新snapshotを返し、native適用は入力全体とwriter候補を再検証してからcommitする。`properties`は既存のset_properties相当の入力契約だけを扱う。nilを削除扱いしない。通常文字列はUTF-8へ変換し、不正encoding/NULを拒否する。show/TVShowNameの重複は拒否する。copyrightは©cpyのみ、contentRatingは既存ContentRatingの入力規則を使う。

文字列の既知の変換はRubyで定義する。通常文字列itemのatom型255、freeformの明示型1を計画に記録する。Item.from_string_listから期待値を読み返す処理は廃止する。native setterの正規化と一致することは独立の手書き期待値と保存後再読込で確認する。

`clear_mdta`は物理キー削除ではなく、値の全削除。snapshotにキーが存在すれば空配列へ変更し、不在なら追加しない。これによりnativeの既存index維持と期待snapshotの論理値を区別できる。

既存forkの`Tag#set_properties`は同じ計画生成処理へ委譲する。File#apply_metadata_updateは全候補検証後に一回で適用する。更新対象の説明も計画から取得し、property定義を複製しない。

`with_properties`は削除する。空値と削除を混ぜるBuilderやブロックDSLは導入しない。原版のtitle=などのsetterは従来の変換・返り値・mdtaへの影響を維持し、MetadataUpdateへ無理に統一しない。

ContentRatingやChapter等、純粋な値クラスが現在native読込ファイル内にある場合は、native非依存のファイルへ移動する。値APIはnativeがない別プロセスでもrequireできることを受入条件にする。

## 比較契約

MetadataSnapshotの比較を以下へ整理する。旧logical_equal?、structure_equal?は削除する。

| API | 比較対象 |
| --- | --- |
| `==` / `eql?` / `hash` | 通常itemのキー・kind・atom型・値、mdtaのキー・型・locale・値順・重複。値なしキーの存在も含む |
| `same_values?` | 上記から値なしmdtaキーの存在だけを除く。復元先の既存空キーを許す別ファイル比較 |
| `same_source_layout?` | 両方に観測情報がある場合のsource_layout一致。値の一致は保証しない |
| `diff(other, mode: :exact)` | `==`と同じ値差分。`:values`ならsame_values?と同じ差分 |

キー間のHash順序は値比較に含めない。mdtaキー内の値順と重複数は含める。source_layoutは取得元の観測なので`==`/hashに含めず、同一snapshot編集後のディスク構造を保証しない。観測なし同士のsame_source_layout?はfalseとし、構造保持の証明に使わせない。

`diff(...).empty?`と対応する比較結果を一致させる。別型の比較はfalse、別型へのdiffや未知modeはArgumentErrorとする。差分はまず生値で判定し、公開返却値ではbinary/画像をサイズ・SHA256、長文を制限付き表示へ縮約する。現行の名前付きHash配列を維持し、新しいDiff階層は作らない。

ChapterSnapshotの`==`は両形式のミリ秒時刻・タイトル・順序を完全比較し、diffの空判定と揃える。ChapterSampleSnapshotは`preserved_equal?`を残す。これはsample保持の照合であり、movie/edit時間の一致や異なるmux出力でのtrack ID不変を意味しない。

## 原本・pending状態・保存結果を分ける

MetadataAccessはFileに属する内部オブジェクトで、原本のパス、有効性、原本item型を明示的に受け取る。Tagにinstance variableを注入しない。native handleを長期保持せず、各操作時にFileから取得する。close/reopen後は原本文脈を再構築する。

File#metadata_diagnosticsは原本構造の診断とpending候補のwriter可否を別フィールドで返す。capabilityはbackendの機能、diagnosticsは対象ファイル/候補の可否であり、キー一覧の取得成功だけで機能全体の対応を推測しない。確実な機能判別方法は両native layoutの既存bindingを確認して実装段階で固定する。

保存比較用のprivateメソッドは`metadata_save_signature`へ改名する。公開snapshotとは統合しない。

- 同一ファイル保存では既存keys/index、writerのfreeform型推論、media/chapter保持も検証する。
- 別ファイル復元では公開snapshotのsame_values?を使い、復元先の既存空keysを許す。
- 無変更時もsource_layoutの再利用をディスク観測の代わりにしない。保存結果を独立に開いて読み直す。
- 既存nativeでsnapshot能力がない場合の通常APIの互換動作を維持する。公開snapshot取得は拒否し、通常保存の内部検証へ完全capture要件を無条件に追加しない。

MetadataCodecは両経路の型付き読取を共有するが、公開captureは未知/部分読取を拒否する。従来保存用のunknown表現を公開snapshotに混ぜない。freeformのwriter推論は保存検証側に置き、公開値を暗黙に補正しない。

保存トランザクションのcopy → native保存 → 独立照合 → rename → reopenと、MdtaSaveErrorのphase/committedは維持する。snapshot復元はpending状態への操作であり、ディスク保存ではない。未知atom・字幕・mediaのすべてをsnapshotの一致だけで保証しない。

## 読取処理・例外

metadataとchapterで共通化するのはatom header、範囲、子box列挙、指定bytes読取だけ。内部AtomReaderへ集約し、領域ごとの深度・件数・payload制限を明示的に渡す。現在の拒否条件を単一の広い上限へ緩めない。

ChapterReaderは`samples: true`という動作切替constructorをやめ、`read_chapters`と`read_samples`という明示的入口を持つ。両方で共通の構造解析結果を利用する。完全読取が証明できない場合は現在どおり拒否し、対応形式の拡張やpadding規約の変更は含めない。

値構築エラーはArgumentError、capture/restoreの拒否はSnapshotError(code, phase, area, issues)、保存後の結果は既存MdtaSaveErrorで区別する。MetadataSnapshotError/ChapterSnapshotErrorは新独自APIへの移行時に統合可能だが、native例外やプログラミングエラーをすべてunsupportedへ変換しない。読取の境界/I/Oエラーだけを文脈付き診断へ変換する。

## 移行と変更範囲

1. 原版の公開APIとfork追加APIの一覧を既存YARD/生成wrapperから確定する。原版の返り値・encoding変換・例外を既存テストで固定する。
2. 不変値、MetadataUpdate、差分をnative非依存のファイルへ分離し、新値モデルを作る。
3. MetadataCodecとMetadataAccessを作り、取得・復元をFileの公開APIへ切り替える。
4. private保存署名へ改名し、保存比較方針を分離する。トランザクション本体は維持する。
5. 呼出側・受入テスト・YARD・READMEを移行し、旧fork APIと位置依存配列のRuby内伝播を削除する。
6. AtomReaderとChapterReaderの入口整理を別変更として進め、異常構造fixtureで受入判定を維持する。

主な変更対象: `lib/taglib/mp4_metadata_snapshot.rb`、`mp4_property_update_plan.rb`、`mp4_chapter_snapshot.rb`、`mp4_chapter_sample_snapshot.rb`、`mp4_chapter_reader.rb`、`mp4.rb`と対応テスト/設計/APIコメント/gemspec。ファイル分割は責務単位で行い、1メソッドごとのファイルは作らない。

旧APIの非推奨期間・alias・v1/v2並行実装は設けず、独自APIの破壊的変更をリリースノートにまとめる。gemspecの配布一覧とrequire順を更新する。既存のformat_version=1は行配列の表現に結びついているため新値モデルへ持ち込まない。今回は永続化/JSONプロトコルを提供しない。sample保持署名のversion=1は別の契約として残す。

外部のMListNew等の呼出側は、このリポジトリの設計だけで移行済みと扱わない。実装・配布前に使用箇所を確認して移行先を記録する。今回そのリポジトリの変更はしない。

## 受入条件

- nativeがないプロセスで値APIのrequire・構築・編集・比較ができる。取得元をclose/GCしても文字列・画像・mdta値を使え、入力の変更がsnapshotへ伝播しない。
- 全9Item型、画像未知format/空bytes、mdta異型/locale/順序/重複/空payloadを保存・再読込で保持する。未対応writerはcommit前に拒否する。
- 不在キー/空キー/空payloadを区別し、exactとvaluesそれぞれで差分空と比較結果が一致する。source_layoutなしを構造保持成功にしない。
- property更新は手書き期待値とnative setterの実結果・保存後再読込で照合する。同じ計画同士の一致だけを成功条件にしない。
- 最後の入力の不正やnative候補後半の失敗でもTag/ItemMap/pending/原本を維持する。復元の繰返し、保存失敗後の再試行が成功する。
- 一時出力の実データ故障をrename前に検出する。rename後reopen失敗はcommitted=trueで区別する。
- chapterの両形式不一致、片形式復元、sample ticks/padding、参照/時間修復後のsample保持を維持する。宣言件数欠落・mdat外参照・不正文字列を完全snapshotにしない。
- 原版APIの返り値・変換・例外と、snapshot非対応nativeでの通常APIを検証する。legacy/groupedを独立プロセスで検証し、配布artifactはソーステストと別に確認する。

今回は設計の静的レビューのみ。これらの条件を実行済みとは扱わない。

## 採用しない案

- 全snapshotの基底クラス化: 値と観測・復元能力の違いを曖昧にする。
- 全Hashのクラス化: キー付きitem/mdta値以外は効果が薄く、クラス数と変換が増える。
- Rubyによるwriter実装/型上限表の複製: nativeとの二重管理になる。
- 公開snapshotだけによる通常保存検証: index・writer変換・media保持の検証を失う。
- 比較条件を任意コールバックで注入: 保持条件が呼出ごとに拡散する。exact/valuesと内部保存方針へ限定する。

## 既存設計との関係

この案は、既存の[metadata snapshot](mp4-metadata-snapshot-design.md)、[部分編集・差分](mp4-snapshot-extensions-design.md)、[値取得・property期待値・chapter](mp4-snapshot-access-chapter-design.md)、[chapter sample](mp4-chapter-sample-snapshot-design.md)に対する次期Ruby設計。実装完了までは既存設計が現行動作の説明であり、本案の名前・比較規則を現行APIへ適用しない。
