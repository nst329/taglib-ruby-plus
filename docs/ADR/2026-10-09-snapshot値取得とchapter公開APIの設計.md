# snapshot値取得・chapter公開・property期待値生成の契約を試作から決定する

日付: 2026-10-09。状態: 実装済み、公開は未実施。

## 背景

MListNewの配列検索・型付き値の分解・Nero/QuickTime退避を減らしたい。変更を許可したタグ以外を保持し、確認不能なら原本を置換しないことが必要。

## 決定と理由

- 値取得は名前付き不変Hashを返す。既存snapshotのpayloadを再利用でき、複雑な値クラスを追加せず配列配置への依存を減らせるため。
- mdta_valuesのnil/[]/空payloadを区別する。空payloadと値なしキーは有効で、呼出側の真偽判定による取りこぼしを防ぐため。
- 既存logical_equal?/diffの空キー無視を維持する。公開済みの比較基準を取得APIの追加で変更しないため。キー存在の保持確認は別の契約とする。
- artworksは観測したformat整数とbytesを返し、Artwork変換を使わない。既存Artworkの署名・空値制約で取得情報を落とさないため。
- property期待値はset_properties相当に限定し、共通更新計画を使う。native title=とは空文字・mdtaへの影響が違い、モードを混ぜると意味が曖昧になるため。nil削除は導入しない。
- 試作のprivate呼出しとTag.allocateは製品化時に廃止する。検証・変換の共有可能性を確認するための道具であり、製品の依存境界にするべきではないため。
- ChapterSnapshotは両形式を独立にdeep copyし、選択形式を全置換する。既存Chapterのタイトルは可変で、共通chaptersは形式不一致を拒否するため。
- chapter公開前にnativeの完全読取診断を追加する。宣言数と実データが異なるNero構造でも現行readerが部分一覧を成功扱いすることを再現したため。単なる内部メソッドの公開は見送る。
- chapter復元は両形式を全検証してからpending状態へ反映する。2形式目で失敗して1形式目だけ変わる状態を避けるため。
- chapterの保証は既存ミリ秒時刻とタイトルの論理値に限定し、構造完全復元とは分ける。現行一覧APIが提供しない情報を復元可能と主張しないため。
- 時刻上限は音声情報読込に依存する現状を明示する。readAudioProperties=falseでduration上限チェックが省略されることを再現したため。
- 保存はFile#saveを維持する。タグ・chapterの同時保存とrename前検証が既にあり、故障注入で原本とpending値の保持を確認できたため。
- 製品コードを変更せず試作テスト・設計資料を追加する。今回はテストしながら設計する依頼であり、公開API追加・リリースを先行しないため。

## 影響

2.3.2.9の挙動は変えない。値取得を先に実装できる。chapterはnative診断が必要で、QuickTime異常構造・上限・精度の検証を追加してから公開する。今回の試作は不完全readerの現状を成功テストで記録しているため、製品修正時には期待値を「明示拒否」へ変更する。

[詳細設計](../mp4-snapshot-access-chapter-design.md) / [試作検証](../Memos/2026-10-09-snapshot値取得とchapter公開APIの試作検証.md)

## 追加検証後の実装判断

QuickTime sttsの宣言数3・実データ2件でも既存readerが2件を返すことを再現した（試作13 tests / 97 assertions成功）。完全読取診断の必要性は維持するが、実装場所をnative必須からRubyの厳密な構造preflightへ変更する。既存MP4 atom解析を再利用し、NeroのpayloadとQuickTimeの参照・サンプル表・UTF-8を全件検証してからnative読取結果と一致確認する。nativeのABI・patchを増やさず、両backendで同じ拒否契約を提供できるため。nativeが扱えない構造はpreflightで拒否し、推測補完は行わない。

- 既存Chapterのタイトルもcopy/freezeした。不変という既存コメントと実挙動を一致させ、pending変更にも呼出側の文字列変更を波及させないため。
- 完全診断をsave/save_chaptersにも適用した。新APIで退避できても保存時に部分取得で成功扱いすれば原本保護の契約を満たさないため。従来保存できた非対応chapter構造も明示的に拒否する互換性変更となる。
- parserに深度・atom数の上限を追加した。異常構造の診断で無制限再帰・走査を起こさないため。
- Nero/QuickTimeのwriter上限をsnapshot構築時に検証した。切り詰め・整数overflowで変更結果が期待値と異なる前に拒否するため。
- 公開済み2.3.2.9と区別して2.3.2.10へ更新した。パッケージ内容の変更を既公開バージョンと混同しないため。CIのgem smokeテストの古い固定バージョンも実際のversion読取へ変更した。
- 試作は公開APIの受入テストへ置換し、private呼出しと試作moduleを削除した。実装と異なる二重APIを維持せず、製品契約を直接検証するため。
- 一時出力のchapter読取拒否をMdtaSaveErrorのphase=:verifyへ変換する。失敗した場所を保存準備・原本置換と区別し、呼出側へ正しい原因段階を伝えるため。

実装後の結果と限界は[実装検証](../Memos/2026-10-09-snapshot値取得とchapter公開APIの実装検証.md)を参照。
