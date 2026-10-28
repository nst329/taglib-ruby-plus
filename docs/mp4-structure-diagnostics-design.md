# MP4構造破損の読み取り専用診断

状態: 実装済み（初期範囲） / 2026-10-17、観測API追加 2026-10-28

## 目的と前提

MP4のatom境界、track識別、sample tableと媒体参照の整合性を、原本を書き換えず公開APIから診断する。chunk offset異常だけに限定しない。一方、全codecの復号・再生可否・媒体payloadの内容破損を保証する機能ではない。対象例の数値は利用者からの調査結果であり、本リポジトリで実ファイルを検証した値ではない。

「MP4構造全般」には、通常の非fragmented MP4の整合性検査と、fragmented・暗号化・外部参照を含む全形式検証の二つの解釈がある。本提案は前者を初期対象とし、後者は未検査範囲を明示して段階追加する。未対応を破損と判断しない。この範囲は実装開始前の確認事項とする。

## 現行実装の確認結果

- `lib/taglib/plus_mp4.rb`: `File#diagnose(area)`はmetadata、chapters、chapter_references、chapter_timing、colorに対応する。戻り値は深く不変な`{ status:, data:, issues: }`、issueは`code/message/location/details`。構造例外は`diagnostic_failure`で`data: nil`に変換され、detailsは空になる。I/O・プログラムエラーは正常reportへ変換しない。
- `lib/taglib/mp4_atom_parsing.rb`: headerだけをseek/readする再帰parser。32/64bit size、size=0、親境界、深さ16、atom数50,000を検査する。失敗は`MdtaSaveError`。境界エラーで全体が中断し、異常位置や部分indexは返らない。既知container以外のpayloadを再帰解析しない。
- `lib/taglib/mp4_chapter_references.rb`: `ChapterReferences`は診断と修復前検証を共有する。moov上限64 MiB、構造allowlist、自己完結drefなど保存向けの制限がある。`collect_offsets`はstco/co64のheader・件数を確認し、最初のmdat外offsetで`ChapterReferenceError(code: :malformed)`になる。複数trackの集計はしない。legacy経路では原本全体SHAや保持署名の取得も伴う。
- `lib/taglib/mp4_hint_validation.rb`: stsc/stsz/sttsとoffsetからsample配置を検証するが、hint向け制約・payload検証を含む。汎用診断からそのまま呼ぶと不要な制限とI/Oを持ち込む。
- `lib/taglib/plus_mp4_io.rb`: `Generation`が原本世代・atom境界indexを保持する。既定stat確認では全体hashなし、明示sha256では全bytesを読む。`File`生成自体はnative解析を要求しない。既存diagnoseの実行は`read_native`を経由する。

## 公開API案

```ruby
TagLib::Plus::MP4.open(path) do |file|
  report = file.diagnose(:structure)
end
```

`diagnose(:structure)`を新設し、既存のchapter参照診断からも同じ構造診断結果を利用する。新領域はnativeを開かずRubyの読み取り専用readerへ直接渡す。File生成自体は既に構造解析を要求しないため、当初は別のpath専用APIを増やさない。壊れたmoovでもこの入口へ到達できることを受入試験する。APIの整理を優先し、既存診断のissue codeや`data`形状を変更してよい。

新領域の`data`は部分結果を持てる。既存領域の`data`の意味は変更しない。

```ruby
{
  status: :malformed,
  data: {
    file_size: 713409974,
    mdat_ranges: [{ start: 32, end: 708502003 }], # 例。startは実測ではない
    coverage: [
      { check: :atom_boundaries, status: :complete },
      { check: :chunk_offsets, status: :complete },
      { check: :sample_extents, status: :complete }
    ]
  },
  issues: [{
    code: :chunk_offset_outside_mdat,
    message: 'chunk offset outside mdat',
    location: 'structure',
    details: {
      file_size: 713409974,
      mdat_ranges: [{ start: 32, end: 708502003 }],
      tracks: [{
        track_id: 1, handler: 'vide', track_index: 0,
        tables: [{
          type: 'stco', atom_offset: 0, # 実際は観測したtable位置
          declared_count: 108741, scanned_count: 108741,
          invalid_count: 13255, complete: true,
          first_invalid: { index: 95486, offset: 708502959 },
          last_invalid: { index: 108740, offset: 801208461 },
          max_offset: 801208461,
          max_referenced_end: 801209292
        }]
      }]
    }
  }]
}
```

例中のatom位置・mdat開始位置はschema説明用。indexは0始まり、mdat範囲はheaderを除くpayloadの`[start, end)`、endは排他的。最大参照終端はoffset最大値ではなく、各chunkの`offset + chunk内sample size合計`の最大値。stsc/stsz（またはstz2）が未対応・不正で計算できなければ`nil`とし、coverageに理由を残す。推測値を入れない。track ID欠損・重複時もtrack_indexとatom位置で区別し、track_id/handlerは観測不能ならnil。

