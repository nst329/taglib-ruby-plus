# ドキュメント一覧

インストール・利用例・開発手順は[README](../README.md)、リリースごとの変更は[CHANGELOG](../CHANGELOG.md)を参照してください。Ruby APIの詳細は`docs/taglib/`のYARDコメントにあります。

## 次期設計案

[MP4 snapshotのRuby API再設計](mp4-snapshot-redesign.md): 原版APIを維持し、fork追加APIを整理する案。未実装であり、以下の現行API契約とは区別してください。

## 機能別の設計・契約

| 目的 | 文書 |
| --- | --- |
| MP4チャプターの読み書き・保存 | [chapter API](mp4-chapter-api-design.md) |
| 通常タグ・画像・freeformの操作 | [metadata API](mp4-atomicparsley-replacement-design.md)・[受入検証](mp4-atomicparsley-replacement-validation.md) |
| propertyの入力変換・検証 | [property正規化](mp4-property-normalization-design.md) |
| 型・locale・複数値を保ったmdta置換 | [mdta一括置換](mp4-mdta-replace-design.md) |
| metadata全体の退避・比較・復元 | [MetadataSnapshot](mp4-metadata-snapshot-design.md) |
| snapshotの部分編集・差分・copyright | [snapshot追加API](mp4-snapshot-extensions-design.md) |
| snapshot値の取得・property期待値・chapter退避 | [値取得とChapterSnapshot](mp4-snapshot-access-chapter-design.md) |
| paddingを含む全chapter sampleの退避 | [chapter sample snapshot](mp4-chapter-sample-snapshot-design.md) |
| chapter参照の読取・指定関係の解除 | [参照読取と明示的解除](mp4-chapter-reference-read-design.md) |
| QuickTime chapterの欠落参照の除去 | [chapter参照修復](mp4-chapter-reference-repair-design.md) |
| RTP hint付きMP4の参照診断・明示的解除 | [RTP hintの検証と保持条件](mp4-rtp-hint-reference-repair-design.md) |
| 未対応metadataの限定保持保存・chapter時間診断と修復 | [限定MP4修復](mp4-unindexed-metadata-and-chapter-timing-repair-design.md) |
| colrとmetadata contextの構造診断・purl保存拒否 | [色構造とcontext診断](mp4-color-and-context-diagnostics.md) |
| macOS向けバイナリgemの配布 | [native gem](native-gem-design.md) |
| TagLib 2.3.2への最低要件変更 | [2.3.2移行](taglib-2.3.2-upgrade-design.md) |

nativeパッチの適用方法と構成は[patches/taglib](../patches/taglib/README.md)を参照してください。

## TagLib本体との責務・提案

- [mdta上流向け設計](mp4-mdta-upstream-design.md): native APIと保存処理の責務。隔離実装の検証と上流への取り込みは区別する。
- [ローカルパッチの設計履歴](mp4-mdta-taglib-core-proposal.md): 採用方式、旧案、実装時の判断。
- [初期のmdta保持調査](mp4-mdta-preservation-design.md): 問題の再現、旧案の比較、第一実装の経緯。現在のAPI契約は機能別設計を優先する。

[意思決定記録（ADR）](ADR/)には、採用理由・却下案・影響を記録しています。各設計書から関連する記録を参照できます。

## 検証記録

`Memos/`は実行時点の環境・結果・制約の記録です。過去の成功は現在の実行結果を意味せず、一時ディレクトリのコマンドは当時の環境を前提とします。snapshotの試作記録は実装検証の末尾に統合しています。

### mdtaとnative連携

- [mdta一括置換](Memos/2026-10-08-mdta一括置換の検証結果.md)
- [上流設計の先行native試作](Memos/2026-10-08-mdta上流設計のnative試作検証.md)
- [上流向け隔離実装](Memos/2026-10-08-mdta上流向け隔離実装の検証.md)
- [Ruby binding結合](Memos/2026-10-08-mdtaのRubyBinding結合検証.md)

### snapshot

- [公開metadata snapshot](Memos/2026-10-08-mp4公開snapshotの実装検証.md)
- [部分編集・差分・copyright](Memos/2026-10-09-snapshot追加APIの実装検証.md)
- [値取得・property期待値・chapter公開API](Memos/2026-10-09-snapshot値取得とchapter公開APIの実装検証.md)

### 修復・配布・障害調査

- [MP4色構造・purl・非ゼロ欠落参照の合成検証](Memos/2026-10-13-MP4診断保存の合成検証.md)
- [QuickTime欠落chapter参照](Memos/2026-10-09-QuickTime欠落chapter参照の検証.md)
- [複数tref修復と時間診断](Memos/2026-10-09-複数tref修復と時間診断の検証.md)
- [実MP4の複数tref修復](Memos/2026-10-09-実MP4複数tref修復検証-010226_001.md)
- [metadataとchapter時間の設計前テスト](Memos/2026-10-09-metadataとchapter時間の設計前テスト.md)
- [限定MP4修復の製品API](Memos/2026-10-09-限定MP4修復の実装検証.md)
- [2.3.2.12バイナリgem](Memos/2026-10-09-2.3.2.12のバイナリgem検証.md)
- [Ruby 4 / MP4 ItemMap SIGSEGV](Memos/2026-09-01-ruby4-mp4-item-map-segfault-investigation.md)

## 文書の整理方針

- 利用手順はルートREADME、API契約と制約は機能別設計、実行結果はMemosへ記載する。同じ説明を各文書へ複製しない。
- 同じ機能の試作・実装・内部整理は一つの検証記録へまとめ、時点と対象を明示する。独立した障害・実ファイル・配布検証は分ける。
- 古い案は判断理由や反例が残る場合に限り履歴として保持し、現在の設計への入口を示す。実装済み・未検証・上流未取り込みを混同しない。
- 判断理由と却下案はGit管理された`ADR/`に置く。設計書はAPI契約を記載し、詳細な判断理由はADRへのリンクで示す。未追跡のローカルADRは公開文書の参照先にしない。
- 文書の統合・削除時は参照リンクとgemspecの配布一覧も更新する。
