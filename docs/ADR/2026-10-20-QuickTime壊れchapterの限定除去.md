# ADR: 壊れたQuickTime chapterだけを専用trackごと除去する

日付: 2026-10-20

状態: 採用

## 背景

TagLib 2.3.2.25では、QuickTimeの音声chap参照が不完全だと`file.chapters`とsetterの全体完全読取が失敗し、正常Neroの値まで利用できない。正常Neroを残す必要があるため、QuickTimeを形式指定で独立読取し、壊れたQuickTimeだけを限定除去するPlus公開APIが必要になった。

## 決定

- `read_chapters(style:)`を追加し、指定形式だけの完全読取を公開する。不在は`nil`、異常はreason code付きErrorとする。
- `plan_quicktime_chapter_removal`と`remove_quicktime_chapters(plan:)`を追加する。計画はFile世代に結び付け、同一世代の`:removable`計画以外を拒否する。
- Neroは正常または不在であることを計画条件にする。Nero異常、I/O失敗、分類不能は成功空配列へ変換しない。
- 音声または映像由来の全chap参照が同一の専用text trackを指し、他用途参照がない場合だけ、chap参照とtrack atomを同一計画で除去する。映像sourceは音声外参照だけを理由に拒否しない。
- 正常QuickTime、欠落参照、共有字幕、字幕source、未知handler source、複数target、未知構造、外部参照は削除しない。拒否理由は公開`reason_code`で判別する。
- 原子的`save!`、独立再読込、Nero値／chpl payload、QuickTime不在、target track不在、非対象media保持の検証を既存保存境界へ接続する。

## 理由

参照解除だけでは専用text trackが孤立して通常字幕として残る可能性があるため、安全に同定できるtrackを参照と同時に除去する。逆に欠落参照から実在trackを推測すると、通常字幕や別用途trackを誤削除するため拒否する。source handlerを一律に音声限定すると、専用trackへ収束する安全な映像sourceまで誤って拒否するため、`soun`／`vide`を許可し、字幕sourceと未知handlerは分離して拒否する。mdatを再構成しないのは、既存media offsetとpayloadを保持し、I/Oと破損範囲を限定するためである。

## 影響

MListNewはstage上の計画statusとreason codeを判断し、保存後に独立比較する必要がある。正常Nero／QuickTime併存のNero統一は呼出し側の責務である。gemはFFmpeg、backup、DB処理を追加しない。対象外構造は修復成功にならず、原本と計画を保持して再試行できる。
