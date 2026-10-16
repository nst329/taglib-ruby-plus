# taglib-ruby-plus独自APIの再設計

日付: 2026-10-16
状態: 初版実装済み。診断・通常編集・保存の基本契約を検証済み。

## 方針

独自APIの入口を`TagLib::Plus::MP4.open`にまとめ、利用者は編集用Fileと不変のmetadata/chapter値を扱う。保存は`save!`だけにする。Update、SavePlan、RepairUpdate、Reportの公開クラスは設けない。

互換性は前提としない。元のtaglib-ruby由来のラッパーは別の低水準層として残し、独自APIを`TagLib::Plus::MP4`に分離する。旧fork追加メソッドや互換aliasは削除する。対象は現在のMP4独自機能で、他形式へ一般化しない。

前案のDocument → Update → SavePlanは、更新の受渡しと検証を明確にできた一方、通常操作にも内部transactionの概念を要求した。これらは内部責務として維持し、公開の利用モデルを「読む・編集する・保存する」にする。

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

別ファイルへの出力は`file.save!(to: output_path)`。snapshotの復元も、別Documentの値を代入するだけにする。

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
| `file.metadata` / `metadata=` | 現在の編集候補を読む／metadata全体の復元候補を代入する |
| `file.chapters` / `chapters=` | 形式別の現在の編集候補を読む／全形式の復元候補を代入する |
| `file.changes` | 元世代と現在候補の差分・修復対象を不変Hashで返す |
| `file.save!(to: nil)` | 検証後に原本置換。to指定時は既存出力を上書きせず別出力を作る |
| `file.diagnose(area)` | 原本の指定領域一つを、不変Hashで診断する |
| `file.chapter_samples` | 原本の全chapter sampleの観測値。不在はnil |
| `file.detach_chapter_references(references:)` | 診断で明示したchap関係だけの解除を保存待ちにする |
| `file.repair_chapter_timing(track_id:, profile:)` | 一致する既知profileの時間修復だけを保存待ちにする |
| `file.close` | 未保存編集を破棄して資源を解放。繰返しは無操作 |

tag、item_map、native handle、save_chapters、save_preserving_*を新APIに公開しない。metadata/chapter形式別managerや、変更を自動保存するブロックDSLも設けない。

## 読取と編集の状態

Fileは一つの原本世代と、そこから作った編集候補を所有する。metadata/chapters getterは常に現在候補を返す。未編集なら原本値と同じであり、編集後に突然原本値へ戻らない。取得済みの値は後の編集・save・closeで変化しない。

原本世代の完全読取ができない領域は、空値で代用せず例外にする。遅延読取を認め、metadataだけの参照に章の完全読取を無条件に要求しない。保存に必要な保持検査は別途行い、安全を証明できなければ保存を拒否する。

`diagnose`と`chapter_samples`は保存済み原本の観測だけを扱う。章編集が保留中のchapter_samplesは、候補のsampleと誤認させないよう拒否する。metadata編集だけなら原本sampleを観測できる。診断結果へpending候補の情報を混ぜない。

原本の外部変更を検出したら、cache済み候補の返却も含めて操作を拒否する。mtime/sizeだけで世代同一性を証明しない。再openしてやり直し、暗黙reload・自動merge・自動再試行はしない。

原本へのsave成功後は、保存前に独立再読込・検証した出力値とdigestを新baselineとして採用し、保留編集を空にする。Fileはnative handleを長期保持せず、公開後のnative再openを必要としない構成にする。これにより同じFileで次の編集ができる。返却値や原本への書込成功後に問題が起きた場合はcommitted=trueを通知し、そのFileを使用不可にして再openを求める。

別出力へのsave成功後は原本とbaselineを変えず、編集候補も維持する。候補はまだ原本に適用されていないためである。続けて原本にも保存したり、別の新規出力を作れる。closeで破棄する。別出力をFileの新しい原本へ暗黙に切り替えない。

## metadata値と編集

MetadataSnapshotは`items`、`mdta`、`properties`、`artworks`を持つ不変値とする。通常itemは名前付きMetadataItem、mdtaはMdtaValue、画像はArtwork、ratingはContentRatingで表現する。位置依存の行配列は公開しない。値はnativeなしで構築・比較でき、ネストしたString/Array/Hashまで所有コピー・freezeする。

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

診断領域はmetadata、chapters、chapter_references、chapter_timing、color。各戻り値は`{ status:, data:, issues: }`。statusはcomplete/unsupported/malformed/limit、issueはcode/message/location/detailsを持つ不変Hash。対象不在はcompleteと空配列/nil。Report.sectionsという外側の階層と専用Issueクラスは削除する。I/O障害・プログラミングエラーを空の診断へ変換しない。

参照解除は診断元世代と位置・ID・観測値を再検証する。欠落だけを解除する場合も利用側がstatusで選択する。トラックやmediaは削除しない。空選択は無操作。時間修復はprofile必須とし、不一致を明示的に拒否する。

