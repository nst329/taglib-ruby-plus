# QuickTimeと不正mdtaの限定修復を一つの候補へ合成する

## 2026-10-21追記: 安全なcontext pairの拡張実装

### 追加実装後のリファクタリング

context集合のpolicy呼出だけを包む補助メソッドを削除し、親識別をreader/editorとも絶対offsetと終端の組へ統一した。editor内のmeta子atomとhandlerはcontextごとに一度解析し、集合検証と編集で共有する。重複したraw bytesの切り出しとatom走査を避け、atom件数上限を重複解析で消費しないためである。キャッシュはeditorインスタンス内だけに保持し、別世代へ流用しない。ファイル読取回数・media payload読込範囲は増やさず、上限内の解析結果を編集終了まで保持するメモリと引き換えに走査CPUと一時bytes割当を減らす。総bytesや性能の削減量は未計測。

同種handlerの拒否試験が3 contextを生成していた点も修正し、mdir+mdirとmdta+mdtaを正確に2 contextで検証する。公開API、reason_code、保存経路と個別item検証は維持する。

5 tests / 45 assertionsの設計probeにより、現行の診断と限定修復の不一致、別udtaをpathで区別できない問題、mdta先行時のnative通常値欠落、未知meta子atomの検査不足を確認した。

採用案は、取得済みatom情報を使う共通検証器で、親の実体・個別context構造・集合の許可条件を分けて検証する方式とする。許可は同一moov直下の同一udtaにある検証済みmdir+mdtaの2個だけで、順序は問わない。汎用性は検証責務の再利用に置き、任意数contextや拡張可能なrule frameworkは採用しない。実装ではlimited editorのraw構造検証とMetadataStructureReaderの親座標検証を共通条件として揃え、必要範囲に対して複雑さを増やさず安全境界を保った。

mdirはnativeへ変換せずraw保持し、mdtaだけを既存raw置換へ渡す。診断・計画・保存後検証は同じ条件を使用する。構造診断とnative snapshot能力を分離し、後続mdirがnativeから見えなくてもrawで検証する一方、不完全snapshotの取得許可には使わない。issueの一括除外や未知構造の成功fallbackは採用しない。

計画時の検証器はI/Oせず既存解析結果を使う。保存後は共通条件を再確認するためmetadata構造readerを一度だけ呼び、root/moov/udta/metaの境界とheaderだけを走査する。mdat payloadは読まない。製品経路のI/O回数・bytesは今回未計測。

独立fixture候補のraw保持・decode成功に加え、公開apply/save!で不正indexだけを除去し、mdir保持・原本不変・独立再open後unchangedを確認した。詳細と未検証条件は[併用設計の拡張節](../mp4-combined-limited-repair-design.md)を参照する。

日付: 2026-10-20
状態: 採用・実装済み。対象versionは2.3.2.38。

## 背景

現行公開APIは壊れたQuickTime専用trackを限定除去できるが、不正mdta indexの限定除去を提供しない。内部のunindexed保存は不正itemを保持するため代替にならない。既存保存の完全metadata snapshot要求も併用を妨げる。

## 決定と理由

- 新しい診断計画・登録操作を追加し、既存save!を保存境界として共用する。公開APIだけでは要求を満たせず、アプリのraw patchを残すとoffset・世代・検証が分散するため。
- 要否判定に許可設定を使わず、登録時に必要操作がすべて許可されているか確認する。metadata許可と必要性の混同によるQuickTime単独修復の拒否を防ぐため。
- metadataは正常keysの件数Kに対するindex 0およびK超過のitemを、位置・件数によらず除去する。正常indexとの混在・重複を扱い、対象外bytesを保持する。0限定では同じ原因の範囲外参照を取り残すため。keysやhandlerの変更、再採番、意味の推定は行わない。keys破損・fourccとの曖昧性・未知構造・読取失敗はblockedまたはErrorにする。
- 数値indexは32bit全域を検査し、既存の先頭byte=0という識別制約を一般化する。既知通常fourccを誤削除しないよう、型の解釈が確定できないitemは拒否する。既存index 0保持機能は変更しない。
- 二つの完成済み計画を逐次保存せず、同じ原本座標から一つのmoov編集を生成する。offset補正を一度にまとめ、全面copyと中間世代の照合を減らすため。
- 修復経路のmetadata完全snapshot前提をraw保持基準へ置き換える。破損入力を扱いつつ、対象外item・画像のbytesを検証できるため。meta全体の検証除外はしない。
- 別出力保存を必須とし、独立再読込・出力digest・既存committed/cleanup契約を共用する。原本の最終置換を利用側へ残すため。
- 通常編集と他repairの混在拒否は維持する。今回必要な二操作だけを扱い、汎用修復フレームワークを導入しないため。
- 無変更は保存を呼ばない。明示的な無変更save-asの既存コピー契約は変えない。

## 代替案

現行APIの逐次保存はmetadata限定除去が公開されておらず、raw patchと二段階copyを残す。内部sanitize流用はkeys削除とmdir化を伴い、itemだけの除去契約を満たさない。metadata全体置換は対象外raw情報保持の根拠にならない。よっていずれも今回の推奨方式にはしない。

## I/Oと影響

標準モードの保存は原本Nの一回copyと候補N'の独立scanを基本とし、hashを各走査へ統合する。構造・値検証の範囲読取とstrict世代SHAは追加となる。二段保存の中間copyを削減する一方、上限内moov候補のメモリとhash CPUを使う。コピーと走査の回数はテストで確認し、併用修復の総bytesは未計測とする。
既存単独APIの公開契約は維持し、新しい診断計画・登録API、結果付加項目、別出力制約を実装した。計画は最新の一つだけをFile内に保持し、メモリ寿命を限定する。

詳細な状態表、限定条件、保持検証、障害・I/O受入条件は[併用設計](../mp4-combined-limited-repair-design.md)に記録する。

## 設計probeによる改訂

7 tests / 41 assertionsの設計probeで、任意位置の不正index除去とQuickTime除去を一つの候補へ合成し、raw metadata・Nero・mdat・残存track・相対chunk位置の保持を確認した。現行公開保存の拒否と、現行readerが上位byte非0のindexをfourcc扱いすることも再現した。

同じ4bytesが通常fourccにも32bit indexにもなるため、全域を無条件に自動識別する案は採用しない。数値表として全itemを扱う`:indexed`、既知通常fourccを予約する`:mixed_known_fourcc`の解釈profileを呼出側が明示する案へ改訂する。未指定で解釈が確定しない場合はblockedとする。理由は、keys範囲外という情報だけでは対象外通常itemの誤削除を防げないためである。profileは許可方針として扱い、gem側で構造・保持・offset・世代を検証する責務は維持する。

設計probeの成功は候補処理の確認である。その後に公開API・保存障害契約・I/O回数の製品テストを追加した。他backendの検証完了や総bytes削減の実測とは区別する。
