# metadata完全復元は全値とcontextを一括置換する

状態: 採用・実装済み。受入probeと既存回帰テストを通過。

## 背景

2.3.2.21の公開APIで、mdirからmdta再mux先への直接代入、任意の型付きmdta、画像取得に失敗した。
mainのeb6182cでも、少数itemの復元は復元先値を保持し、title等の通常itemをmdtaへ変換するため、完全復元契約と一致しない。
使用側は旧File、native Tag、Internalへ依存せずに完全復元する必要がある。

## 決定案と理由

- 既存`file.metadata = snapshot`を完全置換の入口とする。with/withoutは部分編集のままとする。
  mergeとreplaceの意味を1つの操作で暗黙に切り替えず、新APIや互換層を増やさないため。
- 全通常itemと全mdta値から出力contextを生成する。通常itemだけならmdir、mdtaだけならmdta、両方ならmdir→mdta。
  purl限定の補修や、通常itemを別のkeyへ意味変換する対応表では、型・locale・全値の保持を保証できないため。
- MetadataItemは型付き値を所有し、purl rawはsnapshotの復元情報として保持する。別snapshotからrawを伴わずitemだけ移す入力は拒否する。
  rawを推測・省略せず、公開APIだけで原因を確認できる保存契約にするため。全itemのwire所有は後続整理とする。
- 通常itemとmdtaの同居を、既存metaの置換・追加・削除を含む1つの保存計画へ統合する。
  itemの少なさで復元先値を残す特別経路をなくし、保存前に全体の保持可否を検証するため。
- 内部責務を「snapshotの編集・検証」「contextの構成」「Fileの保存」の3つに整理する。
  保存手順と値の変換を分離し、通常編集と完全復元の経路を共通化するため。クラス数の増加は前提にしない。
- 代入時はpreflightと候補採用までとし、最終保存計画はsave!時に現在の全候補から作る。
  代入後のchapter編集などを、古い計画で保存しないため。
- 空snapshotは空の単一mdirに統一する。無変更保存ではcontextを再構成しない。
  空metadataの出力分岐を減らし、不要なファイル書換えを避けるため。
- artworkは公開symbolで読み書きする。withにartworks引数を追加し、空配列でclearする。
  利用側にcovr形式整数や内部表現を扱わせないため。
- 公開Errorへ元のcode/issuesを引き継ぎ、preflightで可能な拒否を行う。
  原因をgenericなsaveへ潰さず、値を省略するfallbackも不要にするため。

## 比較した案

全通常itemをmdtaへ変換する案は採用しない。任意itemの意味対応がなく、元のitem型を変えてしまうため。
比較条件だけを緩める案も採用しない。復元先だけの値の残存や型変換を成功扱いするおそれがあるため。

## 検証と残作業

15ケース・98 assertionsの受入probeで、全item/mdta値、画像、purl、media、章、ffprobe title単一化、失敗時の原本SHA維持を確認した。
保存先のmdtaは、通常itemを意味変換せずmdirへ、mdta値をmdtaへ再構成する。
MetadataItem単位での全item wire所有、逆方向復元、metadata contextがない入力の生成は残課題であり、対応不能な構造は明示拒否する。

この案は採用・実装時に、`2026-10-16-mdta通常item移行の一般化.md`の通常item移行方針を置き換える。
詳細: [完全復元設計](../mp4-metadata-complete-restore-design.md)。

## 軽微な内部整理

artwork入力の検証とcovr行の生成をconstructorとwithで共用する。
両入口で形式・重複指定の拒否条件がずれることを防ぎ、公開契約は維持するため。
context templateの構築は保持する子atomを明示したbytes列に整理し、不要な中間変数を除く。
Plus専用Fileのatom計画適用を内部メソッドへ集約する。native handleの生存期間とコピー生成手順を揃え、staging前の重複コピーを除くため。
