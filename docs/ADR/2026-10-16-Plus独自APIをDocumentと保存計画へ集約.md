# Plus独自APIをDocumentと保存計画へ集約する

日付: 2026-10-16
状態: 前案・未実装。後続の[編集セッションによる簡素化案](2026-10-16-Plus独自APIを編集セッションへ簡素化.md)を現在の推奨案とする。以下は設計probeを作成した時点の判断として残す。

## 背景

taglib-ruby-plusの独自APIがMP4 File/Tag、snapshot、property、mdta、chapter、個別修復と保存経路へ分散している。機能追加ごとに入口・pending状態・例外・比較名が増え、呼出側が内部の保存経路や原本との関係を理解する必要がある。

ユーザーは独自APIの互換性を不要とし、整理案の設計を依頼した。今回は元のtaglib-ruby由来のAPIを別の低水準層として残し、独自APIだけを作り直す前提とする。実装の変更は行わない。

## 提案する決定と理由

1. 新しい独自契約を`TagLib::Plus::MP4`へ置く。元ラッパーへのmixin・alias・setter上書きと区別でき、将来の独自API増加を元ラッパーへ流し込まないため。
2. 公開入口を保存済み世代に結び付くDocumentに集約する。File/Tag双方の入口、metadata/chapterで異なるpending読取を解消するため。
3. 編集は不変snapshotとUpdate、原本との適合確認はSavePlanに分ける。利用者が変更内容を事前確認でき、構築の失敗でnative状態が部分更新されないため。
4. SavePlanだけがcommit!/write_to!を持つ。通常更新・特殊metadata保持・修復のwriter選択を内部へ閉じ、save_chaptersやsave_preserving_*の利用側分岐を減らすため。
5. 通常更新と修復は別々の計画とする。既存の限定修復・保持検証は互換性の問題ではなく安全性の条件であり、統一APIのために混在制限を外す根拠はないため。
6. 一般propertyはSymbolのsnake_caseへ統一し、aliasを削除する。高水準の正規化と型付きitems/mdtaの直接更新は区別する。正規化の副作用を隠さず、意図的な併存も表現できるため。
7. 名前付きのMetadataItem/MdtaValue/Artworkを公開し、keysの物理indexとcontext配置は観測情報へ分ける。位置依存配列の分解と、値と物理構造の混同をなくすため。
8. snapshotの厳密な値比較、別ファイル向け値比較、保存保持の内部照合を区別する。公開のstructure_equal?が成功しただけでは全ファイル保持を保証できないため。
9. 診断は領域ごとのReport、失敗は読取・計画・保存の境界別例外へそろえる。予期した未対応を調べられる形にしながら、不正構造やI/O障害を空結果へ握りつぶさないため。
10. 原本世代と計画のsource digestを検査する。成功後のDocumentは再openし、自動reopenを廃止する。書込済みとhandle状態の混在を減らし、古い診断位置やsnapshotの誤適用を防ぐため。

## 検討した別案

| 案 | 利点 | 採用しない理由 |
| --- | --- | --- |
| 既存File直下で名前とaliasだけを整理 | 実装変更が少ない | native pending、保留snapshot、修復状態と保存分岐の結合が残る |
| metadata/chapters/repairを各managerへ分割 | 呼出側で機能を見つけやすい | manager同士のpending状態・transaction共有が必要になり、入口と状態所有が増える |
| ブロックDSLで編集し、終了時に自動保存 | 短く書ける | ブロックを抜けることと保存を結び付け、計画の確認と明示的commitが曖昧になる |
| 何でも扱える汎用patch・汎用snapshot | 型数を減らせる | metadataとchapter、sample観測と修復で単位・適用能力・保持条件が異なる |
| 旧APIを残して新APIを追加 | 利用側を段階移行できる | 今回は互換性不要。入口の二重化を長期化させる |

## 影響と制限

破壊的変更になるため、呼出側の移行とリリースノートが必要。外部リポジトリを調査・変更する前に、この設計だけで移行完了とは扱わない。platform gemの配布方式やnative ABIを変更する決定ではない。

計画作成と厳密読取には原本digestや候補出力検証のコストがある。遅延capture/cacheの方針は実装前に詰める。mtime/sizeだけに検証を落とさない。

完全な外部writer排他、電源断耐性、任意の未知MP4構造対応は新しく保証しない。非上書きの別出力公開は現行とは異なる実装作業として受入テストを用意する。任意のunsafe/skip_verify操作は公開しない。

## 検証と次の判断

現行コード・既存設計書の静的確認と、後述のテスト専用adapterによる確認に基づく提案。製品の独自APIは未実装。

実装着手前に、専用名前空間への移動と「保存済みDocument＋明示的SavePlan」という利用モデルを確認する。これらは設計レビューの主要論点であり、今回のドキュメント作成を止める承認手順ではない。

詳細なAPI、旧API対応表、保存失敗契約、実装順、受入条件は[独自API再設計](../taglib-ruby-plus-api-redesign.md)に記載する。


## 追記: testコードで確認した境界

Document/Update/SavePlanの主要フローをtest/supportのadapterとして具体化し、既存backendと合成MP4で検証した。新規21件を含む関連84 tests / 1,054 assertionsが成功した。製品コードは変更していない。

- sectionは定義どおりHashとし、利用例の.data参照をfetch(:data)へ修正する。戻り値の外形と利用コードを一致させるため。
- mdta clearの期待値は既存キーを[]、不在キーを不在とする。全体復元の保存照合では、明示的に除いた復元先キーの空残存だけを許可する。厳密比較の過剰拒否とsame_values?の過剰許容をともに避けるため。
- 変更なしのwrite_to!はwriterを通さずbytesをコピーし、digest一致を要求する。利用者が要求していない再シリアライズを避けるため。
- cleanup失敗にtemporary_pathと元の保存失敗のcauseを残し、公開後の失敗はcommitted=trueとする。回復時に再試行してよいかを判断できるようにするため。

これらは設計の明確化として採用する。probeが再利用する旧値モデルや既存writerを、次期の全値モデル・全writerの実装と見なさない。修復・raw/context・native非依存値・新namespace/旧API削除等は未検証で、受入条件に残す。

詳細は[設計検証記録](../Memos/2026-10-16-Plus独自API設計のテスト検証.md)を参照。
