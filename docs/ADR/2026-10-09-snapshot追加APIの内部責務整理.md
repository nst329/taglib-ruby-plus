# snapshot追加APIの内部責務整理

日付: 2026-10-09
状態: 採用・実装済み。公開APIとversion 2.3.2.9の契約は維持。

## 背景

追加APIの実装で、snapshot再構築の重複、mdta更新のキーごとの配列走査、差分判定と診断表示の混在、property更新対象の再解決が残っていた。

## 決定と理由

- without/withの再構築をedited_snapshotへ集約する。version・取得元構造の引渡しと再検証を共通化するため。
- mdta全値置換をreplace_mdta_valuesへ分離し、キー検索に挿入順序を保つHashを使う。既存index・キー位置を保ったまま、更新ごとの全キー走査を避けるため。
- diffは領域単位の比較をdiff_areaへ委ねる。公開入口を入力検証・論理値の解決・不変化の流れとして読めるようにするため。
- payloadの変更分類と診断表示をpayload_changes/diagnostic_payloadへ分離する。生値の比較と表示用縮約が混同されないようにするため。
- 順序付き値列のフィールド比較は、重なる位置だけを直接参照する。zipとfirstの一時配列を作らず、従来の対応位置による診断を維持するため。
- propertyの検証済み候補に共通の更新対象と値を保持し、native commit時の対象再解決をなくす。setterと影響APIの定義共有を保ちながら同じ解決を繰り返さないため。
- nativeコード、保存基盤、未知タグの扱い、公開型定義は変更しない。今回の整理に新しい機構は必要ないため。

## 検証と影響

構文・空白検査成功。関連範囲はlegacy 81 tests / 838 assertions、grouped 81 tests / 843 assertions、失敗・省略なし。
型・順序・重複・空値・index、不正入力、差分の分類・縮約、全propertyの更新影響、title=互換性、copyrightと保存時の原本保護を確認。
前回成功した全体範囲の再実行は、内部責務の整理だけを理由に繰り返さない。全体の既知wrapper数failureは前回記録のまま。

[設計](../mp4-snapshot-extensions-design.md) / [検証メモ](../../docs/Memos/2026-10-09-snapshot追加APIのリファクタリング検証.md)
