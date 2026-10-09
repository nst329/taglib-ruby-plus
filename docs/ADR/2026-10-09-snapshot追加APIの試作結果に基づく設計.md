# snapshot追加APIの試作結果に基づく設計

日付: 2026-10-09
状態: 試作後の設計記録。実装時の最終判断は[実装ADR](2026-10-09-snapshot追加APIの実装と検証後の見直し.md)を参照。

## 背景

MListNew移行では、型情報を保持した期待snapshotの生成、保存検証の差分説明、setterの更新影響の共通化が必要。
設計を先に固定せず、テスト用試作でlegacy/groupedの実MP4保存まで検証した。各7 tests / 77 assertions成功。

## 決定と理由

- 部分編集はキー単位の明示的置換と除外にする。暗黙mergeやappendは期待状態を曖昧にするため採用しない。
- itemsは既存型付き行、mdtaは型・locale・binaryの順序付き値配列を使う。新しい型推測層を作らず情報落ちを防ぐ。
- source_structureは取得元の観測情報とする。編集だけでは復元先の配置を知れないため再生成しない。
- mdta新キーの仮indexは元最大値から採番する。既存indexと衝突せず、復元先の再割当と区別できるため。
- 入力検証とnative writer検証の二段階を維持する。Ruby側にwriter制約の重複表を持つとずれるため。
- diffはlogical_equal?と同じ正規化を使う。値なしキー・indexは構造情報であり、別ファイルへの復元を不一致にしないため。
- binary/hashは診断表示用とし、生値の比較を維持する。既存の一致基準を変えないため。
- 更新影響は可能な対象と操作意図を返し、set_propertyとnative setterを区別する。実測でtitleのmdta削除有無が異なるため。
- copyrightは既存property APIへ©cpyを追加する。ユーザーがiTunes形式の©cpyを必須と明示し、nativeのText handler登録試作で両backendの保存・再読込も成功したため。初期のcprt追加案は撤回する。
- ©cpyをnativeの既知Text atomとして登録する。mdta構造の既知atom検査を通し、既存text parser/writerとsnapshotをそのまま使えるため。
- cprtとmdta copyrightは独立して保持し、fallback・自動移行しない。許可された©cpy以外を変更しない要件を満たすため。
- native汎用PropertyMapのCOPYRIGHT=cprtは維持する。今回の対象はRubyのproperty APIであり、既存の汎用PropertyMapの互換性を変える必要がないため。
- 許可外変更の拒否は原本rename前に期待snapshotで検証する。既存saveは変更後の状態を期待値にするので、許可範囲を単独では判定できないため。
- 製品save APIの変更は今回決めず、MListNewの候補ファイル検証を第一案とする。試作だけで保存契約の拡張を確定しないため。

## 影響

製品APIはまだ変更しない。詳細分類付きdiff・全property/削除操作・copyrightの共通定数への統合は製品実装時の追加検証対象。

追加native試作とcopyrightテスト、既存関連テストは両backendで各37 tests / 424 assertions成功。製品nativeパッチにはまだ取り込んでいない。

最終実装の詳細: [設計](../mp4-snapshot-extensions-design.md)
試験記録: [検証メモ](../../docs/Memos/2026-10-09-snapshot追加APIの試作検証.md)
