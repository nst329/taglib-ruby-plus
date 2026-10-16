# MP4公開APIのI/O設計

対象: v2.3.2.23を基点とするRuby実装。入口は `require "taglib_plus"` と `TagLib::Plus::MP4.open`。
判断理由は[ADR](ADR/2026-10-16-MP4公開APIのI-O削減.md)、実測は[I/O検証記録](Memos/2026-10-16-MP4公開APIのI-O性能検証.md)を参照。

## 世代確認のAPIと保証

```ruby
require 'taglib_plus'

# 通常モード。媒体全体を読まず、OSの世代属性を確認する。
TagLib::Plus::MP4.open(path) do |file|
  title = file.metadata.properties[:title]
  chapters = file.chapters
end

# 厳密モード。openと世代確認ごとに内容SHA-256を照合する。
TagLib::Plus::MP4.open(path, verification: :sha256) do |file|
  file.diagnose(:metadata)
end
```

`verification:` は `:stat`（既定）と `:sha256` だけを受け付ける。利用側にInternalアクセスやpatchを要求しない。

| 保証 | 通常 `:stat` | 厳密 `:sha256` |
| --- | --- | --- |
| 開いたhandleとcanonical pathのdev/ino照合 | あり | あり |
| size、mtime、ctimeの照合 | 秒以下も含めて照合 | 同左 |
| 同サイズの書換え、mtime復元 | ctimeの変更で検出 | statに加えて内容SHAも照合 |
| stat属性が同一に見える内容変更 | 検出を保証しない | SHAの異なる内容を走査時に検出 |
| 操作中の変更 | native読取・解析・候補生成の前後と公開直前に確認 | 同じ確認点でSHA照合も行う |
| 外部writerとの排他 | なし | なし |

ctimeの分解能や属性更新の可視性はファイルシステムに依存する。通常モードは内容同一性の暗号学的証明ではない。開いたhandleはcloseまで所有する。初回のpathはrealpathへ正規化し、そのcanonical pathの置換を確認する。入力symlink自体の付替えを追跡するAPIではない。

厳密モードでも走査は瞬間的なsnapshotではない。走査中の改変と復元、stat属性の偽装、最終照合からrenameまでの競合を完全には排除しない。完全排他が必要な利用側は外部writerと別途調停する。これらは従来の毎回SHA方式にも存在する限界である。

変更検出後は `Error(code: :source_changed, committed: false)` として拒否し、cache済み値も返さない。暗黙reloadや候補mergeはしない。再openが必要。

[header情報と保存snapshotの再利用](mp4-header-info-design.md)で、この設計を追加改善した。完全置換時の旧値変換の省略と、save!のsnapshots返却契約はそちらを優先する。

## File単位のcache

metadataとchaptersは遅延読取した不変snapshot、diagnoseは領域別の不変HashをFile内で再利用する。別File間の共有や永続cacheは行わない。媒体bytesは保持しない。既存のmetadata/moov読取上限は維持する。

cacheを返すときも世代確認を行う。編集後のgetterは候補を返す。diagnoseは保存済み原本だけを表すため、未保存編集では無効化せず、原本保存成功時に全診断cacheを破棄する。原本保存では独立検証済みsnapshotと候補handleを新baselineへ引き継ぐ。別path保存では原本・cache・候補を維持する。

参照解析は構造・offset・hint検査を維持し、通常のPlus操作では全体SHAとmdat内容署名を作らない。修復計画の構造署名ではmdat長を使い、内容は保存時の独立照合が担当する。低水準の旧APIの既存検証方式は変更しない。

## 保存フローと走査予算

1. 原本世代と出力pathを確認する。
2. metadata生成はftyp＋moov/udta/metaだけの小さい一時MP4でnativeの型変換を使う。media・trackを複製しない。併存context読取も同じ小さい作業領域で分離する。
3. 通常metadata編集は検証済みmoov置換計画で候補全体を一度出力する。原本読取中に全体SHAと各mdatの長さ・SHAを同時計算する。修復と無変更コピーも同じstreamを使う。
4. metadataとNeroの同時編集は、小さい作業領域でnative生成したchpl atomも最初のmoov置換へまとめる。QuickTime編集は同じ候補にnativeのchapter専用writerを適用する。内部の原子的保存やmetadata writerを重ねない。metadata完全置換と両chapter形式の独立編集を同時に行える。
5. 保存後の候補を独立に一回逐次読取し、出力全体SHAとmdat署名を共有計算する。さらに別native handleでmetadata/chapter値と修復構造、purl raw署名を照合する。コピー中のhashだけで出力保持を証明しない。
6. 原本と候補の世代を再確認し、renameまたは排他的linkで公開する。検証済み候補handleを引き継ぎ、別inodeの値をbaselineに混ぜない。

通常metadata保存の媒体サイズ依存I/Oは、原本一回読取＋候補一回書込＋出力一回読取。全体hashは二回だが、いずれも必要なコピー・独立検証の走査と共有する。小さいmetadata作業領域や構造解析のI/Oは別途発生する。

QuickTime chapter変更はmdatを追加・変更できるため、単純な全mdat一致を要求しない。対象外の音声・映像・字幕等のtrack sample署名を原本と出力で追加照合し、両形式のchapter値も照合する。このsample読取はコピーの走査と共有していない。単純な範囲コピーだけではsample単位の順序・境界を含む署名を作れないため、既存の検証を維持する判断である。chapter編集時も候補全体コピーは一回。metadata＋Neroだけの同時編集はmdat全体一致を独立に確認し、追加のtrack sample走査は不要。

不正offset、未対応構造、purl raw不足等は従来どおり明示的に拒否する。通常item、mdtaの型・locale・bytes・順序・重複、複数artwork、正当なmdir＋mdta併存の診断契約を維持する。

## save!の返却契約の変更

戻り値の既存キー `output_path / changed / source_digest / output_digest / verification` を維持する。後続の再利用改善で `snapshots` を追加した。

| 操作 | digest | verification |
| --- | --- | --- |
| 通常モードの初回、無変更の同一path保存 | 両方nil（未計算） | `:stat` |
| 厳密モードの無変更の同一path保存 | 実測SHA | `:sha256` |
| 実際に候補を出力する保存・別pathコピー | 原本と保存後出力の実測SHA | `:independent_reopen` |

原本保存後は実測済み出力SHAを保持するので、続く通常モードの無変更保存はその値を返せる。ただし世代確認は引き続きstat方式である。nilを受け付けない既存利用側は変更が必要。無変更保存を独立再読込済みと表示せず、偽のdigestやstat由来の疑似digestを返さない。

無変更の同一path保存はコピー・全体hash・置換を行わない。厳密モードでは選択した世代検査の全体SHAだけが発生する。別pathコピーは一回のコピーと一回の独立全bytes照合を行う。

## 失敗時

code / phase / committed / issues / cause / output_path / temporary_pathを維持する。公開前は原本を変更せず候補を保持する。入力世代変更がなければ再試行できる。公開後の失敗とcleanup失敗は既存契約どおり報告する。公開済みの失敗後はセッションを使用不可とする。
