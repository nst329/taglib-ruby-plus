# QuickTime優先と破損チャプター削除の設計

状態: 実装済み（2026-10-22）。保存後検証を含む追加受入テストは継続。

## 確定した方針

QuickTime形式を正とする。正常なQuickTimeがない場合は正常なNeroを代替利用する。破損チャプターは形式を問わず削除対象とする。正常なNeroを暗黙削除したり、NeroをQuickTimeへ変換したりはしない。

## 選択と削除を分離する

読取による選択は原本を書き換えない。QuickTime、Neroの順で完全読取できた形式を選ぶ。不在と存在する空配列は区別し、正常な空QuickTimeもQuickTimeとして選択する。両方不在なら選択なし、存在するが利用可能な形式がない場合は診断付きで利用不能を返す。

| QuickTime | Nero | 選択 | 削除候補 |
| --- | --- | --- | --- |
| 正常 | 正常・不在 | QuickTime | なし |
| 正常 | 破損 | QuickTime | Nero |
| 不在 | 正常 | Nero | なし |
| 破損 | 正常 | Nero | QuickTime |
| 破損 | 破損 | なし | 両方 |
| 不在 | 不在 | なし | なし |

未対応形式、予算超過、I/Oエラー、世代変更は破損確定として扱わない。既存readerのmalformedも原因コードを監査する。atom境界不明など安全な除去範囲が確定できない異常は削除候補であってもblockedにする。時間不整合は既存時間診断の確定条件を使い、単なる形式間の値の相違は破損としない。

## API案と互換性

既存のchapters、read_chapters(style:)、QuickTime限定除去は契約を維持する。内部共通取得のNero優先やconflict例外も今回変更しない。

追加APIとして`select_chapters`、`plan_broken_chapter_removal`、`remove_broken_chapters(plan:)`を実装した。選択結果はstyle、chapters、形式別診断、選択不能理由を持つ不変値。削除計画は形式ごとの候補・拒否理由・保持対象を持ち、セッションと世代に束縛する。未知の診断状態はエラーとして止める。

両方破損時も同じ原本座標の単一計画を作る。削除候補の一部がblockedなら全体をblockedとし、部分適用しない。別形式が破損しているだけでは、除去の安全性を拒否しない。現行のnero_unreadable前提は新計画に引き継がず、正常なら値とraw hash、削除対象なら不在、未対応で保持するならraw hashと構造署名で検証する。

## 除去範囲と保存

Neroは境界が確定した対象chpl atomを除去し、udta全体は消さない。重複chplや複数udtaは初期実装では拒否する。QuickTimeは既存の専用track・参照安全検証を再利用し、対象trakと対応chap参照を同時除去する。共有track、未知構造、除去対象内の保持必須titlなどは既存どおり拒否する。欠落参照の除去は既存の専用計画を使う。

保存は既存のstage、逐次コピー、独立検証、原子公開を使う。mdatから未参照sampleを物理回収しない。保存後は除去対象不在、正常形式の値・raw保持、非対象track・metadata・artwork保持、mdat hashを確認する。別出力なら原本不変も確認する。

## I/Oと実装順序

計画作成では同世代のChapterReaderとatom indexを共有し、Nero/QuickTime別にmoovを読み直さない。時間・参照解析も既取得moovを使う。保存は両形式分を一つのmoov置換へまとめ、stageへの全体コピー1回と既存の独立検証走査を使う。診断だけなら書込み0回。無変更の同一パス保存は既存の無書込み経路を維持する。

製品実装時はFile#readの位置・bytes・回数とコピー回数を計測する。今回のprobeはI/O削減効果の実測ではない。保持する診断・moovはメモリを使うが、mdatの蓄積や形式ごとの全体コピーを避ける。新規cache機構は追加しない。

破損チャプター除去では原本metadataのnative snapshot再読込を省き、計画時と出力のraw保持署名を比較する。出力snapshotの返却は維持する。malformedの除去に不要な時間診断を省き、サイズ維持時のmoov生成を1回にする。判断と検証は[重複読取と生成を省くADR](ADR/2026-10-22-破損チャプター除去の重複読取と生成を省く.md)を参照する。

## テストと残作業

実行可能probeはtest/probes/mp4_chapter_policy_design.rb。異なる正常値、QuickTime不在、各形式の破損、Nero除去後のQuickTime保持を合成MP4で確認する。16通りの状態組合せで選択と削除候補を確認する。保存後検証を含む7テスト79 assertionsが成功している。

製品受入テストでは、正常空配列、両方不在、unsupportedと破損の併存、既知時間不整合、共有track、重複atom、未知構造、原本変更、異なるセッション、許可不足、部分適用拒否、保存失敗・cleanup・原本維持を追加する。合成した正常字幕trackも含め、保存前後のtrack別packet hashとmetadata/artworkを独立比較する。結合文字のパスで再読取・保存・cleanupを確認する。これらの追加保存試験とI/O計測は未実施。
