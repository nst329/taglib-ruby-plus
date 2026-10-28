# QuickTime chapter計画拒否の調査と安全性設計

日付: 2026-10-21
状態: 実装済み（2.3.2.32の合成fixture検証済み）。実作品確認とbackend拡張は未実施。

追記: `QuickTimeChapterRemovalPlan#message/#issues`、`DanglingChapterReferenceRemovalPlan`、限定修復の`:remove_dangling_chapter_references`を実装した。[メッセージ保持ADR](ADR/2026-10-21-chapter計画の拒否メッセージを保持する.md)を参照。

実装方針: 正しさ・破損防止・公開API契約を満たすことを前提に、**実装でもI/Oが少なくなる方針を優先する**。読書き回数とbyte数を評価し、取得済みデータの再利用、必要範囲の読取、変更の一括保存、無変更時の書込回避を行う。安全性確認に必要な検証は省略しない。

## 対象と制限

依頼の最終指示「確認し設計して」に従い、今回は現行コードの調査と設計までとする。実作品KBI-060（753,326,184 bytes）とGVG-793（696,554,517 bytes）の所見は依頼者提供の診断であり、実ファイルのパス・payloadは提供されていない。実作品の探索、コピー、保存、置換、削除は実施していない。KBI-060のtitlが以下の対応profileに一致するとは断定しない。

## 現行実装で確認した責務と原因

| 領域 | 現行の意味と制限 |
| --- | --- |
| `chapters` / `chapters=` | ChapterReaderの完全読取値から両形式の編集候補を作る。snapshot取得だけのnative handle openは行わない |
| `diagnose(:chapters)` | ChapterReaderによる形式別の値の完全読取。編集時の全構造保持を証明しない |
| `diagnose(:structure)` | atom境界・chunk offset等の診断。参照編集が対応する構造全体の証明ではない |
| `diagnose(:chapter_references)` / `:chapter_timing` | ChapterReferencesの全構造検証後に参照・時間情報を返す。構造未対応なら観測前に拒否 |
| `plan_quicktime_chapter_removal` | 専用text trackをchap参照とともに除去する計画。正常QuickTimeの統一・削除APIではない |
| `detach_chapter_references(references:)` | 指定chap関係だけを解除する既存Plus公開API。track自体を削除しない |
| native `remove_dangling_chapter_references` | 存在しないtargetへの参照だけを選ぶ既存内部機能。Plus APIは計画と世代検証を追加する |

`ChapterReferences#initialize`は、構造検証、参照収集、選択検証、offset検証、時間収集、編集準備の順に進む。ただしPlus公開入口の`read_structure`には先行する構造検査もあり、例えば重複track IDはそこでmalformedになる。内部ChapterReferencesの分類と同じになるとは限らない。`moov/udta/titl`は条件付きprofileで検証し、chapter読取completeと編集可能性を分離する。

`QuickTimeChapterRemovalReferences#prepare_atom_edits`はchapter状態検証後、source handlerを検証してからtarget欠落を検査する。このためvide/soun/sbtlから欠落先0を指す場合、`:missing_reference`より`:subtitle_source`が先に出る。字幕から実在targetへのtrack削除を防ぐ検査として必要だが、参照だけの解除可否の判断には流用しない。

`build_quicktime_removal_plan`は例外を捕捉し、codeだけをreason/reason_codeへ渡す。message・場所・参照行は失われる。限定修復editor内の捕捉にはmessageがあるが、基底の構造検査はその捕捉より前であり、構造未対応時には`plan_limited_repairs`から例外が出る経路もある。

## ケース1: titlを保持する条件

3GPP TS 26.244のTitle boxはversion=0、flags=0、packed language、NUL終端UTF-8またはBOM付きUTF-16の文字列を持つ。規格で定義されたpayloadにファイル位置やtrack参照はない。この形式に一致すると検証した範囲では、位置が変わってもpayloadの内容を変更する必要がない。

