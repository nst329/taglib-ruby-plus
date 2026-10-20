# taglib-ruby-plus独自APIの再設計

日付: 2026-10-16
状態: 初版実装済み。診断・通常編集・保存の基本契約を検証済み。

## 方針

世代確認・cache・保存のI/O予算とdigest返却契約は[MP4公開APIのI/O設計](mp4-public-io-design.md)を参照する。通常はstat世代確認、内容照合が必要な場合は `MP4.open(path, verification: :sha256)` を明示する。

独自APIの入口を`TagLib::Plus::MP4.open`にまとめ、利用者は編集用Fileと不変のmetadata/chapter値を扱う。保存は`save!`だけにする。Update、SavePlan、RepairUpdate、Reportの公開クラスは設けない。

互換性は前提としない。元のtaglib-ruby由来のラッパーは別の低水準層として残し、独自APIを`TagLib::Plus::MP4`に分離する。旧fork追加メソッドは通常のFile/Tagではprivateにし、`TagLib::MP4::Internal::File`だけがwriter用に利用する。内部の値クラス・エラー・native変換も公開契約に含めず、互換aliasは設けない。元から存在する`save`/`tag`/`title`等の低水準操作は維持する。対象は現在のMP4独自機能で、他形式へ一般化しない。

前案のDocument → Update → SavePlanは、更新の受渡しと検証を明確にできた一方、通常操作にも内部transactionの概念を要求した。これらは内部責務として維持し、公開の利用モデルを「読む・編集する・保存する」にする。

[header情報と保存snapshotの再利用](mp4-header-info-design.md)に、選択式info、未読baselineへの置換予定、検証済み出力snapshotの追加契約を記録する。

## 基本の使い方

```ruby
require 'taglib_plus'
MP4 = TagLib::Plus::MP4

MP4.open(path) do |file|
  file.metadata = file.metadata.with(properties: { title: '新しい題名' })
  puts file.changes
  file.save!
end
```

`with`は元の値を変えず、新しい不変値を返す。Fileへの代入はメモリ上の編集だけ。`save!`が明示的なディスク書込で、ブロック終了はcloseだけを行う。

別ファイルへの出力は`file.save!(to: output_path)`。snapshotの復元も、別Fileから取得した値を代入するだけにする。

```ruby
metadata = MP4.open(source) { |file| file.metadata }
MP4.open(destination) do |file|
  file.metadata = metadata
  file.save!
end
```

## 公開入口

| API | 契約 |
| --- | --- |
| `MP4.open(path) { ... }` | Fileを所有し、ブロック終了時にclose。ブロック値を返す |
| `MP4.open(path)` | Fileを返す。利用者がcloseする |
| `file.info(sections: [:movie, :tracks])` | 原本の選択したheader宣言を不変snapshotで返す。sample・native・外部probeを起動しない |
| `file.metadata` / `metadata=` | 現在の編集候補を読む／metadata全体の復元候補を代入する |
| `file.chapters` / `chapters=` | 形式別の現在の編集候補を読む／全形式の復元候補を代入する |
| `file.changes` | 元世代と現在候補の差分・修復対象を不変Hashで返す |
| `file.save!(to: nil, snapshots: [])` | 検証後に原本置換。to指定時は既存出力を上書きせず別出力を作る |
| `file.diagnose(area)` | 原本の指定領域一つを、不変Hashで診断する |
| `file.chapter_samples` | 原本の全chapter sampleの観測値。不在はnil |
| `file.detach_chapter_references(references:)` | 診断で明示したchap関係だけの解除を保存待ちにする |
| `file.repair_chapter_timing(track_id:, profile:)` | 一致する既知profileの時間修復だけを保存待ちにする |
| `file.plan_limited_repairs(mdta_layout: nil)` | metadataとQuickTimeを独立診断し、必要な限定修復の不変計画を返す |
| `file.apply_limited_repairs(plan:, allow:)` | 同じFileの最新計画を、必要操作すべての許可を確認して登録する。保存は別出力のみ |
| `file.close` | 未保存編集を破棄して資源を解放。繰返しは無操作 |

