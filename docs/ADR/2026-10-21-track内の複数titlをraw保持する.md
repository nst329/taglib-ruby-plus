# track内の複数titlを位置依存のない非対象データとしてraw保持する

- 日付: 2026-10-21
- 状態: 採用

## 背景

2.3.2.36のChapterReferencesはmovieのudtaにある単一titlだけを許可していた。ALDN-046には第3trackのudtaに通常header・44 bytesのtitlが2個あり、既存のpayload profileには一致するが配置検査で停止した。原本は読み取り専用で調査し、構造境界の破損を認めなかった。

ETSI TS 126 244 V16.0.0 §8.2・表8.1ではmovie/trackのudtaと、version/flags=0・packed language・NUL終端UTF-8/UTF-16のTitleが定義される。payloadにはファイルoffsetやtrack IDが含まれない。同一言語の重複は同節の個数制約と別問題であり、規格適合を保証する理由にはならないが、既存データをそのまま保持する障害にもならない。

参照: https://www.etsi.org/deliver/etsi_ts/126200_126299/126244/16.00.00_60/ts_126244v160000p.pdf

## 決定と理由

1. movie/trackのudtaを共通profileとして扱い、track ID、producer、個数、文字列の一致による制限を設けない。全titlを個別に検証し、同一言語の重複もraw保持する。意味の修復や重複統合は今回の限定操作ではないため行わない。
2. 8/16-byteの明示size headerを許可する。どちらも共通parserが境界を検証し、rendererがraw leafを返せるためである。親末尾に依存するsize=0は今回のprofileでは拒否を維持する。
3. 未対応配置、version/flags/言語、不正文字列はblocked。titlを無条件に許可したり、他種boxの許可範囲を広げたりしない。削除対象chapter track内のtitlは移動・削除をせず保持できないため拒否する。
4. 保存後のTitle署名はheader込みのraw bytesにする。payloadだけの比較ではheader形式の変化を検出できないためである。構造上の配置・順序・個数は既存の階層署名で比較する。
5. 内部ChapterReferenceErrorに不変issuesを追加し、番号付きpath、絶対offset、header込みsizeを伝播する。例外の文字列から固定位置を推測する診断は廃止する。構造解析全体の失敗は両領域の同一issuesにscope/affected_areas/diagnosisを追加し、未診断領域の正常扱いを防ぐ。
6. UTF-16の内部NULを16-bit符号単位で検査する。隣接文字間の00 00を終端と誤判定するbyte検索を修正する。文字列の再生成はしない。

## I/Oと複雑さ

既存のatom indexからpathを一回の走査で計算する。追加のファイル走査や解析用コピーは作らない。メモリは走査中のpathとtitlごとの小さなcontext・既存payload cacheに比例する。保持するmoovは既存の64 MiB上限内である。

計画は一回取得したmoov rawから検証・Title署名・renderを行い、titlごとの追加readを発生させない。診断のみのcapture_raw=falseは必要な各titl範囲を読む。mdatの読取・コピー回数は既存保存フローのままで、公開前の独立検証を省略しない。原本の読取専用調査ではatom headerと対象payloadのみを読み、mdat本文を走査しない。実保存検証の全体SHA走査は原本不変・出力一致を確認する別目的として実施した。性能改善の実測値は主張しない。

汎用の未知box passthroughや任意path許可は位置依存情報を見落とすため採用しない。producerごとの分岐、同一言語のdeduplication、titlを別階層へ移す方式も安全保持の目的に不要なため採用しない。

## 影響と検証

公開メソッド引数、session/世代確認、原子的保存、publication_status契約を維持する。MListNewの修復計画・blocked尊重に変更は不要で、修正版gemへの更新が必要。リリース・gem公開はこの作業では行わない。

第3trackの重複Titleを含むfixture、movie/複数trackの混在、拡張header、UTF-8/UTF-16BE、不正payload、未対応配置、size=0、削除対象track、保存失敗時の原本保持を確認する。実原本は変更せず、一時領域への別出力と独立再読込で検証する。結果と未検証条件は[検証記録](../Memos/2026-10-21-track内titlの調査と検証.md)、対応仕様は[主資料](../mp4-chapter-plan-safety-design.md)に記録する。

## 保持対応後のリファクタリング

- 一覧処理から単一Titleの検証を分離する。各atomの配置・header・payloadを検証し、例外へ実座標を付ける責務を一箇所にまとめるためである。検証を通過したpayloadだけを従来のcacheへ登録する。
- Title contextはoffsetをキーにしたHashから順序付きArrayへ変更する。利用箇所は列挙と範囲検索だけであり、offset検索は不要なためである。走査順序・重複を維持し、track削除前の検索で中間のvalues配列を作らない。
- Plus側の修復エラー診断補完をprivate helperへ集約する。具体的なissuesはそのまま保持し、空の場合だけ各入口が指定したlocation/pathを補完する。内部editorにも同じ責務の小さなhelperを置き、異なる層を継承や共通基底クラスで結合しない。診断のキー・値、blocked条件、例外のcode/phaseを変更しない。
- atom indexの走査回数、moov取得回数、titl範囲読取、mediaコピー・独立再読込は変更しない。Array化によるメモリ削減の実測値は主張しない。公開API・世代確認・保存契約を維持する。