参照: [3GPP TS 26.244 V2.0.0 表8.1](https://www.3gpp.org/ftp/TSG_SA/TSG_SA/TSGS_23/Docs/PDF/SP-040065.pdf)。これは実作品形式の証拠ではなく、対応profileの根拠である。

現在の保持条件は以下とする（2026-10-21のtrack配置対応で更新）。

1. `moov/udta/titl`と`moov/trak/udta/titl`。movie・複数track・複数udta内の複数titlを各個に検証する。同一言語の重複も非対象データとして元順序で保持し、規格への意味的な正規化は行わない。他階層は拒否する。
2. 通常8-byteまたは拡張16-byte headerの明示sizeで親境界内に収まるleaf。size=0は親末尾依存の表現として引き続き未対応。
3. full boxの4 bytesがすべて0。languageのpad bit=0、各5 bitが1..26。非対応version/flagsや言語表現はunsupportedとする。
4. UTF-8は妥当な符号列で、最後の1 byteだけがNUL。UTF-16はFE FF BOMを持つBE表現、偶数長、妥当なsurrogate、末尾の2 bytesだけが終端。空文字列も終端があれば許可する。LE BOMは当初profile外とする。
5. 宣言済みversion=0で本文が短い、終端欠落、文字列破損ならmalformed。未対応配置・versionはunsupported。不明な文字列末尾データはmalformed。いずれも編集はblocked。
6. 検証は意味の再シリアライズをしない。全payloadと元headerを保持し、保存後は独立handleで配置・順序・個数・header込みraw長/hashを比較する。Nero/chplとmetadata/artworkも従来どおり保持する。

`STRUCTURES`への無条件追加は行わず、titl専用の条件付き検証経路を設ける。許可条件を診断・時間診断・参照解除・専用track除去・限定修復で共有する。通常のnative metadata/chapter setterがtitlを保持するとの保証には拡張しない。正常QuickTimeはtitl対応後も限定除去の`:complete`であり、壊れたchapterとして削除しない。KBI-060は時間異常がなければ、この結果になる可能性がある。

## ケース2: 欠落参照だけの解除

専用track除去のsource制限は維持し、既存APIのreason_codeの優先順位も変えない。全参照行の詳細をissuesへ追加すれば、字幕source拒否と欠落先の両方を公開できる。

既存`detach_chapter_references`と同じ`ChapterReferenceRepair`を実行基盤に使い、MListNew向けの計画境界として次を追加した。

- `plan_dangling_chapter_reference_removal`: 不変計画。statusは`:repairable` / `:unchanged` / `:blocked`、reason_code、issues、選択referencesを公開する。
- `remove_dangling_chapter_references(plan:)`: 同じFile/世代で発行した計画だけを登録するPlus API。legacy同名APIは変更しない。
- target IDの数値0を特別扱いせず、検証済みtrack ID集合に存在しないことを根拠に選択する。重複track IDなど欠落判定が曖昧な入力は拒否する。
- sourceが通常字幕でも、変更対象は存在しないtarget IDへのchapエントリだけ。source track、sample、時刻、chap以外のtref、実在targetへのchapは保持する。空のchap/trefの扱いは既存rendererに合わせ、非対象参照を巻き込まない。
- 欠落と実在が混在する場合も欠落行だけを選ぶ。実在targetが共有されていても、このAPIはそのtargetも参照も削除しない。専用track削除API側の共有target・字幕source拒否は回帰検証する。

限定修復へは、同じ選択・編集検証を使う操作`:remove_dangling_chapter_references`を明示的allowとして接続した。専用track除去と操作を区別し、全chap参照が欠落しているケース2をtarget_track_id=nil、track削除なしとして扱う。混在状態は限定修復ではblockedとし、個別の欠落参照計画で扱う。

既存QuickTimeChapterRemovalPlanの`:removable`を参照だけの操作へ拡張しない。検証時も「target track不在」を要求する専用track除去と、「全track保持」を要求する参照解除を分ける。Nero不完全時はMListNew向け計画・限定修復をblockedとし、Neroを失う可能性を隠さない。

## 公開診断の追加と互換性

既存QuickTime計画のstatus/reason/reason_codeを維持し、`message`と凍結した`issues`を追加する。ChapterReferenceErrorにもissuesを追加し、diagnose、計画結果、登録拒否Error、限定修復のネストした結果まで同じ具体情報を伝える。

```ruby
# 追加するissue形式の例。offsetは原本の絶対byte位置。
{ code: :unsupported, message: 'unsupported titl location: expected movie or track user data',
  location: '/moov[1]/trak[3]/titl[1]',
  details: { atom_path: '/moov[1]/trak[3]/titl[1]', offset: 1234, size: 40 } }

{ code: :missing_reference, message: 'chapter reference target is missing',
  location: 'moov/trak/tref/chap',
  details: { source_track_id: 26, source_handler: 'sbtl',
             target_track_id: 0, target_exists: false,
             tref_index: 0, reference_index: 0 } }
```

場所にはtrack ID・各indexもdetailsで添える。部分解析できなかった場合は参照を捏造せず、得られた構造位置だけを返す。未知構造をunsupported、壊れた既知構造をmalformed、安全に選択可能な欠落をrepairable、正常をcomplete/unchangedとして区別する。新APIのstatus語彙を既存APIへ流用して置き換えない。source_changedやI/O失敗は通常のblockedへ隠さず例外を維持する。

公開入口で先行する構造検査のissuesもそのまま保持する。duplicate track IDは公開診断で既にmalformedと報告されるため、この既存分類を維持する。限定修復の構造未対応は、現行ではErrorとなる経路を新設計でblocked計画へ統一する。解析不能なのにmetadata/quicktimeを正常扱いせず、両領域に同じ構造issueを示す。互換性上これは「計画APIの構造未対応時に例外からblocked結果へ変わる」追加仕様としてリリース時に記載し、I/O・source_changed・プログラム引数エラーは例外のままにする。

## MListNew向け推奨順序

以下は実装済み公開APIの使用例である。まず限定修復を計画し、blockedなら具体的issuesを記録して停止する。アプリでblockedを無視したり、atomを書き換えたりしない。

```ruby
TagLib::Plus::MP4.open(source_path) do |file|
  plan = file.plan_limited_repairs
  raise "repair blocked: #{plan.quicktime.inspect} #{plan.metadata.inspect}" if plan.status == :blocked
  if plan.status == :repairable
    file.apply_limited_repairs(plan: plan, allow: [
      :remove_broken_quicktime_chapters, :remove_dangling_chapter_references
    ])
    file.save!(to: output_path)
  end
end
# 保存した場合、output_pathを別セッションで開き、Nero/参照/時間/構造を再診断する。
# :unchangedは修復不要であり、作品整理全体の保存可能性の保証ではない。
```

metadata修復が必要なら`mdta_layout`を別途確定し、必要操作だけをallowへ明記する。allow不足は停止する。全章snapshotは壊れたQuickTimeで失敗するため、事前Nero取得は`read_chapters(style: :nero)`を使う。診断を先に全種類実行することは必須にしない。計画が使った観測を同一世代で再利用し、詳細表示が必要な場合にdiagnoseを呼ぶ。

独立した欠落参照処理では、`plan_dangling_chapter_reference_removal`→status確認→`remove_dangling_chapter_references(plan:)`→`save!(to:)`を使う。既存のblocked計画を無視するMListNew側の代替処理としては採用しない。

```ruby
plan = file.plan_dangling_chapter_reference_removal
if plan.status == :repairable
  file.remove_dangling_chapter_references(plan: plan)
  file.save!(to: output_path)
elsif plan.status == :blocked
  logger.warn("dangling chapter repair: #{plan.reason_code}: #{plan.message}")
end
```

## I/Oと保存境界

titl検証にmdat読取は不要。計画で取得したmoovを再利用し、titlの範囲だけを検証する。診断の`capture_raw: false`経路は必要なtitl bytesだけ読み、ファイル全体のコピーを生成しない。計画と診断の無期限キャッシュやbackend間の共有機構は追加しない。

実装時の具体条件を次に固定する。

- 診断・計画からの全体コピー、native metadata/artwork取得、ffprobe起動は追加しない。テストでの独立probeは検証用であり製品処理に移さない。
- 編集計画では既存のmoov rawを取得した後にtitl本文を検証できる順序にし、検証・保持署名・rendererで同じbytesを利用する。現行の構造検査→raw取得の順序に単純に本文読取を足すと二重読取になるため避ける。raw取得前もatom境界と64 MiB上限を確認する。
- 読取専用診断は、titl対応を理由にmoov全体やartworkを取得しない。範囲読取を使う。必要なprofile検証に対する読取量はpayload長に比例し、mdatサイズには比例させない。
- 限定修復は一回のChapterReaderと一回のChapterReferences解析からmetadata・欠落参照・専用track除去を判定し、個別の公開計画APIを順番に呼んで再解析する実装にしない。
- 成功時だけでなくblocked時も取得済みの不変参照行・issuesを計画へ渡す。理由表示のためだけに同じファイルを再解析しない。診断の観測値と編集用の候補は別に保持し、未完了の解析結果をcompleteとしてキャッシュしない。
- 同一世代の同一diagnoseは既存キャッシュを再利用する。statモードでの原本media本文0 byteという既存診断の性質を維持する。sha256モードでは世代照合に全体読取があるため、0 byte保証の対象外とする。
- 必要操作なしの計画はreplacementを生成せず、修復のみのsaveは書込なしとする。複数修復は一つのmoov候補にまとめる。保存のコピーと独立検証は省略しない。

I/O回帰テストでは読取要求のoffset/lengthとmdat本文の重なり、同一診断の追加読取、保存のコピー回数を観測する。キャッシュ内部の特定の呼出回数をテストするより、不要な全体走査・本文読取・コピーが増えないことを検証する。診断範囲と再診断に加え、titl付き限定修復計画のmoov取得が一回、その後のmoov内個別読取が0件であることを確認した。保存回数の追加計測は未実施である。

Plus保存は既存の逐次コピーとmedia hashを使い、出力の独立走査・保持signature検証後に公開する。新操作ごとの追加mdat走査・外部probeは導入しない。現行コードには世代確認・独立読取・hash取得等もあるため、全体の読取回数を単純に1回とは表現しない。性能改善値は未計測。legacy保存の事前cp等の最適化は今回の範囲外。

失敗時は原本を変更せず、一時生成物をcleanupする。公開後のcleanup/reopen失敗はcommitted/output_path/temporary_pathを正確に報告し、「保存されなかった」と偽らない。metadataと参照を同時修復する場合も一つのmoov候補と一回の公開へまとめる。

## 実装時の検証計画

| fixture / 故障注入 | 必須の確認 |
| --- | --- |
| 正常Nero+正常QuickTime+対応titl | 章読取complete、参照・時間診断complete、専用track除去はcomplete |
| 正常Nero+破損QuickTime+対応titl | 安全条件一致時のみremovable、別出力で独立再読取 |
| vide/soun/sbtl→欠落ID 0・非0 | 欠落計画repairable、通常字幕を含む全track保持、全欠落chapだけ解除 |
| 欠落と実在の混在、同じchap内の重複 | 個別計画では欠落行だけ解除、残存参照の順序とindexを検証、限定修復はblocked |
| 通常字幕sampleを持つsbtl→実在target | 専用track除去のsubtitle_source拒否継続、欠落計画は無変更 |
| 共有target・未知atom・外部dref・曖昧track ID | 専用track除去または全構造検査の拒否継続 |
| titlのversion/flags/配置/重複/境界/終端/encoding不正 | profile外と破損を区別し、原本・payloadを変更しない |
| moovがmdatより前/後、stco/co64、4-byte余り | offset補正、非対象sampleと時刻の同一性 |
| metadata修復+欠落参照解除、titl併存 | 明示allowのみ、部分適用なし、除去対象外metadata/artwork保持 |
| write/verify/publish失敗、原本変更、cleanup失敗 | 原本hash保持、一時生成物除去、除去不能なら残存pathとcauseを公開 |

全fixtureで診断・計画前後の原本hashを比較する。出力を独立handleとatom検査で確認し、titl全payload、Neroの時刻・名称・順序、chpl全payload、非対象atom・metadata・artwork、chap以外の参照を比較する。映像・音声・通常字幕についてpacket payloadとPTS/DTS/duration/time_baseを外部probeで独立比較する。mdat hashだけをpacket/時刻検証の代わりにしない。

既存テストは欠落参照・通常字幕・限定除去・保存失敗の基盤を持つが、対応titlと今回追加する計画APIの試験にはならない。新fixture検証完了前に実作品対応済みとしない。Ruby/nativeの組合せ、OS、backend、UTF-16 profile、実作品条件ごとに実行結果を記録し、未実行条件と分ける。

## 今回の確認結果

- ローカル読込version: taglib-ruby-plus 2.3.2.32、Ruby 4.0.7、arm64-darwin27。
- `test/plus_mp4_quicktime_removal_test.rb`、`test/mp4_chapter_references_test.rb`、`test/plus_mp4_limited_repair_test.rb`を同一runnerで実行し、62 tests / 770 assertions、失敗・エラー・省略0。
- `test/plus_mp4_api_test.rb`を含めた実行はshoulda-context不足で起動失敗。bundle経由でもrake-compiler 0.9.9、shoulda-context 2.0.0、yard 0.9.45不足で起動できなかった。依存追加は行わず、このテストを成功扱いにしない。
- 本体コードへtitl条件付き検証、欠落参照計画、限定修復接続を実装した。実作品診断、他OS/backendの検証は未実施。合成fixture成功をそれらの安全性の証明に流用しない。
- この環境では`Docs`と`docs`は同じディレクトリとして解決され、Git上の追加pathは既存の`docs/`表記になる。

## テストコードによる設計確認（2026-10-21追記）

追加した`test/mp4_chapter_plan_safety_design_test.rb`は本体の新実装を合成fixtureで検証する回帰テストであり、mockは使用していない。

| 追加テスト | 実測した結果と設計への反映 |
| --- | --- |
| titl付きNero/QuickTime | titl payloadを保持したまま専用track除去を保存。位置外titl・不正終端はunsupported/malformedで拒否 |
| vide/soun/sbtlの全chap→0 | 参照complete、全行missing、時間tracks空、単独除去subtitle_source。限定修復の`:remove_dangling_chapter_references`だけを許可し、全track・非chap参照・Nero/chpl・metadata/artwork・mdatを保持 |
| 同じchapの欠落ID 0/88888と実在音声IDの混在 | 欠落6行だけを解除し、実在先への3参照・通常字幕と全packetを保持。実在参照が残るので専用track除去はsubtitle_sourceを維持 |
| 未知udta/zzzz | 診断unsupported、計画blocked、参照解除拒否、原本不変 |
| 重複track ID | 公開入口でmalformed / duplicate track ID。限定修復はblocked計画、参照解除拒否、原本不変 |
| 参照解除後のverify失敗注入 | 原本hash不変、出力未公開、ディレクトリ内の部分生成物なし |
| 参照診断のI/O観測（stat） | HeaderReaderのread_mp4_bytes経由の全読取がmdat本文と非重複。同じdiagnoseは同じreportを返し、同経路の追加読取0件 |

保存成功の2ケースは、ffprobeのpacket data_hash・PTS/DTS・duration等をpos以外すべて比較し、streamのcodec・time_base・duration_tsも比較した。これは通常字幕をmov_textで実際に符号化したfixtureでの検証であり、handler名だけを付け替えた擬似字幕ではない。raw比較には実JPEG artworkを含むudta全体を使用した。外部probe自体のI/O、OSキャッシュ、syscall数、保存全体のI/O量は計測していない。

実行結果: Ruby構文チェック成功。追加10 tests / 99 assertions、失敗・エラー・省略0。既存関連テストと合わせて72 tests / 869 assertions、失敗・エラー・省略0。[責務整理とtitl再読込削減ADR](ADR/2026-10-21-chapter計画の責務整理とtitl再読込削減.md)にリファクタリングの判断を記録した。

未検証: UTF-16 titl、新計画の世代変更後拒否、今回fixtureでのmoov先頭配置と移動、未知backend、実作品。共有専用target・実在text chapterへの字幕source拒否は既存テスト側の確認範囲である。


## track内titlの保持対応（2026-10-21）

ALDN-046の実原本を読み取り専用で調査した。`/moov[1]/trak[3]/udta[1]/titl[1]`（offset 5,110,176）と`titl[2]`（offset 5,110,220）があり、各size=44、通常header=8、payload=36 bytes。payloadのhexは両方とも次のとおり。

```text
0000000055c4e697a5e69cace8aa9eefbc88537065656368416e616c797a6572efbc8900
```

version/flags=0、language=`und`、UTF-8「日本語（SpeechAnalyzer）」と終端NUL。atom境界・文字列表現の破損は認めなかった。trackのudta配置は[ETSI TS 126 244 V16.0.0 §8.2、表8.1](https://www.etsi.org/deliver/etsi_ts/126200_126299/126244/16.00.00_60/ts_126244v160000p.pdf)に認められる。一方、同一言語の重複は同節の言語ごとの個数制約には適合しない。ファイル全体を規格準拠と断定せず、「位置依存情報のない検証済みTitleを非対象データとして保持できる」と判断した。重複の統合・削除は修復対象に含めない。

修復で削除する専用chapter trackにtitlがある場合は、移動・削除なしに保持できないためblocked。全体構造の解析が失敗した場合は両領域をblockedとし、同じissuesに`details.scope=shared_structure`、`affected_areas=[metadata, quicktime]`、`diagnosis=incomplete`を付ける。検証済みtitlの拒否では実際の番号付きatom path、絶対offset、header込みsizeを伝播する。atom indexの生成自体に失敗した場合、確定していない座標は捏造しない。

同じ配置の合成fixtureでmetadataの不正index除去と欠落参照解除を合成し、公開APIの計画・適用・別出力保存・独立再読込を確認。movie/複数track/同一track内重複・拡張headerのraw保持、Nero、非対象metadata、mdatを比較した。UTF-8とBOM付きUTF-16BE、非対応version/flags/言語、不正終端・surrogate、size=0、対象track削除拒否、保存検証失敗時の原本保持を検証した。UTF-16内のNUL判定はbyte境界でなく16-bit符号単位で行い、隣り合う文字をまたぐ00 00の誤検出を解消した。

実原本の公開計画は変更後`unchanged`（metadata_complete / quicktime_absent）となり、今回の限定修復で除去する項目はなかった。`save!(to:)`で一時領域への無変更別出力と独立再読込を実行し、原本・出力SHA-256はともに`16ee7ee3a4c3b706823e486458aea15d3dc8bf22256123de4db111b4fe475c96`、titlの配置・個数・raw bytesも一致した。実原本に修復が発生したとの結果には扱わない。MListNewのblocked尊重・保存手順は変更不要で、gemの更新が必要。

判断とI/Oの評価は[ADR](../Docs/ADR/2026-10-21-track内の複数titlをraw保持する.md)、詳細な検証結果は[検証記録](Memos/2026-10-21-track内titlの調査と検証.md)を参照する。過去節にある未検証条件のうち、今回の対象ファイル・UTF-16BEの合成fixtureはここに記した範囲で検証済み。他OS/backendは未検証。

保持対応後の整理では、単一titl検証と一覧cache登録を分離し、contextを走査順のArrayで保持する。具体的なissuesを優先する診断補完も層ごとのprivate helperへ集約した。対応profile、公開診断、blocked条件、I/Oと保存契約は変更しない。