tag、item_map、native handle、save_chapters、save_preserving_*を新APIに公開しない。metadata/chapter形式別managerや、変更を自動保存するブロックDSLも設けない。

## 読取と編集の状態

Fileは一つの原本世代と、そこから作った編集候補を所有する。metadata/chapters getterは常に現在候補を返す。未編集なら原本値と同じであり、編集後に突然原本値へ戻らない。取得済みの値は後の編集・save・closeで変化しない。

原本世代の完全読取ができない領域は、空値で代用せず例外にする。遅延読取を認め、metadataだけの参照に章の完全読取を無条件に要求しない。保存に必要な保持検査は別途行い、安全を証明できなければ保存を拒否する。

`diagnose`と`chapter_samples`は保存済み原本の観測だけを扱う。章編集が保留中のchapter_samplesは、候補のsampleと誤認させないよう拒否する。metadata編集だけなら原本sampleを観測できる。診断結果へpending候補の情報を混ぜない。

原本の外部変更を検出したら、cache済み候補の返却も含めて操作を拒否する。通常はpathと所有handleのdev/ino/size/mtime/ctimeを照合し、内容SHAによる保証と区別する。厳密モードは内容SHA照合を追加する。再openしてやり直し、暗黙reload・自動merge・自動再試行はしない。

原本へのsave成功後は、保存前に独立再読込・検証した出力値とdigestを新baselineとして採用し、保留編集を空にする。Fileはnative handleを長期保持せず、公開後のnative再openを行わない。公開前に独立再読込したsnapshotとdigestだけを採用する。これにより同じFileで次の編集ができる。返却値や原本への書込成功後に問題が起きた場合はcommitted=trueを通知し、そのFileはclose以外の読取・編集・診断・保存すべてを拒否し、再openを求める。別出力への保存後に失敗した場合も同じとする。

別出力へのsave成功後は原本とbaselineを変えず、編集候補も維持する。候補はまだ原本に適用されていないためである。続けて原本にも保存したり、別の新規出力を作れる。closeで破棄する。別出力をFileの新しい原本へ暗黙に切り替えない。

## metadata値と編集

`MetadataSnapshot.new(items: [...], mdta: {...})`でnativeなしに構築できる。MetadataSnapshotは`items`、`mdta`、`properties`、`artworks`を持つ不変値とする。通常itemは名前付きMetadataItem、mdtaはMdtaValue、画像は`MP4::Artwork`、ratingは`MP4::ContentRating`で表現する。位置依存の行配列は公開しない。値はnativeなしで構築・比較でき、可変入力を所有コピーし、ネストしたArray/Hashまでfreezeする。凍結済みStringは共有でき、大きいartworkのbytesと未変更itemはwith/withoutで再利用する。

```ruby
metadata = file.metadata
metadata.properties[:title] # 複数値を保持するArray。キー不在はnil。

file.metadata = metadata.with(properties: { title: '題名', tv_show: '番組' })
file.metadata = file.metadata.without(properties: [:comment])
file.metadata = file.metadata.with(mdta: {
  'custom' => [MP4::MdtaValue.new(data_type: 1, locale: 0, data: 'value'.b)]
})
```

編集用の入口は`with(properties: {}, items: {}, mdta: {})`と`without(properties: [], items: [])`だけにする。withは指定項目だけを置換し、未指定を維持する。withoutは指定property/通常itemを削除する。全体復元はFileへの代入で表す。

property名はsnake_caseのSymbolに統一する。対応名はtitle、artist、album、genre、comment、copyright、description、long_description、grouping、tv_show、tv_episode、keyword、podcast_url、year、purchase_date、content_rating。別名は設けない。入力はString、content_ratingだけContentRating。yearも文字列であり推定変換しない。空文字は空値、nilは不正、削除はwithoutを使う。複数値の設定は型付きitemsを使う。

property更新は対応する通常itemを正本にし、対応mdtaの値を全てclearする。title/artist/description/tv_showが対象で、未知型・locale別・重複も含む。copyrightは©cpyだけ。items/mdtaの直接編集ではこの正規化を行わない。

