# 未対応mdtaのraw保持とchapter時間修復の分離

状態: テスト検証を根拠とする設計決定。製品実装済み。

## 背景

複数tref修復後の実ファイルで、通常タグ保存がmetadata検証に失敗し、ffprobeは1章だけを返す。ユーザーから「テストコードで検証してから設計」と指定されたため、再現テストとテスト内の試作を先に実行した。

## 決定と理由

- mdta index0の意味は推測しない。keys順を逆にしてもnative viewが同じになるため、件数一致や順序だけでキー対応を復元できない。
- 不正numeric itemを保持した通常タグ更新ルートを別APIとして設計する。既存saveの引数なし契約と完全snapshotの拒否を維持し、保存成功をmetadata正常化と扱わない。
- 実ファイルで確認した先頭連続0 item＋正常keys＋通常itemの単一contextに初期対応を限定する。未検証の混在・複数context等へ広げない。
- 一時コピーだけをnativeが保存可能な作業用contextにし、型付き通常itemを保存した後に元raw metadataを戻す。保存後に戻すだけではgroupedのUnsupported拒否を解消しないことをテストで確認したため。
- native item snapshotに加えて、raw atomの件数・順序・bytesを保存検証する。2件目の不正itemを落としても既存verifyが通る反例を再現したため、既存verifyを緩める案は採用しない。
- moovだけを上限付きで解析し、実mdatを逐次コピーする。実ファイルの大きさに比例してmediaをメモリへ載せる試作方式は避ける。fixture編集自体もテスト作業ディレクトリ外と外部symlinkを拒否する。
- chapterの新規生成ではnative writerの内部movie durationを64bitにし、tkhd/elstへmovie単位の同じ値を書き、必要な場合だけv1を生成する。未変更writer自身が提示値を再現したため、生成防止を診断だけで済ませない。
- 既存時間修復は明示profileと厳格なfingerprintに限定する。正常crop、empty edit、複数edit、rate変更、mdhd/stts不一致を単純補正しない。
- full-movie profileの補正値はmovie durationを採用する。media換算値との差132300 ticks（0.3ms）はwriterのms丸めと一致し、writerが全movie期間の単一identity editを作る意図を維持するため。未知のファイルへこの選択を自動適用しない。
- v1単一identity editのstrict reader対応を修復と合わせて設計する。補正後のv1を現行readerが拒否することをテストで確認したため。
- metadata保持保存、参照修復、時間修復、chapter編集は別保存にする。対象外の同時変化を避け、失敗時の復旧範囲を明確にするため。

## 影響と留保

実ファイルの原本と時間情報は変更していない。テスト内では両backendの実ファイルコピーで通常タグ更新・raw保持・15章の保持が成功した。既存APIに試作を組み込んだ状態ではない。

native writerの生成不整合は入力条件から再現できたが、実ファイルの生成ソフト・履歴まで特定したものではない。正常editへの自動補正は行わない。製品化時にはnative再ビルド、raw保持故障検証、offsetとatomic saveの故障検証、対応外入力と公開APIの回帰が必要。

[設計](../mp4-unindexed-metadata-and-chapter-timing-repair-design.md)

実装後、両backendの実ファイルコピーで参照修復・時間修復・保持APIの通常タグ保存2回と原本不変を確認した。細部の採用判断は[限定atom編集のADR](2026-10-09-限定atom編集と原子的保存の共用.md)に記録する。上記の試作段階の記録は当時の根拠として残す。
