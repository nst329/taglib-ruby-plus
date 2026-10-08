# ADR: mdta提案APIをRuby bindingへ接続する

- 日付: 2026-10-08
- 状態: 実装・結合検証済み

## 前提

利用者の「本体」はTagLib C++本体を指す。Ruby bindingの実装・接続・結合検証は対象内であり、本体へ適用しないことを理由に残さない。C++本体のソースツリーやシステムライブラリには適用せず、一時コピーを使う。

## 判断と理由

1. extconfでgrouped APIとlegacy APIを実際にリンクして判別する。バージョン番号だけでは同じ2.3.2のパッチ差を区別できないため。
2. 共通adapterをSWIG入力と生成済みwrapperの両方からincludeする。Hashとバイナリ変換を二重実装せず、公開Ruby MdtaItemとreplace_mdta_itemsを維持するため。
3. grouped snapshotを既存のflatなRuby列へ展開する。型・locale・バイナリ・順序・重複を保持し、利用者の既存コードを書き換えないため。
4. 単一値setterはgrouped版で一要素の一括置換を呼ぶ。既存の「指定キーを単一値に置換する」意味を維持するため。
5. copyStateTo/applyChangesをbinding専用の別パッチ0002に分ける。安全な一時保存はraw item・削除・keys変更状態まで移送する必要があり、公開一覧だけから再構成すると失うため。上流用公開APIへbinding固有責務を混ぜないため。
6. 状態移送では転送先FileのAtom参照を保持し、モデルとrawをコピーする。別FileのAtomポインタを持ち込まないため。
7. title/artistの従来mdta fallbackをRubyへ置く。native上流提案は通常プロパティ連携を対象外としたが、Ruby利用者の読み取り互換性は維持するため。明示的な空の通常itemが存在する場合はその値を優先する。
8. mdta_statusを公開し、legacy版はunknownとする。不在と非対応を推測で区別しないため。grouped版でUnsupportedは部分一覧を返さず保存を拒否する。
9. 曖昧な新規fourCCを提案writerでも書込前に拒否する。結合検証で旧テストのzzzz追加が初期対応範囲外と判明し、書いてから拒否する経路をなくすため。従来nativeのzzzz互換テストは保持し、grouped版では拒否の専用テストを追加する。
10. 元のbindings・インストール済みnativeを変更せず、一時コピー内で全extensionをビルドする。異なるnative ABIを同じRubyプロセスへ混在させず、本体非適用の範囲を守るため。

## 検証と残る事項

mdta関連30テストが両backendで成功。全体Test::Unitは各259件中258件成功し、残る1件は以前からの借用wrapper追跡数の既知失敗（終了時に基準より1多い）。Minitestは両backendとも12件・54アサーション成功。正式な上流取り込みと全ABI検証、一般I/Oの永続化保証は別事項。

[結合検証記録](../Memos/2026-10-08-mdtaのRubyBinding結合検証.md)

## コミット前のリファクタリング

- Ruby Hashの生成を一つの変換関数へまとめ、native layoutの分岐はフィールドの取得だけにする。同じ公開fieldsとバイナリ変換を二重管理しないため。
- extconfのprobeを明示的なlayout指定から生成する。別probeの文字列置換に依存せず、必要symbolを読める形にするため。
- title/artistの動的定義を通常のメソッドと共通fallbackへ置き換える。native readerとの接続と通常item優先の責務を追いやすくするため。
- 提案パッチの空の文脈行を空白なしへ統一する。行末空白の指示を守り、git apply後のnativeソースが同一であることを確認した。

リファクタリング後、両backendで構成・コンパイルとmdta対象30テストが成功した。groupedは299アサーション、legacyは294アサーション。nativeの動作と対応範囲は変更していない。