一回のwith/withoutで同じatomやmdtaキーへ競合する指定は拒否する。入力全体を検証し、後半が不正でも既存値やFileを変えない。別々の代入では利用者が順番を明示しているため、現在候補へ順に適用する。公開のUpdate.mergeや汎用的な競合解決機構は作らない。

mdtaは`Hash<String, Array<MdtaValue>>`。不在はnil、空キーは[]、空payloadは値1件のdataが空bytesである。with(mdta: { 'key' => [] })は既存キーの値をclearし、不在キーなら追加しない。物理keys削除は公開操作にしない。ファイルから取得した空キーは、手動構築や全体復元で不在のキーと区別する。

取得元のcontext・keys/index・raw purl等の情報は読み取り専用の付帯情報として保持する。物理配置の編集や復元先indexの指定は認めない。関連値を変えた場合は古いraw情報を失効させ、writerが安全に生成できなければ保存を拒否する。手動構築値からraw bytesを推定しない。曖昧な複数contextをHashへ黙って縮約しない。

## chapter値と編集

```ruby
chapter = MP4::Chapter.new(start_ms: 0, title: '開始')
file.chapters = file.chapters.with(nero: [chapter])
file.chapters = file.chapters.with(nero: []) # Neroだけ削除。QuickTimeは維持。
```

ChapterSnapshotはnero/quicktimeの不変Chapter配列を持つ。withの指定形式だけを置換し、省略は維持、[]は削除。:preserve/:any/:bothは設けない。両方を更新するときは両方を書く。異なる両形式を勝手に一致させない。

論理章、sample観測、章参照の解除は別の責務である。映像からtextへのchapを診断・sample観測できても、論理chapter書込へ無条件に拡張しない。sampleのticks/padding・参照順序を維持し、sampleのrestore APIは作らない。

## 診断と修復

```ruby
report = file.diagnose(:chapter_references)
references = report.fetch(:data).fetch(:references)
selected = references.select { |row| row[:status] == :missing }
file.detach_chapter_references(references: selected)
puts file.changes
file.save!
```

診断領域はmetadata、chapters、chapter_references、chapter_timing、color、structure。各戻り値は`{ status:, data:, issues: }`。statusはcomplete/unsupported/malformed/limit、issueはcode/message/location/detailsを持つ不変Hash。structureはatom境界、track、stco/co64、sample配置、mdat範囲を読み取り専用で診断し、確認済みの部分dataを返す。対象不在はcompleteと空配列/nil。Report.sectionsという外側の階層と専用Issueクラスは削除する。I/O障害・プログラミングエラーを空の診断へ変換しない。

参照解除は診断元世代と位置・ID・観測値を再検証する。欠落だけを解除する場合も利用側がstatusで選択する。トラックやmediaは削除しない。空選択は無操作。時間修復はprofile必須とし、不一致を明示的に拒否する。

修復はraw構造の操作であり、通常snapshotの候補へ混ぜない。修復保留中に使える入口はchanges、diagnose、save!、closeだけとし、論理値やsampleの取得・代入は拒否する。原本への保存成功後は通常の読取・編集へ戻る。

通常編集と修復、および異なる修復は混在禁止。同じFileで逆順に操作しても、後の操作を部分適用せず拒否する。保存してから次の操作へ進む。原本保存後の古い診断行は使えない。saveのために同じ修復を再呼出しする必要はない。

## 変更確認と保存

changesは取得済みbaselineとの値の差分と、正規化でclearするmdta・解除する参照など実効的な対象を返す。binary/画像はサイズ・digestへ縮約する。未読baselineへの完全代入は値一致が不明なため置換予定とし、無変更判定だけのために旧値を読まない。実行可能な計画ではなく、writerの可否や保存成功の証明でもない。

save!は内部で入力全体とwriter可否を検証し、候補作成 → 別handle再読込 → 値・構造・media保持照合 → モードに応じた原本世代再確認 → 原子的公開を行う。writerの経路は利用者に選ばせず、特殊metadata保持や限定atom編集を内部で扱う。safeを既定optionにするのではなく、unsafe/force/skip_verify自体を提供しない。