## 観測API

`File#observation(areas = OBSERVATION_AREAS)`は、同一世代の読み取り専用観測を領域別status付きでまとめる。既定領域はmetadata、chapters、chapter_references、chapter_timing、chapter_samples、tracks。

```ruby
TagLib::Plus::MP4.open(path) do |file|
  observed = file.observation(%i[chapters metadata tracks])
  observed[:chapters][:status] # :complete / :absent / :malformed / :unsupported / :limit
  observed[:chapters][:value][:quicktime] # statusがcompleteでなければnil
end
```

各領域は`{status:, data:, issues:, value:}`を返す。malformed等は例外にせずstatusへ集約し、`source_changed`、`io`、`closed`、`pending_changes`だけを再送出する。未知・重複の領域名は`ArgumentError`。`diagnose`のcacheと世代を共有し、metadataは診断と完全snapshotを同じnative読込みで取得して以後の編集候補へ再利用する。未保存のchapter編集は観測へ反映せず、保存待ちのまま観測を求めた場合は`pending_changes`で拒否する。詳細は[ADR](adr/2026-10-28-同一世代の観測をstatus付きで返す.md)を参照する。

## 検査範囲と分類

| 検査 | 初期版で診断する内容 | 主なissue code案 |
| --- | --- | --- |
| atom境界 | header切断、拡張size切断、header未満size、親/EOF超過 | atom_header_truncated, atom_size_invalid, atom_outside_parent |
| movie/track | 必須構造の欠落・重複、tkhd ID 0/重複、handler読取不能 | required_atom_missing, duplicate_atom, invalid_track_id, duplicate_track_id |
| table形状 | fullbox version/flags、宣言数と実bytesの不一致、offset表重複 | table_header_invalid, table_count_mismatch, ambiguous_chunk_offset_tables |
| chunk開始 | stco/co64全entryと全mdat payload範囲、EOF超過 | chunk_offset_outside_mdat |
| sample配置 | stsc順序・chunk/sample割当・description index、stsz、stts数の整合 | sample_mapping_invalid, sample_count_mismatch |
| chunk終端 | sample size合計による終端の同一mdat内収容 | chunk_extent_outside_mdat |
| track参照 | 存在しないtrack ID、重複IDで解決不能 | track_reference_missing, track_reference_ambiguous |

正常な空table/空trackを一律破損としない。必須条件はtrack形式・非fragmented/fragmentedの文脈ごとに定義する。durationの単純不一致はeditや丸めでも生じるため、それだけで破損扱いしない。既存chapter_timing診断のprofile判断を一般化しない。

stz2、fragmented (`moof/mvex`)、暗号化、外部drefは初期版では該当checkをunsupportedとする。未知atomは、境界を検証してpayloadをskipし、存在だけで破損とはしない。未知atom内部は検査対象外と明記する。外部dref trackのoffsetをローカルmdatと比較して誤検出しない。fragmented構造でも安全に確認できるatom境界異常は報告する。

`coverage`各行はcheck、status（complete/unsupported/limit/blocked）、必要時reasonとtrack_indexを持つ。completeは当該checkを完走した意味で、破損なしとは限らない。blockedは前提構造の破損等で未実施。report全体は、確認済み破損ありならmalformed、なければ予算超過でlimit、なければ未対応/blockedでunsupported、すべて完走ならcomplete。新領域ではcode文字列からstatusを推測せず、内部の検出分類から集約する。既存領域の優先順位は変更しない。

## 解析と安全な継続

1. 原本をrbで開き、世代とサイズを確認する。ルートheaderを一巡してmdat範囲とmoov位置を得る。mdat payloadはseekで飛ばす。
2. 信頼できる親境界の内側で既知containerを走査する。壊れた子の次位置を計算できなければ、その親の残りをblockedとする。親の終端が確実なら親の次の兄弟へ進める。`moov`などの文字列を媒体bytesから探索して再同期しない。
3. track headerとtable headerを取得する。countから必要bytesをchecked arithmeticで算出し、残りpayloadと予算を確認してから走査する。欠落・重複を記録し、依存しないtrack/tableは継続する。
4. stco/co64を固定サイズblockで逐次走査し、全trackを集計する。複数表の存在自体もissueとし、各表を別atom位置で報告する。表の選択や修復はしない。
5. 検証済みstscとsample sizeからchunkの終端を算出する。固定stszをsample数分の配列へ展開せず、可変stszはblock読取する。sample payloadは読まない。sttsはrunの件数合計を照合し、sample単位へ展開しない。chunk番号は昇順に処理し、正しい単調増加のstsc mappingでは現在行のindexを一度だけ進める。これにより探索は`O(chunks + stsc_rows)`となる。不正・非単調mappingは適用イベントを前処理して従来の結果を再現し、chunkごとの全行走査を避ける。
6. 世代を再確認して不変reportを返す。原本が変化していたら部分reportを成功として返さず、既存source_changed契約で失敗する。

