# paddingを含むchapter全sample公開API

## 背景

論理chapter_snapshotは先頭paddingを除外するため、ffprobeの全chapterとは件数と位置が異なる。sttsの総数・合計だけでは途中の変更を検出できない。MListNewにMP4 parserを複製しないため、gemが完全読取と保持判定を提供する。

## 決定と理由

- `File#chapter_sample_snapshot`と不変の`ChapterSampleSnapshot`を追加する。既存の論理snapshotを変更すると利用者のpadding・ミリ秒契約が変わるため、別APIとする。
- 利用者確認済みの「保存済みファイルのみ」を読む。pendingタグ・chapter・参照／時間修復は反映も変更もしない。nilは参照不在に限定し、不完全読取・非対応構造は既存ChapterSnapshotErrorで拒否する。
- strict ChapterReaderの境界・表・payload検証を共用する。raw sampleモードだけ整数media ticksとdurationを返し、co64も読む。native readerとの比較は論理APIの責務として維持する。submillisecondと64bit offsetをnativeの制約で丸めないためである。
- mdhd durationとstts合計、正のsample duration、空でない宣言済みchapter表をrawモードで要求する。部分成功を防ぐためである。既存論理APIの対応範囲は広げない。
- 単一音声chap参照、text sample、mdhd v0、単一identity editまたはeditなしから始める。複数参照、Nero併存、trim・empty edit・rate変更・複数editを推測で選ばない。
- sampleのstart/durationはmedia ticks、movie/editは別の値とする。修復前の短いidentity editもraw sampleを取得できるが、全sampleを覆わない場合はffprobe_comparisonをclippedとする。mediaデータの保持確認と表示期間の適合判定は異なる責務である。
- paddingは複数sampleの先頭・start=0・空titleが同時に成立する場合だけとする。中間・末尾、単一sampleの空titleは保持する。これは既存writer/論理readerの規約で、生成由来を証明する意味ではない。
- signature v1はtrack ID、参照元ID、media時計とduration、sample数、各位置・start/duration・payload長・payload全体のSHA256を固定幅で連結してSHA256にする。物理offsetとmovie/editを除外し、移動と時間修復では一致、欠落・並び替え・payload変更では不一致にする。
- `preserved_equal?`は上記の保持契約だけを比較する。movie/editの適合は別途require_ffprobe_comparable!で要求する。二つを混ぜると正常な時間修復をデータ破損と判定してしまうためである。
- FFmpegは製品依存に追加しない。テストの独立照合だけに使用し、codec警告の採否・stage・DBはMListNewに残す。

## 任意のprofile読取専用診断

今回は追加しない。既存repair_native_chapter_timingは一致時にpending計画を設定するため、UIの読取専用診断には代用できない。将来の`chapter_timing_profile_diagnostics(profile:)`では、現行editorのfingerprint判定を共有し、候補trackごとに適合・不適合理由と必要な参照修復を返す設計を提案する。fingerprint一致と完全な修復適用可否は分ける必要がある。今回の全sample APIにprofile判定や書込計画を混ぜない。

## 影響

既存のchapter_snapshot・保存API・時間修復profileは変更しない。新APIは保存済みのQuickTime text章に限定され、取得だけで原本・pendingを変更しない。署名はmedia sample保持の検証用で、mdat全体の完全性・作品同一性・暗号学的署名を保証するものではない。

## リリース判断

利用者のcommit・push・tag・binary gem作成指示に従い2.3.2.13として公開する。2.3.2.12の既存tagを上書きしない。今回nativeコードに変更はないため、ローカルarm64 gemは既に検証済みのRuby 4.0／macOS最小12.0向けextensionとパッチ済みTagLibを再使用し、新Ruby実装を同梱する。tag pushによる既存workflowではarm64／Intelのnativeを再ビルドし、インストール済みgemで全sample取得と通常タグ保存後の保持をsmoke検証してGitHub Packagesへ公開する。