原本への変更なしsaveは置換しない。別出力の変更なしsaveはコピー時の原本全bytes署名と、出力の独立再読取の署名一致を要求する。通常モードの同一path無変更saveは全体hashを行わず、未計算のdigestはnilを返す。verificationはこの場合statまたはsha256、それ以外の出力保存はindependent_reopen。別出力は原本自身、既存出力、同一inode、symlinkを拒否し、公開直前の競合でも上書きしない。exists?→renameだけで保証したことにしない。

戻り値は不変Hashの`{ output_path:, changed:, source_digest:, output_digest:, verification:, snapshots: }`。SaveResultクラスは作らない。snapshotsは保存候補から独立再読込した値だけを含み、変更保存のmetadataを常に返す。chapterは変更時または明示選択時だけ読む。期待値で未読領域を埋めない。原本保存でwriterが残した空キー等は、検証済みの実出力値を新baselineにする。値比較は厳密な==を基本とし、明示的にclearしたキーだけ空残存を許可する。公開snapshotの一致だけで全保持の成功とはしない。

失敗時に原本未変更なら編集候補を保持し、障害解消後にsave!を再試行できる。cleanup失敗は一時pathと元の失敗をcauseに残す。公開済みの失敗ではcommitted=trueとして自動再試行しない。外部writerとの完全排他・電源断耐性・ACL等の完全保持まで新しく保証するものではない。

## 例外と比較

入力不正はArgumentError。ファイル由来の未対応・不正・世代不一致・保存失敗は共通の`MP4::Error`とし、code/area/phase/committed/output_path/temporary_path/issuesで判別する。用途ごとの6種類の公開例外階層は作らない。ClosedError相当はcode=:closed、世代不一致は:source_changed、混在は禁止理由に応じたcodeを持つ。保存前のcode=:source_changedはcommitted=false。I/O失敗はcauseを保持し、プログラミングエラーを一律にunsupportedへ変換しない。

MetadataSnapshotの==/eql?/hashは型・locale・順序・重複・空キーの存在を含む値の厳密比較。取得元配置・raw情報は別である。diff(other)も同じ厳密値基準とし、比較modeや同義aliasを公開しない。別ファイルへの復元で空keysの残存を許すのは保存検証の責務にする。

ChapterSnapshotは両形式のms/title/順序を完全比較。`chapter_samples`はnilまたは固定キーの不変Hashであり、旧snapshotオブジェクトを返さない。ticks、source_references、payload署名、時刻写像の照合可否を観測情報として保持し、論理章やbytesの一致と混同しない。公開の任意比較policyや汎用Diff階層は作らない。

## 前案から減らすもの

| 前案 | 簡素化案 |
| --- | --- |
| 保存済みDocumentとclose後も使えるSavePlan | 編集用File。一時的な保存計画は内部だけ |
| MetadataUpdate/ChapterUpdate/RepairUpdateとmerge/apply | 不変snapshotのwith/without、Fileへの代入、明示的修復メソッド |
| plan.preview、plan.commit!、plan.write_to! | file.changes、file.save!(to:) |
| 保存後にDocumentを捨ててopenし直す | 原本保存成功後は検証済み出力をbaselineとして継続 |
| Report.sections/Issue/SaveResult | 固定schemaの不変Hash |
| 境界別の複数例外・比較mode | 共通Errorのcode/phaseと厳密比較 |

名前付きitem/mdta値や各snapshotまでHash一つに潰さない。型・単位・復元能力の違いを保つことには実益がある。一方、操作要求と内部保存計画を独立した公開値にする理由は、通常利用に対して薄い。

## 診断とsampleの固定schema

全領域が`{ status:, data:, issues: }`を返す。statusは`:complete`、`:unsupported`、`:malformed`、`:limit`。
issueは`{ code:, message:, location:, details: }`。既知の構造拒否だけを診断へ変換し、I/O障害はcause付きError、プログラミングエラーは元の例外を通知する。読取不能で観測値を作れない場合のdataはnil。