新readerの内部観測結果は保存・修復用の「検証済みindex」と分離する。既存parserを寛容に変えたり、部分indexをGenerationの既存atom_indexへ入れたりしない。境界演算など小さな共通処理のみ共有し、writerの厳格な拒否を維持する。

## API変更方針

互換性より診断結果の一貫性を優先する。`file.diagnose(:chapter_references)`がchunk offset異常を検出した場合は、`status: :malformed`を維持してもよいが、`data`には構造診断の部分結果を返し、issue codeは`:chunk_offset_outside_mdat`へ具体化する。`message`と`location`も構造診断と統一する。既存の`ChapterReferenceError`を公開契約として残す必要はなく、診断では例外をreportへ集約してよい。

`chapter_references`はchapter参照の論理診断、`structure`はMP4全体の物理構造診断として責務を分ける。ただし内部では同じ`StructureDiagnostics`の観測結果を共有し、stco/co64を二重走査しない。既存利用者向けの旧形式変換層は実装しない。MListNew側は新schemaへ移行する。

metadata・chapters・colorなど他の領域も、構造破損が前提条件を壊している場合は構造診断のissueを直接返してよい。`data: nil`へ機械的に縮退させず、確認できた範囲を返す。I/O障害、source_changed、実装バグは引き続き例外とし、破損reportへ変換しない。

## 集計上限とI/O

予算は解析呼出し全体で共有する。初期提案値は深さ16、atom数50,000、table総読込64 MiB、table総entry走査4,000,000、issue最大256件。blockは64 KiBを上限とする。値は実装時のfixture/I/O計測で調整し、公開契約として固定する前に確認する。sample対応の演算数もentry予算へ含め、悪意あるstscで無制限loopを作らない。

不正entryは全件保存せず、tableごとにcount・first・last・maxを保持する。上限到達時のcount/maxは走査済み範囲のみで、complete=false、scanned_count、打切り理由を必須にする。issue件数上限で捨てた診断は件数とcoverageに集約し、正常と見せない。

通常経路の読込対象はatom header（原則8/16 bytesずつ）、track識別の必要部分、stco/co64、stsc、stsz、stts、必要なstsd/dref headerだけ。媒体サイズに比例する読込・コピー・digestは追加しない。moovの全bytesコピーも不要。表の読込はおおむね`ceil(table bytes / 64 KiB)`回＋header。mdat範囲は一度収集して再利用し、CPU側は範囲探索で対応する。stscのchunk対応は全行逆走査を繰り返さず、通常経路で`O(chunks + stsc_rows)`とする。

同一File世代内で新診断の不変結果を再利用し、保存・reload時は既存世代管理に合わせて無効化する。既存chapter診断からの詳細集計と新領域で同じ結果を再利用する。正常chapter診断には全構造診断を追加しない。異常時のstrict検査済みprefix再読込は初期版では許容し、その範囲を計測する。巨大tableの永続配列cacheは作らない。

既定stat確認は全体hashを行わず、同一statを偽装する外部変更まで保証しない。明示sha256の全体走査契約は維持する。上記I/O削減は設計上の見込みで未計測。選択理由とトレードオフは[ADR](../Docs/ADR/2026-10-17-MP4構造診断を読み取り専用で分離する.md)に記す。

## 受入試験と段階導入

1. 共通境界観測器と新領域。正常MP4はissues空、atom切断・不正size・親/EOF超過は位置/期待/観測値つき。壊れた入力でもnativeを呼ばず到達できることを確認する。
2. stco/co64集計とsample配置。複数track、複数mdat、mdat header/隙間/endちょうど/EOF外、開始は正常で終端だけ外、64bit offset、壊れたstsc/stsz、固定sample sizeを試験する。first/last/maxを独立計算した期待値で検証する。
3. chapter参照診断への構造結果統合。旧code/message/`data: nil`の維持は要求せず、新schemaのtrack別detailsと部分dataを検証する。chapter・metadata・colorの新しい構造破損経路を試験する。
4. ID・参照整合性と未対応coverage。重複IDでもtrackを混同しないこと、未知atom/外部参照/fragmentedを誤って破損扱いしないことを確認する。
5. 予算・原本不変・I/O。fixtureのbytes/size/mtimeを前後比較する。試験用hashは製品診断のI/Oと分離する。read/seek計測でmdat payload未読、全体hashなし、block上限、再診断cache、世代変更時拒否を確認する。sparse fixtureで4 GiB超のco64と巨大mdatを検証する。小fixture成功を実媒体検証とみなさない。

実装後は対象Test::Unit、関連回帰、変更Rubyの`ruby -c`、`git diff --check`を実行する。本変更は設計文書のみなので、実装テストの成功は主張しない。

MListNewは新schemaへ移行し、旧独自診断との比較期間を設ける。limit/unsupported/blockedやmax_referenced_end=nilを「正常」と解釈しない。診断結果からoffset補正・原本保存へ自動接続しない。
