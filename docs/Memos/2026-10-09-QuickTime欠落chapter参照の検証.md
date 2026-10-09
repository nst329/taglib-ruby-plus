# QuickTime欠落chapter参照の検証

## 環境・前提

macOS arm64、Homebrew Ruby 4.0.7、FFmpegを使用。実ユーザーファイルを変更せず、1秒の映像・音声・日本語字幕を含む合成MP4とNero 16章を生成した。型・locale・NUL入りbytes・同値重複・値なしmdtaキー、日本語title、実JPEG artworkも保持対象に含めた。

Rubyコードを/private/tmpの隔離libへ反映し、既存2.3.2.9 native bundleを使用した。native ABIの変更はない。legacyとgroupedの両バックエンドで新APIを検証した。

## 既存APIの再現

`LEGACY_CHAPTER_REPRO=1`、2.3.2.9の配布済みlibを指定し、`test_legacy_remove_success_leaves_dangling_reference`を実行した。1 test / 6 assertionsが成功。3トラックのchap→0に対するremove_chaptersとsave_chaptersがtrueを返し、全ファイルSHA-256と欠落参照が変化せずNero 16章が保持された。native QtChapterList::removeの「参照先トラックなしならtrueで終了」と一致する。

## 新API・保持対象の検証

`test/mp4_chapter_references_test.rb`: legacy、groupedとも14 tests / 170 assertions、失敗・エラーなし。最後にFFMPEG環境変数またはPATH上のffmpegを使うようテストを変更し、legacyで同じ14 / 170の成功を確認した。

- Neroのみ＋3トラックからID 0への参照、非0欠落ID、重複した欠落参照を除去。
- 有効QT参照と欠落参照の混在、先頭が欠落した参照と有効参照の重複を保持して清掃。
- 存在する映像トラックへの不適切な参照は別判定とし、除去せず保持。
- 他種tref参照、co64、extended moov headerを保持。
- moovがmediaの前にあり、混在参照から4 bytes除去して8 bytes移動する場合を独立offset補正と実デコードで検証。
- 参照なし・有効QTだけでは除去計画なし。再実行は空配列、計画作成だけでは原本不変。
- 独立atom parserで保存後の参照を検証。全実トラックIDとchap／offset／padding以外のleaf payload、全mdat、Nero、metadata、artworkのサイズ・SHA-256を比較。
- 別handleのNero 16章、metadataの構造一致を確認。有効QTはchapter内容も確認。
- 不正atom境界、chap payload不整合、重複chap、fragmented構造、mdat外chunk、外部drefを理由付き拒否。原本SHA-256は不変。
- 未保存のタグ／chapter更新と修復計画の混在、計画後の原本変更を拒否。
- 一時出力書込み失敗、media破損、解析不能な一時出力、rename失敗を注入。committed=falseで拒否し、原本と計画を保持、一時出力を削除。書込み失敗後の再試行も成功。
- save入口での修復と原本mode 0600の保持も確認。

ffprobeの警告は成功条件に使用していない。実ファイルで警告が表面化する段階は今回も未確定。

## テストで見直した点

保存準備中の混在拒否と、別handleで解析不能な一時出力の例外を、既存MdtaSaveErrorのprepare／verifyへ統一した。保持確認できない場合は置換しない。

初期fixtureのダミーPNGはデコード不能だったため実JPEGに変更した。またQT追加後に別mdatがmoovより後へ追加されることを確認し、extended header fixtureの期待offsetを独立に補正した。いずれもfixture側の問題であり、製品へ回避策は追加していない。

## 回帰テスト

chapter、公開snapshot、metadata snapshot、mdta全体置換、metadata保持と新APIの関連6ファイル: 69 tests / 773 assertions、失敗・エラーなし。