| 領域 | data |
| --- | --- |
| metadata | `{ structure:, capabilities: }` |
| chapters | `{ formats: { nero: { status:, reason: }, quicktime: { status:, reason: } } }` |
| chapter_references | `{ references: [...] }` |
| chapter_timing | `{ tracks: [...] }` |
| color | `{ entries: [...] }` |

領域固有の観測値は保持する。chaptersの不在形式は`:absent`だが、診断全体は`:complete`。
colorはvideo entryとcolrの拒否も集約する。非video entryは色診断の対象外で、観測値として保持する。

chapter_samplesのキーは`track_id`、`source_track_id`、`media_timescale`、`media_duration`、`samples`、`movie`、`edit`、`preservation_signature`、`ffprobe_comparison`、`source_references`、`signature_version`。
samplesのticksとpayload署名を保持し、close後も参照できる。pending章編集・修復中は拒否する。

## 保存失敗時の状態

| 失敗点 | committed | 原本・出力 | セッション |
| --- | --- | --- | --- |
| 候補生成・検証・公開前の競合 | false | 原本を維持。競合出力も上書きしない | 候補を維持し再試行可 |
| 公開後のbaseline採用・結果生成 | true | 検証済み出力は公開済み | close以外を拒否 |
| 一時ファイル削除 | 公開済みかを反映 | 原本・出力の公開状態を維持 | 公開済みならclose以外を拒否 |

cleanup失敗はmessageに削除エラー、temporary_pathに対象を残す。先行エラーがあればcauseとして保持し、さらに元の失敗原因まで辿れる。公開後の失敗は自動再試行しない。

## 実装・検証済みと残る制限

実装は`lib/taglib/plus_mp4.rb`、旧操作の公開境界は`lib/taglib/mp4_internal.rb`に置く。
セッション状態と原本世代の確認は共通化し、metadata・chapterともbaselineと候補を同じ不変値で比較する。[状態確認と比較の簡素化ADR](ADR/2026-10-16-Plus編集状態の確認と比較を簡素化.md)に判断を記録する。
metadataとchaptersは遅延読取し、完全snapshotを取得できないファイルも診断できる。
受入テストは[plus_mp4_api_test.rb](../test/plus_mp4_api_test.rb)で、公開境界、型付き値、通常保存、保存前後の障害、cleanupの原因連鎖、公開競合、再試行と再利用拒否、診断schema、sample値の所有を確認する。
既存の構造・保持テストは内部Fileを使い、purl/context/未index mdta/hint/offset補正の検証を維持する。

映像からtextへのchapは診断・sample観測・明示的参照解除の範囲に限り、論理章snapshotの制約を緩和しない。
原本世代の完全排他、symlinkを含む出力親ディレクトリの外部変更、電源断耐性、ACL等の完全保持、実ファイルの全映像デコードは保証しない。
名前付きitemの全編集形式と、特殊metadata保持を新API経由で網羅する受入検証は残る。
旧未index mdta専用の保存操作は内部専用で、新APIで完全snapshotを取得できないmetadataの編集を許さない。
JSON永続化、任意のsample復元、計画シリアライズ、汎用plugin writerは対象外。

前案の[設計probe](Memos/2026-10-16-Plus独自API設計のテスト検証.md)は履歴であり現行APIの受入結果には数えない。

[公開境界・保存失敗・診断ADR](ADR/2026-10-16-Plus公開境界と保存失敗状態と診断schemaの確定.md)・[簡素化ADR](ADR/2026-10-16-Plus独自APIを編集セッションへ簡素化.md)・[前案ADR](ADR/2026-10-16-Plus独自APIをDocumentと保存計画へ集約.md)

## 不正mdta indexとQuickTimeの併用修復

[併用修復仕様](mp4-combined-limited-repair-design.md)を参照する。限定profile内の不正index item除去と専用chapter除去は同じ原本座標の一つの計画へ合成し、通常snapshot編集や他repairと混在させない。修復前に完全metadata snapshotを要求せず、対象外raw bytes、Nero、track、media、出力digestを独立検証する。正常itemのnative非対応値をraw保持できても、明示要求した完全snapshotを取得できなければ保存は拒否する。
