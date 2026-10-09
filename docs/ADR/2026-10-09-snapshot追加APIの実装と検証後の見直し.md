# snapshot追加APIの実装と検証後の見直し

日付: 2026-10-09
状態: 採用・実装済み（2.3.2.9）

## 背景

試作後の設計に従い4機能を実装した。全property・snapshot・両backend保存を組み合わせた検証で、既存propertyの一部の未登録atomとfreeform型の未確定を検出した。

## 決定と理由

- without/withは領域別のキー除外と型付き値全置換とし、元snapshotを変更しない。全体復元の期待状態を明示できるため。
- 入力検証をMetadataSnapshot.newと共有し、保存幅は復元commit前のnative検証に委ねる。writer対応表をRubyへ重複させないため。
- logical_equal?とdiffはlogical_valuesを共有する。空差分と論理一致の契約がずれないため。
- 順序のみの変化は型付き値のtallyで判定する。それ以外は重なる位置のフィールド比較とする。編集距離や列対応の推測を導入せず、before/afterで確認できる単純な診断を選んだため。
- binaryと画像はサイズとSHA-256、通常文字列は256 bytesを超えたら同じ縮約を使う。生値比較を保ちながら診断表示の肥大化を避けるため。
- property_update_effectsはoperationをset/removeで指定し、領域ごとの設定・削除可能キーを返す。現在値の実差分と、操作可能範囲を区別するため。
- native_setterはtitleのみ対応し、通常atomのset/remove両方を返す。空文字・nilの削除を説明でき、未検証setterを説明しないため。
- title=は既存Item.from_string_listとItemMap操作を再利用し、normalized setterと共通property_targetsを使う。文字列変換・空値削除・mdta保持を維持し、説明専用表と新binding APIを作らないため。
- copyrightは©cpyだけを高水準propertyへ追加する。ユーザーのiTunes形式要件と保存検証結果に従うため。
- cprt・mdta copyrightは独立して保持し、native汎用PropertyMapのCOPYRIGHT=cprtも維持する。許可外タグと別APIの意味を変更しないため。
- ©cpyに加えldes/keyw/purdもnative Text atomへ登録する。全property検証でmdta構造のsnapshot取得が拒否される原因を特定したため。
- freeform propertyの文字列型をsetterでUTF-8の1へ確定する。contentRatingの保存前型255とwriter推測後型1の不一致をなくし、snapshotにも適用できるため。
- native buildのpatch適用処理を小さな独立ファイルへ分離し、snapshot適用済みなら最初の重複patchを再適用しない。独立追加patchの導入後に、最後のpatchだけでは完了判定できなくなったため。新規・更新・冪等性をテストした。
- 期待snapshotを受け取るsave引数は追加しない。MListNewの候補ファイル検証と原本置換の責務を維持するため。

## 検証

関連テスト: legacy 81 tests / 838 assertions、grouped 81 tests / 843 assertions、成功・省略なし。
全体: 各302 tests、既知wrapper数の1 failureのみ。変更前HEADでも再現し、今回は無関係タグ保持の条件を弱めずに記録する。
別プロセスMinitest: 各12 runs / 54 assertions成功。
実ファイル原本・外部MListNew・インストール済みgemは変更していない。

## 影響

新native patchを含めた2.3.2.9のビルドが必要。型付きsnapshotの全体復元、既存保存の原本保護・committed区別は維持。
既存longdesc/keyword/purchaseDate/contentRatingが保存前snapshotと組み合わせられる。

[詳細設計](../mp4-snapshot-extensions-design.md) / [検証記録](../../docs/Memos/2026-10-09-snapshot追加APIの実装検証.md)
