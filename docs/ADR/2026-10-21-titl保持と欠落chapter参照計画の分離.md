# ADR: titlを条件付きで保持し、欠落chapter参照解除をtrack除去と分離する

日付: 2026-10-21
状態: 採用・実装済み（実作品確認は未実施）

## 背景

依頼者の2.3.2.32診断では、udta/titlの構造未対応と、字幕sourceから欠落targetへのchap参照がMListNewの処理を停止させる。現在は読取診断と編集検証の役割が伝わりにくく、計画で例外messageも失われる。実作品のpayloadは未確認である。

## 決定案と理由

- titlを単に許可一覧へ追加しない。規格の位置非依存Title boxに一致する限定profileだけを検証し、raw bytesを保持する。atom名だけでは独自形式や位置依存データの不在を証明できないため。
- 初期profileはmoov/udta直下、単一、通常header、version/flags=0、妥当なlanguageとNUL終端UTF-8/BOM付きUTF-16BEに限定する。広範な独自形式対応より、検証できる範囲を明確にすることを優先する。
- 正常QuickTimeを限定除去しない。chapterのcompleteは編集可能性を意味せず、修復不要と削除希望も異なるため。
- 既存専用track除去のstatus/reason_codeとsubtitle_source拒否を維持する。欠落参照解除にtrack削除の許可を流用すると通常字幕の誤削除へつながるため。
- 既存参照解除エンジン上に、欠落だけを選ぶPlus計画APIを追加した。既存detach APIだけをアプリに組み合わせさせる案は小さいが、MListNewがblocked計画を迂回する構成になるため採用しない。
- 限定修復へ明示操作remove_dangling_chapter_referencesを追加し、全参照欠落だけを接続した。実在targetとの混在は個別計画で扱い、一部修復を全体成功としない。
- message/issuesを追加し、場所・元track ID/handler・target ID・診断indexを保持する。既存reason_codeの変更や優先順位変更で原因を表現する案より互換性を保てるため。
- 診断と計画はmoovと既存世代キャッシュを再利用し、titlのためにmdatを読まない。保存は既存の逐次コピー・独立hash検証を再利用する。CPU/メモリはtitl範囲の文字列検証ぶん増えるが、追加のファイル全走査や複雑なキャッシュを避ける。効果は未計測である。

## 影響と保留事項

公開APIは追加中心で、既存blockedを自動で成功へ読み替えない。限定修復は新操作を明示allowしたときだけ適用できる。非対応titlと実在targetへの字幕sourceは引き続き拒否する。通常setterの保持保証や正常QuickTimeのNero統一は今回の修復設計に含めない。

実作品への適合はtitlの配置・header・payloadを読み取り専用で確認した後に判断する。コピー検証は対象と保存先の確認後に限る。合成fixtureの安全性確認は完了したが、実作品・UTF-16・他backendの確認は未完了である。

詳細: [調査と設計](../mp4-chapter-plan-safety-design.md)

## テストによる確認と実装方針の追記

状態: 実装済み。追加の回帰テストは9件・92 assertions成功。

- 実sample付きvide/soun/sbtl fixtureで、欠落chapだけの既存解除と別出力保存が全track、packet内容と時刻、Nero/chpl、metadata/artwork、非chap参照を保持した。新しいatom編集器は作らず既存エンジンを使う方針の根拠とする。
- 欠落と実在音声targetの混在でも選択解除は成功した。限定修復へ混在を自動接続する根拠にはしない。正常なchapterの適否まで自動判断しないため、当初の全欠落限定を維持する。
- titl付き正常章でpayload保持と専用track除去を検証した。位置外titl・不正終端は具体issue付きで拒否する。構造入口の限定修復はblocked計画へ統一し、I/Oと世代変更は例外を維持する。
- 重複track IDは公開入口で既にmalformedとなる。内部解析との分類統一を目的に既存公開分類を変更しない。
- **実装でもI/Oが少なくなる方針を優先する。** 正しさ・破損防止・公開API契約を満たしたうえで、取得済みmoov/観測を再利用し、titlを二重読取せず、限定修復を一回の解析と一回の保存候補生成にまとめる。無変更時は書込を避け、理由表示のための再解析・追加mdat走査・コピーを増やさない。
- statモードの参照診断は、計測したHeaderReader読取がmdat本文に重ならず、同一diagnoseの繰返しでも追加読取がなかった。この性質を維持する。sha256世代照合や保存時の独立hash検証は安全性のため継続し、必要I/Oを省かない。

キャッシュを複雑化して全操作を共有する案は採用せず、既存の世代キャッシュと単一解析内のraw再利用に限定する。CPU・メモリは検証対象titlと上限付きmoovに必要な範囲とする。ファイル全体のI/O削減率や性能値は未計測であり、実測として記載しない。