修復はraw構造の操作であり、通常snapshotの候補へ混ぜない。修復保留中に使える入口はchanges、diagnose、save!、closeだけとし、論理値やsampleの取得・代入は拒否する。原本への保存成功後は通常の読取・編集へ戻る。

通常編集と修復、および異なる修復は混在禁止。同じFileで逆順に操作しても、後の操作を部分適用せず拒否する。保存してから次の操作へ進む。原本保存後の古い診断行は使えない。saveのために同じ修復を再呼出しする必要はない。

## 変更確認と保存

changesは値の差分と、正規化でclearするmdta・解除する参照など実効的な対象を返す。binary/画像はサイズ・digestへ縮約する。実行可能な計画ではなく、writerの可否や保存成功の証明でもない。

save!は内部で入力全体とwriter可否を検証し、候補作成 → 別handle再読込 → 値・構造・media保持照合 → 原本/digest再確認 → 原子的公開を行う。writerの経路は利用者に選ばせず、特殊metadata保持や限定atom編集を内部で扱う。safeを既定optionにするのではなく、unsafe/force/skip_verify自体を提供しない。

原本への変更なしsaveは置換しない。別出力の変更なしsaveは単純コピーとし全bytesのdigest一致を要求する。別出力は原本自身、既存出力、同一inode、symlinkを拒否し、公開直前の競合でも上書きしない。exists?→renameだけで保証したことにしない。

戻り値は不変Hashの`{ output_path:, changed:, source_digest:, output_digest:, verification: }`。SaveResultクラスは作らない。原本保存でwriterが残した空キー等は、検証済みの実出力値を新baselineにする。値比較は厳密な==を基本とし、明示的にclearしたキーだけ空残存を許可する。公開snapshotの一致だけで全保持の成功とはしない。

失敗時に原本未変更なら編集候補を保持し、障害解消後にsave!を再試行できる。cleanup失敗は一時pathと元の失敗をcauseに残す。公開済みの失敗ではcommitted=trueとして自動再試行しない。外部writerとの完全排他・電源断耐性・ACL等の完全保持まで新しく保証するものではない。

## 例外と比較

入力不正はArgumentError。ファイル由来の未対応・不正・世代不一致・保存失敗は共通の`MP4::Error`とし、code/area/phase/committed/output_path/temporary_path/issuesで判別する。用途ごとの6種類の公開例外階層は作らない。ClosedError相当はcode=:closed、世代不一致は:source_changed、混在は禁止理由に応じたcodeを持つ。保存前のcode=:source_changedはcommitted=false。I/O失敗はcauseを保持し、プログラミングエラーを一律にunsupportedへ変換しない。

MetadataSnapshotの==/eql?/hashは型・locale・順序・重複・空キーの存在を含む値の厳密比較。取得元配置・raw情報は別である。diff(other)も同じ厳密値基準とし、比較modeや同義aliasを公開しない。別ファイルへの復元で空keysの残存を許すのは保存検証の責務にする。

ChapterSnapshotは両形式のms/title/順序を完全比較。ChapterSamplesはticks、source_references、payload署名、時刻写像の照合可否を観測情報として保持し、論理章やbytesの一致と混同しない。公開の任意比較policyや汎用Diff階層は作らない。

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

## 実装と検証の範囲

初版は`lib/taglib/plus_mp4.rb`に実装した。`TagLib::Plus::MP4.open`、不変metadata/chapter値、`changes`、`diagnose`、明示的なchapter参照・時間修復、世代検査付き`save!`を提供する。native Fileは操作間だけ開き、保存候補は一時ファイルを独立再読込してから公開する。

利用テストは[plus_mp4_api_test.rb](../test/plus_mp4_api_test.rb)に置き、別出力後の候補維持、原本置換後の継続、stale source拒否、close/既存出力拒否、typed mdtaの所有コピーを確認する。前案の[設計probe](Memos/2026-10-16-Plus独自API設計のテスト検証.md)は、旧Document/Update/SavePlan案の履歴として残す。

初版ではcolor/chapter sampleの戻り値を既存診断値へ委譲している。名前付きitemの全編集形式、保存後失敗の強制再現、実ファイルの映像デコード検証は後続受入条件とする。

実装前に簡素化案の利用テストを作り、特にsetterの全入力検証、編集後getter、失敗後の候補保持、原本保存後の継続、別出力後の候補維持、逆順での修復混在拒否を確認する。既存のpurl/context/未index mdta/hint/offset補正と媒体保持の受入条件も維持する。

世代固定の遅延capture/cache、協調writerの排他、非上書き公開のOS差異は実装時の検討事項。公開クラスを先に増やして解決しない。JSON永続化や計画のシリアライズ、汎用plugin writerは初版に含めない。

[簡素化ADR](ADR/2026-10-16-Plus独自APIを編集セッションへ簡素化.md)・[前案のADR](ADR/2026-10-16-Plus独自APIをDocumentと保存計画へ集約.md)