変更が揃った後に全体Test::Unitを1回実行: 334 tests / 1835 assertions、既知の失敗1件、エラー0、手動probeの条件不足によるomission 10件。失敗はMP4ItemsTestのborrowed wrapper数（expected 14 / actual 15）で、先行作業で変更前HEADでも再現済みの問題。今回の新APIの失敗ではない。全体を成功扱いにはしない。

別runnerのMinitest: 12 runs / 24 assertions、失敗・エラーなし、環境条件不足によるskip 5件。Ruby構文チェックとgit diff --checkも成功。

## 配布内容

source gem `/private/tmp/taglib-ruby-plus-2.3.2.10.gem`を生成し、別ディレクトリへ展開した。展開したlib・testを使用し、映像／音声／字幕の欠落参照0を除去するテストを実行: 1 test / 16 assertions、成功。新API・fixture・設計・ADRの収録も確認した。gemspecに存在しないファイルはなく、収録対象との差分は従来から対象外のworkflow 2件と.gitignoreのみ。新しいnative bundleのビルド・gem公開・commit/pushは今回行っていない。

## 設計整理 → 実装 → テスト → コード整理

追加指示に従い、先に設計書とADRを改訂した。解析のChapterReferencesと、Ruby所有値だけを保持する不変のChapterReferenceRepairを分離した。診断・保存後検証では変更bytesを生成しない。明示的な計画作成だけで生成する。File／native handle／IOを計画へ保持しないため、handleの寿命と独立する。

この設計を実装後、legacyで16 tests / 185 assertionsが成功してからコードリファクタリングへ進んだ。不変計画の変更拒否・close後の適用・原本不変、診断と保存後検証が変更bytes生成を呼ばないことを追加テストで確認した。故障注入は不変計画の書換えからFileの書込境界への注入に変更し、従来の失敗検証を維持した。

コード整理では、保持signatureを構造・相対chunk位置・payload hashの小さな処理へ分解し、offset描画と保存準備を抽出した。stsd取得の重複も除去した。公開API・比較基準・例外phase・原子的置換の順序は変更していない。一般保存フローや共通atom parserはこの整理で変更していない。

最終状態の構文チェックとgit diff --checkは成功。関連6ファイルは71 tests / 795 assertions、groupedの修復テストは16 tests / 185 assertions、いずれも失敗・エラーなし。全体テストは前回実行済みで、今回の内部整理の影響範囲は対象テストで確認したため再実行していない。既知のborrowed wrapper数不一致を解消した扱いにはしない。

source gemを同じ2.3.2.10として更新し、展開したlibとtestから欠落参照除去・不変計画のclose後適用を検証した。2 tests / 26 assertions、失敗・エラーなし。公開やcommit/push、実ユーザーファイルへの書込みは行っていない。

## udta/name対応パッチの取込み

`/private/tmp/mlist-taglib-23210/udta-name-support.patch`を確認して適用した。製品コードの変更はudtaの許可leafへnameを加える1行だけで、C++側の変更はない。

追加された字幕name保持テストは、変更前の隔離libで`unsupported udta/name`として失敗することを再現した。変更後はlegacy／groupedの両方で17 tests / 198 assertionsが成功。保存後の独立atom解析で字幕トラックID 3のname bytesを直接比較するassertionも追加した。既存repair_and_checkにより、欠落参照0が除去され、全実トラック・media・Nero 16章・metadata・artworkの保持と別handle再読込も確認した。

構文チェックとgit diff --checkは成功。変更範囲が許可leafとその回帰テストに限定されるため、全体テストは再実行していない。実ユーザーファイルには書き込んでいない。

## 限界（name対応後も同じ）

Linux・Intel・Ruby 3.2での実行は未実施。fragmented／暗号化／未知構造等は意図的に拒否する。既存の不適切な参照を残すため、すべての外部警告の解消を保証しない。タグ・chapterの同時編集は別保存とする。

[設計](../mp4-chapter-reference-repair-design.md) / [ADR](../ADR/2026-10-09-QuickTime欠落chapter参照の明示的除去.md)
