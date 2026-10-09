# ADR: 公開MP4 snapshotをnative候補の一括commitで復元する

状態: 採用。2.3.2.8向け実装、未配布。

## 背景

一キーreplace_mdta_itemsは複数値消失を解消するが、通常item・画像・複数mdtaキーの復元全体を失敗時に巻き戻せない。既存内部snapshotは比較専用で、未知型、atomDataType、値のないkeysエントリを公開退避契約として扱えない。

## 決定と理由

- 不変なRuby所有MetadataSnapshotと読み取り専用MetadataDiagnosticsを公開する。ファイルを閉じても利用でき、診断と修復を混同しないため。
- nativeはItemMapとmdta状態の候補を作り、全検証・割当後に移送する。Ruby setter反復やclose/reopenによるrollbackでは部分更新や借用wrapperの破壊が残るため。
- 元keys表を維持し、復元元にだけあるキーを追加する。復元先にだけあるキーは値を消す。物理削除によるindex詰め直しを避けるため。
- 通常itemは実writer→parserの型・atomDataType・payload往復で検証する。Ruby整数範囲だけではtmpoなどの保存幅を検証できないため。検証用FileはByteVectorStreamだけを使い実動画を書かない。
- StringのNULは長さ付きUTF-8 bindingで扱い、native parserで失われる通常textは拒否する。mdtaとbinaryはNUL/空値を保持する。
- 診断はraw構造とnative表現の両方を確認し、未表現atom、重複通常atom、通常locale、scalar複数値などを拒否する。native読み取り済み値だけの検証では読込時の縮退を検出できないため。
- disk診断にはFileから初回取得した通常itemの型を使う。未保存の編集によってdisk上の健全なitemを未表現と誤診しないため。
- 通常itemのtyped読み取りを内部保存比較と共通化する。freeformの未保存TypeUndefinedは従来writerどおり推定し、単一setterの互換性を維持する。
- 内部mdta保存比較をkey_index単位に整理し、同じキー内の順序は厳密に維持する。legacyの一括復元で異なるキー間の物理出力順が変わるため。公開logical比較は別ファイルのindex差を許容し、structure比較はkeys順・indexも比較する。
- 保存は既存の一時コピー・再読込比較・rename・reopenを再利用する。二重の保存基盤を作らず既存phase/committed契約を維持するため。
- native変更はdownstreamパッチとgrouped binding用パッチとして管理し、vendorビルドに接続する。上流TagLib C++本体には適用しない。

## 影響

対応構造以外は取得・復元前に明示的に失敗する。画像は通常itemとして一度だけ退避する。字幕のmux・検証はMListNewに残す。チャプター復元、未知atom完全コピー、copyright/更新影響APIは初版に追加しない。

最低実装versionは2.3.2.8。新nativeがない環境ではcapabilitiesをfalseにし、既存APIを利用できる。正式配布・Intel/他OSの確認は未完了。

## 2026-10-09: 実装のリファクタリング

- snapshot構築の通常item検証、mdta検証、binary変換を責務ごとに分ける。全入力検証後に不変値を作る順序を読み取りやすくするため。
- capture/restoreの構造・能力チェックを共通化し、同じ診断reportのcapabilitiesを利用する。重複したnative keys取得と判定のずれを避けるため。
- 復元候補ItemMapの作成・検証を分離する。主要フローを入力再検証→構造確認→候補作成→native一括commitとして明示するため。
- 通常atomのキー復号を構造検証から分離し、data子atomの選択結果をtext診断でも再利用する。責務と重複走査を整理するため。
- 内部保存比較の旧binding向けfallbackも既存KINDS表を参照する。9型の対応表を重複させず、旧getterと戻り値形式を維持するため。

公開API、エラーcode/phase、検証順、native commit、保存基盤、対応構造は維持する。native patchやbindingの変更は不要。

## 2026-10-09: バイナリgemの配布検証

既存のvタグ起点workflowを利用し、arm64-darwinとx86_64-darwinのnative gemを作成する。インストールしたgemからsnapshot能力の取得、コピーへの復元、保存・再読込の論理一致までsmoke確認する。単にFileクラスが存在するだけでは新nativeパッチの同梱を確認できないため。fixture原本は読み取りのみ。既存のGitHub Packages公開経路を維持する。
