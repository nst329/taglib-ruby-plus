Changes in Releases of taglib-ruby-plus
=======================================

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
Releases generally follow [Semantic Versioning](http://semver.org/spec/v2.0.0.html);
four-component RubyGems versions are used when identifying a downstream
revision of a specific TagLib release.

## 2.3.2.44

### Fixed

- macOSのsymlink解決と相対パス絶対化でPOSIX realpath/getcwdの返却bytesを保持し、Ruby側でのNFC表記への変換を避ける。既存名をNFC/NFDへ統一しない。
- 保存候補の所有実体を作成fdから確認する。候補とmetadata用一時ファイルは削除後もlstatで確認し、残存・EACCES・EIOをcleanup失敗として経路付きで報告する。再削除は行わない。

### Tests

- ASCII/NFC/NFDの親子9通りの合成MP4で保存・再open・cleanupとmetadata/章/媒体の保持を確認した。候補差替え・公開失敗・削除異常は失敗注入で検証した。
- ローカルAPFSと隔離インストール済みarm64 gemでUnicode試験16件が成功した。実SMBは未試験で、cache ONの削除不整合の解消は保証しない。

## 2.3.2.43

### Added

- `plan_metadata_repair_and_update(properties:, mdta_layout:)` を追加し、限定metadata修復と文字列タグ差分を同じ候補へ一括反映する。合成できない組合せは保存前に理由付きで拒否する。
- `chapter_samples(style: :quicktime)` を追加し、正常Neroとの併存や内容差によらずQuickTimeのsampleと時計を明示取得できるようにした。
- `save!(diagnostics:)` で独立検証後の要求診断だけを返却し、参照・時間の解析結果を再利用する。

### Changed

- 正常時間へのprofile指定は強制書換えにせず `unchanged` を返す。異常のprofile不適合・診断不能は成功扱いしない。
- 同一世代の完全metadata観測を再利用する。修復変更あり＋同値タグ更新でも変更状態を保持する。
- 既存の世代競合検出、原本保護、独立検証、公開状態、cleanup、無変更の別出力コピー契約を維持する。

### Tests

- 合成MP4で修復・更新・同値・chapter形式別取得と破損除去、artwork保持、Unicodeパス、失敗状態を検証した。
- 約8.4MBのfixtureで2段階保存の全体走査4回／コピー2回を、一括保存の2回／1回へ削減。全不要時は全体走査・コピー・書込ゼロを確認した。

## 2.3.2.42

### Added

- `File#observation(areas)`を追加し、同一世代のmetadata、chapters、chapter参照、chapter時間、chapter sample、tracksを`{status:, data:, issues:, value:}`で一括観測できるようにした。malformed/unsupportedは例外にせず領域別statusで返し、source変更・I/O・close・保存待ちの編集は従来どおり送出する。
- metadata観測と完全snapshotを同じnative読込みで取得し、以後の編集候補へ再利用する。

### Changed

- chapter参照の保持署名を、chunk offsetのmdat内相対位置を固定長digestへ畳み込む表現に変更した。chunk数に比例する配列とmdatごとの線形探索を保持しない。
- 単一mdatのchunk offset検証を最小・最大値の一括判定に変更した。複数mdatは範囲の二分探索で従来どおりmdat外offsetを拒否する。
- `File#chapters`の編集候補をChapterReaderの完全読取値から構築し、同じ世代で読んだchapter診断・`read_chapters`・観測と共有する。snapshot取得のためのnative handle追加openを廃止した。

### Tests

- `test/mp4_observation_test.rb`を追加し、正常観測、malformed metadata/chapter、未保存chapter編集、引数拒否を検証した。`chapters`がnative handleを追加openせず同じsnapshotを再利用することも確認した。
- 均一なchunk移動では保持署名が変わらず、mdat内の位置変更を検出する回帰を追加した。

## 2.3.2.41

### Added

- QuickTime chapterを正として正常なNero chapterを代替扱いし、形式を問わず破損chapterを安全に除去する公開APIを追加した。
- chapter参照の診断・除去計画とatom編集の回帰テストを追加した。

### Changed

- chapter形式の選択、破損判定、除去を同一のMP4保存計画へ統合した。
- テスト用開発依存gemは一時ディレクトリへ導入し、テスト終了時に削除する運用を文書化した。

## 2.3.2.40

### Fixed

- 全体CIを公開前の必須検証へ追加し、Ruby 3.2/4.0の同一コミットでの回帰を公開ジョブへ反映する。
- 世代検証、Unicode原表記保持、metadata context境界検証、候補cleanupの追加回帰テストを製品API経由で実行する。

### Fixed

- ctime差をSHA256で許容する前にfd/pathのdev/inode/size/mtimeを再確認し、走査中の変更も拒否する。読取り中の世代競合はareaとstat差分を保持したまま`phase: :read`で報告する。
- metadata contextの未知handler・未確定の親境界を確実に拒否し、診断時に不要なitem全体のSHA読取りを避ける。
- 原表記保持に合わせてsample境界とartwork読取りのテスト監視pathを更新し、SMB相当の遅延・plan後の変更・検証後の候補差し替えを製品コードの通常テストへ追加する。

### Changed

- バイナリgemの公開は、同一commitに対するRuby 3.2/4.0の全体CI成功を必須とする。

## 2.3.2.39

### Fixed

- `prepare_candidate`中に候補を同一pathへ原子的に置換する保存処理を許容し、検証後の外部差し替えはcleanup前のdev/inode確認で拒否するようにした。
- 通常ファイルの原表記を保持する保存経路に合わせ、候補走査のpath契約テストを更新した。

- `verification: :sha256`で基準SHAを取得したSMB原本のctime-only差分は、fd/pathの内容SHA256が一致する場合だけ継続し、dev/inode/size/mtime差や内容差は`source_changed`で拒否するようにした。比較時のexpected/handle/path statをissuesへ記録する。stat既定は従来どおり厳格検証する。
- SMB上のNFDファイル名を`File.realpath`がNFCへ変換して再open不能にする場合に備え、通常ファイルは入力経路をそのまま保持し、symlinkだけ同一実体を確認したcanonical pathへ解決する。
- 通常ファイルのopen/saveでは入力のUnicode表記を保持し、symlinkだけを同一dev/ino確認後に解決するようにした。出力の存在判定は`lstat`へ変更し、一時候補のcleanup前に作成時dev/inoを再確認して別実体を削除しないようにした。

## 2.3.2.38

### Added
- 同一`moov/udta`内の検証済み`mdir`+`mdta` metadata context pairを限定修復で保持し、`mdta`の不正indexだけを除去できるようにした。
- pairの親atom実体、handler、子atom、keys、順序を診断・計画・保存後検証で共通確認するテストを追加した。

### Changed
- 複数metadata contextは安全な2個のpairだけを許可し、3個以上、同種handler、別`udta`、未知子atom、境界不明は従来どおりblockedとする。
- mdir contextはnative setterへ変換せずraw保持し、保存後の独立再openで限定修復計画を再確認する。

## 2.3.2.37

### Added
- `moov/udta/titl`と`moov/trak/udta/titl`の複数atomを、検証済みraw bytesのまま限定修復で保持できるようにした。
- `titl`の実際のatom path、offset、size、拒否理由を診断へ保持し、共通構造解析の失敗をmetadataとQuickTimeの両方へ伝播するようにした。

### Changed
- `titl`の検証・保持署名と限定修復の診断補完を整理し、既存のI/O・世代検証・原子的保存契約を維持した。
- MListNewは修正版を利用するため、taglib-ruby-plus依存を2.3.2.37へ更新する必要がある。

### Fixed
- 正常なtrack内`titl`を固定の`moov/udta/titl`配置制限でunsupported扱いしていた問題を修正した。

## 2.3.2.36

### Fixed
- SMB共有で保存後のfd/pathのctimeだけが遅れて不一致になる場合、候補SHA256とdev/inode/size/mtimeを再確認して同一世代として採用するようにした。
- 候補内容、dev、inode、size、mtimeのいずれかが一致しない場合は、従来どおり`source_changed`を返す。

### Changed
- MListNewは修正版を利用するため、taglib-ruby-plus依存を2.3.2.36へ更新する必要がある。

## 2.3.2.35

### Changed
- gemspecの収録対象を実行・ビルドに必要なファイルへ限定し、ADR・設計資料・テストfixtureを配布gemから除外した。
- `gemspec_check`を新しい収録対象の方針に合わせた。

## 2.3.2.34

### Fixed
- Ruby 4.0.7 LinuxのGC compaction後にMP4 `ItemMap#item_map`で発生していたSWIG trackingのSIGSEGVを修正した。
- 借用wrapperのVALUEを`rb_gc_register_address`へ直接登録し、GC移動後の参照をRubyに更新させるようにした。

### Changed
- 借用wrapperはnative所有者のclose・置換時まで強参照され、tracking解除後に通常どおり回収される契約へ整理した。Ruby所有wrapperは従来どおりtracking対象外とする。

## 2.3.2.33

### Added
- `udta/titl`を未対応構造として安全に保持し、chapter参照・時間診断と限定修復の可否を分離した。
- 欠落したchapter target参照だけを解除する計画APIと、具体的なtrack・atom位置を含む拒否診断を追加した。
- 別出力の`File.link`が非対応の環境で、同じ検証済み候補をmacOSの排他的renameへ一度だけ切り替える公開処理を追加した。

### Changed
- 計画拒否と保存失敗の公開Errorへ具体的なmessage、issue、publication statusを保持するようにした。
- 保存候補の生成・独立検証・公開責務を分離し、fallback時の追加コピー・再修復・再検証を行わないよう整理した。
- 確定状態が判定不能な場合は`committed: nil`としてセッションを再利用不可にし、原本と競合出力を保護する。

## 2.3.2.32

### Added
- 不正mdta index（0およびkeys範囲外）と壊れたQuickTime専用chapterを独立診断し、一つの別出力保存へ合成する限定修復APIを追加した。
- indexと通常fourccの解釈profile、必要操作の許可確認、除去対象・digest・公開状態の報告と独立保持検証を追加した。

### Changed
- 構造系の読取・診断・計画から不要なnative metadata読込を除き、同じmoov、章観測、無変更snapshot、保存後構造解析を再利用するようにした。
- 8MiB画像付きfixtureの構造操作で、論理readを109,065,558から1,402 bytesへ削減した。

### Fixed
- cleanup失敗後の一時ファイルを明示管理し、GCによる公開出力のctime変更と世代不一致を防いだ。
- 既存stscテストのブロック結合と、Rakeからminitestへ渡すrunner専用オプションを修正した。

## 2.3.2.31

### Added
- 専用text trackへ収束し他用途共有のない映像sourceのchap参照を安全な除去対象へ追加し、字幕source・未知handler sourceはreason code付きで拒否するようにした。
- 正常Nero／QuickTime、欠落・共有・未知参照、時間不整合、Nero異常、世代競合、保存再試行を合成MP4で検証した。

## 2.3.2.30

### Added
- Plus公開APIに形式別完全読取`read_chapters(style:)`を追加し、別形式の異常があっても正常Neroを取得できるようにした。
- 壊れたQuickTimeだけを専用text trackと参照ごと除去する世代付き計画APIを追加した。

## 2.3.2.29

### Fixed
- native gem生成時に、各extension bundleが参照するTagLib C++シンボルと同梱`libtag`のexportを照合し、古いbundleの混入によるmetadata APIのSIGSEGVを生成前に拒否するようにした。

## 2.3.2.28

### Added
- MP4 `sample_boundaries`で、ffmpeg生成AACの限定roll sample group（sgpd/sbgp）を検証し、decode preroll宣言として返すようにした。
- group構造・割当の検証、対応外形式／破損／上限の分類、group payloadのI/O・entry計測を追加した。

## 2.3.2.27

### Added
- MP4 sample tableを検証し、先頭／末尾sampleのabsolute offset・size・raw media時刻・edit情報を返す読み取り専用`sample_boundaries` APIを追加した。
- stts、stsc、stsz/stz2、stco/co64の件数・範囲・mdat内整合性を検証し、非対応構造と上限到達を区別するfixture回帰を追加した。

### Fixed
- sample境界取得でmedia本文・全mdat・全sample配列を読み込まず、読込bytesとentry数を返すようにした。

## 2.3.2.26

### Fixed
- `diagnose(:structure)`のstsc chunk mapping探索を線形化し、大量chunk・大量stsc行のMP4診断を高速化した。
- 不正mappingでも従来の診断結果を維持し、公開schemaと読み取り専用方針を変更しない。

## 2.3.2.25

### Added
- MP4構造診断でatom境界、track、stco/co64、mdat範囲、sample終端を読み取り専用で検査可能にした。
- 不正chunk offsetのtrack別件数、先頭・末尾entry、最大参照位置、ファイルサイズ、mdat範囲を公開する診断を追加した。

### Fixed
- chapter参照診断が最初の不正chunk offsetで詳細を失わず、構造診断結果を返すようにした。

## 2.3.2.24

### Added
- MP4公開APIのheader情報snapshot、保存後snapshot再利用、I/O削減を追加。
- arm64向けバイナリgemのGitHub Actions公開対象を更新。

### Fixed
- test-unitとminitestの実行を分離し、全体テストで片方が未実行になる問題を解消。

## 2.3.2.23

### Fixed
- 公開snapshot保存で生成されるmdirとmdtaの併存をmetadata診断で正しく扱う。

## 2.3.2.22

### Fixed
- metadata snapshot復元とartwork処理を整理し、公開バイナリgemとして配布する。

## 2.3.2.21

### Fixed
- native gem smoke testをPlus APIの内部実装境界に合わせ、公開native APIの誤検出で公開workflowが失敗しないようにした。

## 2.3.2.20

### Added
- `TagLib::Plus::MP4`に編集セッション、不変metadata/chapter値、診断、明示的修復、検証付き保存を追加。
- 旧fork追加操作を内部専用入口へ分離し、保存失敗後の状態と診断schemaを固定。

### Fixed
- Plus APIの保存・診断状態確認とmetadata/chapter変更判定を共通化し、公開前後の失敗原因を保持。

## 2.3.2.19

### Fixed
- 単一mdta contextの既存purlを公開setterで更新・削除した際、数値key atomをfourcc用raw復元へ渡して保存が失敗する問題を修正。
- 自動raw復元は通常itemのfourcc purlに限定し、mdtaの意図的更新と未編集の型・locale・bytes・値順を既存native保存で保持。
- raw保持の対象選択と保存制御を分離し、atom作業コピーの変換・置換・cleanupを共通化。
- 新規追加・変更・同値設定・削除・他タグとの同時保存、独立再読込、Tag/File snapshot、media保持、失敗時の原本保持・cleanupの回帰テストを追加。

## 2.3.2.18

### Added
- 単一mdta contextの`keys`末尾へpurlを追加し、数値key indexのilst itemとして安全に復元可能にした。
- purl以外のmacOS系UTF-8 mdta keyをsnapshot復元で追加できるようにした。
- purlの複数値・locale・data type・raw digestを保持する診断と回帰テストを追加。

### Fixed
- mdtaへ文字列fourcc `purl`を追加することで発生していた`1886745196`等の不正indexを防止。
- atom境界、親サイズ、chunk offset、mdat範囲を検証し、安全に拡張できない場合は原本を変更せず拒否。
- 既存fourcc `purl`、複数context、keys/ilst不整合を専用codeで明示的に拒否。

## 2.3.2.17

### Added
- metadata snapshotにpurlの所有raw bytesを保持し、`purl_raw_digests`で再読込後の完全一致を検証可能にした。
- `metadata_context_diagnostics[:purl]`に保存可否・保存先context・拒否codeを追加。
- `metadata_capabilities`にpurl raw snapshot・既存mdir復元・context生成可否を追加。
- MListNew向け移行手順と制限を`Docs/mp4-purl-snapshot-restore.md`へ記載。

### Fixed
- 単一contextの既存purlをraw復元し、native writerによるdata type変更を防止。
- mdtaとmdirが各1個で保存先が一意な場合、Fileのsnapshot復元で通常itemを既存mdirへ保存。
- 複合contextは既存mdirをmdtaより前に配置し、FFprobeのdata index警告の新規発生を防止。
- 単一mdtaにpurlが存在しない場合は、復元前に`MetadataSnapshotError(code: :purl_context_creation_unsupported, phase: :restore)`で拒否。purlの暗黙省略やcontextの新規生成はしない。
- purlの型変更・不正keys・handler不一致・曖昧なcontextを拒否し、保存失敗時の原本不変を維持。

## 2.3.2.16

### Added
- 読み取り専用color_metadata_diagnosticsでtrack・sample entry・colrの構造と欠落値を診断。
- metadata_context_diagnosticsでmeta/ilstの位置、handler、keys、item解釈とraw digestを公開。

### Fixed
- mdta contextへの新規purl生成をprepareで拒否し、未編集purlのraw変更を保存検証で拒否。
- SWIG定義のAtomDataTypeを完全修飾し、wrapper再生成時の名前空間エラーを解消。
- colrの推測修復や安全判定緩和を加えず、非ゼロ欠落chapter参照の選択解除と対象外保持を合成MP4で検証。

## 2.3.2.14

### Added
- MP4 metadata snapshotの比較契約をvalues/exactへ分離し、Fileからのsnapshot取得・復元・更新を公開。
- MetadataUpdateを導入し、snapshot期待値とnative適用の更新計画を共有。

### Fixed
- 保存検証用metadata署名を公開snapshotから分離し、既存の保存トランザクションを維持。

## 2.3.2.13

### Added
- paddingを含むQuickTime text chapterの全sampleを取得する読取専用chapter_sample_snapshotを追加。
- 整数media ticks、各sampleのduration・title・payload署名と、offset非依存の保持比較を公開。
- 単一identity editの全期間照合可否を明示し、不正表・曖昧な参照・非対応editを拒否。
- 両backend、通常タグ保存・offset移動、実ファイル一時コピーでffprobe全chapterとの照合を検証。

## 2.3.2.12

### Added
- chapter参照診断・修復記録に元のtref_indexを追加し、章の時間不整合を独立して診断。
- 再現済みfull-movie profileに限定した明示的時間修復とv1 identity edit読取を追加。
- 先頭mdta index 0のraw群を保持しながら通常タグを更新する明示保存APIを追加。

### Fixed
- close時のCoverArt走査で共有listをdetachさせず、borrowed wrapperを確実に解除。
- 複数trefを独立して解析し、欠落IDだけを除去。有効参照の順序・重複・group・他参照を保持。
- native chapter writerがtkhd/elstへmovie単位の64bit durationを書き、必要な場合だけv1を生成。
- 保存後の添字変化を考慮した構造検証、対象外payload保持、故障時の例外伝播と原本維持を検証。

## 2.3.2.11

### Fixed
- chapter参照修復で字幕のudta/nameを許可し、元のbytesと他の保持対象を維持する。

## 2.3.2.10

### Added
- snapshotの型付き値取得、set_propertiesと変換を共有する期待snapshot生成を追加。
- Nero／QuickTimeを独立保持するChapterSnapshotの取得・復元・論理差分・読取診断を追加。
- QuickTime chapter参照の診断と欠落参照だけの明示的除去・原子的保存を追加。通常保存では自動修復しない。

### Fixed
- 不完全chapter構造を保存前に拒否し、原本と未保存状態を保持する。
- Chapterのタイトル文字列をコピー・freezeして呼出側の変更から独立させる。

## 2.3.2.8

### Added
- Add Ruby-owned MP4 metadata snapshots, atomic in-memory restoration, strict
  logical/structure comparisons and read-only structural diagnostics (2.3.2.8).
- Include binding snapshot native patches for legacy and grouped mdta backends.
- Publish source and macOS platform gems to the GitHub Packages RubyGems registry.
- Use distinct GitHub Packages gem names for source, arm64-darwin, and
  x86_64-darwin distributions.

### Fixed
- Keep the native gem platform selector out of the source-gem extension build.
- Remove the build Ruby libruby dependency from macOS native extensions so they
  load with the user's Ruby installation.

## 2.3.2.7

### Added
- Atomically replace all ordered, typed mdta values for a key with
  `replace_mdta_items`, preserving duplicates, locale and binary data.
- Adapt the proposed grouped native API without changing the Ruby mdta value layout,
  single-value setter or atomic save boundary; keep binding state transfer separate.
- Expose `mdta_status` for grouped native libraries, reporting `unknown` for legacy ones.

### Fixed
- Render every value when adding a new mdta key.
- Reject ambiguous or malformed structures in the new replacement API.

## 2.3.2.6

### Fixed
- Mark CPU-specific macOS distribution gems as Ruby-platform gems so their
  package names, registry metadata, and installed specifications resolve
  consistently through Bundler.

## 2.3.2.5

### Fixed
- Remove the GitHub Actions build Ruby dependency from macOS native extensions.

## 2.3.2.4

### Added
- Add self-contained macOS platform gem packaging for `arm64-darwin` and
  `x86_64-darwin`, including the patched TagLib library and license files.

## 2.3.2.3

### Fixed
- Allow chapter-only saves to remove chapter-track mdat payloads while
  continuing to verify that nonchapter media samples are unchanged.

## 2.3.2.2

### Changed
- Normalize high-level MP4 `set_property`/`set_properties` updates to ilst for
  `title`, `TVShowName`, `artist`, and `description`, removing only the matching
  FFmpeg mdta fallback while preserving other mdta keys and typed values.
- Make `remove_property` remove the ilst value and matching mdta fallback together.

### Added
- Preserve unknown and typed FFmpeg mdta entries while high-level MP4 properties
  are normalized.

## 2.3.2.1
### Added
- Rename the gem to `taglib-ruby-plus` and its public entry point to
  `require 'taglib_plus'` while retaining the `TagLib` namespace.
- Add high-level MP4 iTunes property and artwork APIs.
- Add Ruby-owned MP4 artwork and content-rating value objects.
- Add CI coverage for the MP4 metadata API and packaged gem smoke test.
- Preserve, read, and write FFmpeg `mdta` metadata in MP4 files when using
  the patched TagLib 2.3.2.

### Changed
- The gem version uses the four-component `2.3.2.1` downstream revision while
  the required TagLib C++ version remains `2.3.2`.

## 2.3.2
### Changed
- Require TagLib 2.3.2 or newer when building the native extensions.
- Expose MP4 codec identifiers and the additional TagLib 2.3.2 codec values.
- Use the TagLib 2.3.2 fixes for MP4 chapter references and malformed atom handling.

## 2.3.1
### Added
- Add MP4 Nero and QuickTime chapter read/write APIs, including `style: :preserve`.
- Add explicit `TagLib::MP4::File#save_chapters` for chapter-only persistence.

### Changed
- Require TagLib 2.3.1 or newer when building the native extensions.
- The initial supported platforms for this release are macOS and Linux.

## 2.0.0
### Changed
- Regenerate SWIG wrapper code against TagLib 2.0.1. This breaks
  compatibility with TagLib 1.x. You will get a compiler error if you
  try to install taglib-ruby 2.x on a system that has TagLib 1.x.
  Please use taglib-ruby 1.x if your system has TagLib 1.x, and
  taglib-ruby 2.x if your system has TagLib 2.x.
- The optional `strip_others` argument to `TagLib::MPEG::File#save` no
  longer takes a boolean value. It now uses the constants
  `TagLib::File::StripOthers` and `TagLib::File::StripNone`.

### Removed
- `TagLib::MPEG::File#tag` has been removed because it no longer
  exists in TagLib 2.x. Please use `TagLib::MPEG::File#id3v2_tag` or
  `TagLib::MPEG::File#id3v1_tag`.

## 1.1.3 - 2022-12-29
### Changed
- Fix warning `warning: undefining the allocator of T_DATA class
  swig_runtime_data` on Ruby 3.2
- Upgraded to SWIG 4.1.1

## 1.1.2 - 2022-04-13
### Fixed
- Fix UserTextIdentificationFrame's constructor so that overloaded
  variants with StringList arguments can be called (#107)

## 1.1.1 - 2022-04-12
### Changed
- Fixed build time warnings with Ruby >= 2.7.0 (#85)
- Upgraded to SWIG 4.0.2
- Fixed running tests against TagLib 1.12

## 1.1.0 - 2021-01-20
### Added
- Added support for CTOC and CHAP frames for ID3v2

## 1.0.1 - 2020-03-25

### Fixed
- Fix segmentation fault with TagLib::FLAC picture lists (#91), thanks
  @jameswyper!

## 1.0.0 - 2020-01-07

* Support for TagLib >= 1.11.1 (drop support for earlier versions) (#83)
  * This includes a lot of new APIs and some changed APIs, see
    `@since 1.0.0` in the docs
* Stop using tainted strings to fix warnings with Ruby 2.7 (#86)

## 0.7.1 - 2015-12-28

* Fix compile error during gem installation on Ruby 2.3 (MRI) (#67)

## 0.7.0 - 2014-08-21

* Add support for TagLib::RIFF::AIFF (#52, by @tchev)
* Add support for TagLib::RIFF::WAV (#57, by @tchev)
* Associate filesystem encoding to filename strings
* Allow CXX override during gem installation
* Try to detect location of vendor/taglib on Heroku (#28)
* Documentation updates

## 0.6.0 - 2013-04-26

* Add support for TagLib::MP4 (#3, by @jacobvosmaer)
* Add support for TagLib::ID3v2::Header (#19, by @kaethorn)
* Support saving ID3v2.3 with TagLib::MPEG::File#save (#17)
  *  Note that this requires at least TagLib 1.8, and due to 1.8.0
     having an incorrect version number in the headers, it currently
     requires master. See issue #17 for details.
* Fix segfault when passing a non-String to a String argument
* Documentation updates

## 0.5.2 - 2012-10-06

* Fix memory bug with TagLib::MPEG::File#tag and TagLib::FLAC::File#tag
  which could cause crashes (#14)
* Update TagLib of binary gem for Windows to 1.8

## 0.5.1 - 2012-06-16

* Fix crashes (segfault) with nil arguments, e.g. with `tag.title = nil`
* Document TagLib::MPEG::File#save and TagLib::MPEG::File#strip (#11)
* Update TagLib of binary gem for Windows to 1.7.2

## 0.5.0 - 2012-04-15

* Add support for FLAC
* Fix problem in SWIG causing compilation error on MacRuby (#10)

## 0.4.0 - 2012-03-18

* Pre-compiled binary gem for Windows (Ruby 1.9) with TagLib 1.7.1
* Unicode filename support on Windows
* Add `open` class method to `FileRef` and `File` classes (use it
  instead of `new` and `close`):

```ruby
title = TagLib::FileRef.open("file.mp3") do |file|
  tag = file.tag
  tag.title
end
```

## 0.3.1 - 2012-01-22

* Fix ObjectPreviouslyDeleted exception after calling
  TagLib::ID3v2::Tag#add_frame (#8)
* Make installation under MacPorts work out of the box (#7)

## 0.3.0 - 2012-01-02

* Add support for Ogg Vorbis
* Add support for ID3v1 (#2)
* Add #close to File classes for explicitly releasing resources
* Fix compilation on Windows

## 0.2.1 - 2011-11-05

* Fix compilation error due to missing typedef on some systems (#5)

## 0.2.0 - 2011-10-22

* API documentation
* Add support for:
  * TagLib::AudioProperties and TagLib::MPEG::Properties (#4)
  * TagLib::ID3v2::RelativeVolumeFrame

## 0.1.1 - 2011-09-17

* Add installation instructions and clean up description

## 0.1.0 - 2011-09-17

* Initial release
* Coverage of the following API:
  * TagLib::FileRef
  * TagLib::MPEG::File
  * TagLib::ID3v2::Tag
  * TagLib::ID3v2::Frame and subclasses
