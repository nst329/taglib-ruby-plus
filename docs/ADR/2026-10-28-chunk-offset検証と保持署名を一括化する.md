# ADR: chunk offset検証と保持署名を一括化する

日付: 2026-10-28
状態: 採用（2.3.2.42）

## 背景

chapter参照の解析は、stco/co64の全chunk offsetについてmdat範囲内かを1件ずつ線形探索し、保持署名も各offsetをmdat内の相対位置へ変換した配列をそのまま保持していた。offset数に比例する配列と、mdat数に比例する探索が、診断と限定修復計画のCPU・メモリ双方を押し上げていた。108kサンプル・162k offsetの試作では、`diagnose(:chapter_references)`が11.9ms、`plan_limited_repairs`が86.4msだった。

## 決定

- mdatが1つの通常MP4では、offsetの最小値と最大値だけをmdat範囲と比較して全offsetの範囲内を判定する。offsetの順序・重複は署名側で扱う。
- mdatが複数の場合は、開始位置で昇順な`@mdat_ranges`を二分探索して所属mdatを確定する。mdat外offsetは従来どおり`malformed`で拒否する。
- 保持署名は`[header, width, count, digest]`とする。単一mdatはoffsetからmdat開始位置を引いた相対位置列、複数mdatは所属mdat index列と相対位置列を、幅に応じた`N*`/`Q>*`で連結してSHA-256へ畳み込む。
- mdat indexを署名に含めるのは、複数mdatで同じ相対位置のchunkが別mdatへ移った場合を保持と扱わないためである。単一mdatはindexを省く。

署名はgem内部の保存前後比較にだけ使い、公開snapshotの`preservation_signature`（v1/v2）とは別物である。`ChapterReferences#preservation_signature`の利用箇所は`==`比較だけなので、配列からdigestへの変更は内部に限定される。

## 却下案

- 全offsetを毎回mdat範囲配列と総当たり比較する案は、複数mdatでoffset数×mdat数に比例するため採用しない。
- offset配列を常時cacheして比較する案は、chunk数に比例するメモリを診断・保存計画の間保持するため採用しない。
- 相対位置配列をそのまま署名として保持する案は、比較時のメモリとコピーが大きく、保存後の独立検証でも同じ配列を作る必要があるため採用しない。

## I/Oへの影響

読み取るatom・bytesと回数は変更しない。削減対象は解析後のCPUとメモリだけであり、ファイルI/Oは増減しない。試作では上記2操作が2.9ms、7.8msまで短縮したが、最終実装での再計測は未実施である。数値を実装後の実測として扱わない。

## 検証

`test/mp4_chapter_references_test.rb`に、先頭へfreeを追加して全chunkを同じだけ移動しても保持署名が一致する回帰、mdat内のchunk位置変更を検出する回帰、mdatを分割しても全chunkとmdatが同じだけ移動すれば署名が一致する回帰を追加した。既存のstco/co64・複数mdat・mdat外offset拒否・保存後検証を含む35 tests / 557 assertionsが成功した。
