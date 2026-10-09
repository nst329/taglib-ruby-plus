# MP4 snapshot値取得・property期待値・chapter公開APIの設計

## 位置付け

2026-10-09。2.3.2.9への試作検証から決め、追加のQuickTime異常構造検証を経て2.3.2.10のRuby層に実装した設計。native ABI・patchは変更しない。

利用例は字幕mux・音声変換・作品タグ更新の前後に、変更を許可したタグ以外と両chapter形式を保持・検証する処理。保持確認に失敗した場合は原本を置換しない。復元は未保存状態への操作であり、ディスク保存は既存File#saveで行う。

## 1. MetadataSnapshotの値取得

次の公開候補を優先する。返却値はdeep freezeされたRuby所有値で、Fileを閉じても利用できる。nativeオブジェクトは返さない。

```ruby
snapshot.mdta_values('gain')
# => [{ data_type: 33, locale: 1041, data: "\0\xff".b }, ...]
snapshot.item('©cpy')
# => { kind: :string_list, atom_data_type: 255, value: ['著作権', '著作権'] }
snapshot.artworks
# => [{ format: 13, data: jpeg_bytes }, ...]
```

| 状態 | mdta_values(key) |
| --- | --- |
| キーなし | nil |
| keys表にあるが値なし | 不変の[] |
| 空UTF-8値 | data_type=1、data=''.bの1値以上 |
| 空バイナリ値 | 元のdata_type、data=''.bの1値以上 |

mdtaの型・locale・bytes・値順・同値重複を保持する。mdtaのindexは値APIに含めず、既存mdta/source_structureで観測する。itemはkind、atom_data_type、元payloadを保持し、キーなしのみnilとする。入力キーの検証は既存snapshotのUTF-8・NUL禁止規則へ合わせる。

artworksはcovr不在なら[]。画像形式は観測した整数を保持する。既存Artworkは空bytes・未知形式・署名不一致を拒否するため、snapshot取得でArtworkへ変換しない。covrのkindがcover_art_listでなければ明示的に拒否する。atom型はitem('covr')で取得できる。

初版は複雑な新しい値クラスを増やさず、名前付きHashを採用する。検索ごとに不変の取得値を構築し、索引やキャッシュは追加しない。

### 空キーと比較の契約

既存logical_equal?/diffは値なしmdtaキーとキーなしを同一扱いにする。取得APIは両者を区別するが、既存の論理比較を変更しない。空キーの存在まで保持確認したい場合は、選択キーの存在を別途比較する必要がある。structure_equal?はindex・配置も比較するため、別ファイル復元時の代替検証にはそのまま使えない。

## 2. property更新後の期待snapshot

公開候補はsnapshot.with_properties(Hash)。初版の意味はTag#set_propertiesと同じであり、title=相当のモードと削除操作は含めない。nilは削除の略記にせず拒否する。削除が必要になった時はremove_property相当を別に設計する。

```ruby
expected = original.with_properties(title: '', copyright: '著作権', show: '番組')
file.tag.set_properties(title: '', copyright: '著作権', show: '番組')
expected.diff(file.tag.metadata_snapshot) # => []
```

変換・alias・入力検証・更新対象を1つの更新計画生成処理へ集める。その結果をset_propertiesがnativeへ適用し、with_propertiesが不変snapshotへ適用する。property_update_effectsも同じ対象解決を使う。計画はファイルの変更や実setter呼出しを行わず、入力全体を検証してから生成する。

通常文字列itemのatom_data_type=255とfreeformの明示型1を維持する。空文字はset_propertiesでは1値として保持し、対応mdtaの全値を削除する。copyrightは©cpyのみ変更する。showとTVShowNameの重複指定は拒否する。文字列encoding変換とContentRating処理も共有する。

試作では既存privateメソッドとnative Item変換を借りた。製品実装は内部PropertyUpdatePlanへ対象解決・検証・native Item変換を移し、Tag.allocateやprivate呼出しを使わない。setter結果を読み取って期待値を生成しない。

この独立性は実setterを呼ばないことを意味する。共有変換ロジック自体のバグを自動的に検出する保証ではない。手書きの期待値（空文字、Shift_JISからUTF-8、atom型、mdta除去）と保存後再読込のテストも維持する。

## 3. ChapterSnapshot

公開候補はFile#chapter_snapshot、File#restore_chapter_snapshot(snapshot, styles: [:nero, :quicktime])、ChapterSnapshot#logical_equal?/#diff。型をMetadataSnapshotから分ける。両形式を独立に取得し、共通chaptersによる優先選択・競合解消はしない。

```ruby
chapters = source.chapter_snapshot
destination.restore_chapter_snapshot(chapters) # 両形式を全置換する未保存操作
destination.save
chapters.diff(destination.chapter_snapshot)
```

初版の保持対象は各形式の開始時刻（既存APIと同じミリ秒）・UTF-8タイトル・順序。トラックID、timescale、sample配置、生atom、ミリ秒未満の時刻、QuickTime固有の補助情報の完全復元は保証しない。NeroとQuickTimeの内容が異なる入力は正常に保持する。

選択した形式だけ全置換し、空配列はその形式の削除。非選択形式は維持する。両形式を復元する場合は全候補を先に検証し、片方だけpending変更された状態で失敗しない。タイトルは必ずコピー・freezeする。現行Chapterは元のタイトル文字列を保持しており、本体freezeだけでは不変ではない。

差分は形式別のvalue_count、start_time、title、orderを診断し、空ならlogical_equal?がtrueとなる。orderは同じタイトル集合の並び替えを示す。時刻は常に昇順で、非昇順入力を拒否する。形式の統合や構造差分を混ぜない。

### 完全読取診断と対応範囲

現行Nero readerは宣言数2・実データ1件のchplを1件の一覧として成功扱いする。現行Ruby APIには完全読取か部分取得かを判定するstatusがない。既存の内部chapter_snapshotをそのまま公開しても「未対応構造を部分取得で成功扱いにしない」契約は満たせない。

QuickTimeでもsttsの宣言数3・実データ2件を成功扱いすることを再現した。この結果を受け、native拡張の代わりに既存MP4 atom解析を利用する内部ChapterReaderを実装した。各形式の読取結果にabsent/complete/unsupported/malformedとreasonを持たせ、公開captureはcomplete/absentのみ受け入れる。他はChapterSnapshotError(code, phase, style)で全体拒否する。完全解析とnative読取の値も照合する。形式不一致は正常で、読取不完全とは区別する。

Neroはversion 0/1、flags・reservedが0、宣言数とpayloadが一致するUTF-8一覧に対応する。QuickTimeは単一音声参照、単一text chapterトラック、mdhd version 0、stco/stsz/stsc/stts、自己参照dref、media_time=0/rate=1の単一edit list（またはedit listなし）に対応する。co64/stz2/ctts、複数参照、外部data reference、未知text modifier、非整数ミリ秒は未対応として拒否する。先頭空タイトル・時刻0のQuickTimeサンプルはnativeと同じpadding規約で扱う。

atom探索は深度16・50,000atom、chapter payload/総sample bytesは32MiB、QuickTime sample/tableは100,000件を上限にする。構造の不正・件数不整合・mdat外sample・UTF-8不正はmalformed。physicalな空構造と不在は診断で区別できるが、ChapterSnapshotの論理値では空配列に統一する。

Nero writerはchapter数255件・タイトル255bytesを上限として切り詰めるため、ChapterSnapshot構築時に上限超過を拒否する。Nero時刻はsigned 64bitの100ns換算上限、QuickTime時刻はwriterの32bitミリ秒上限、QuickTimeタイトルは65,535bytesを上限とする。UTF-8のbyte単位切断を許容しない。既存set_chaptersによる上限超過も保存準備時に拒否する。

時刻のファイル長チェックはreadAudioProperties=falseでは行われない。公開契約は音声情報の有無を明示し、現行の条件付きチェック以上を保証しない。常時チェックが必要なら、独立したduration取得の設計・追加テストを先に行う。

## 実装順と受入条件

1. 値取得APIを追加し、既存snapshotの型・比較契約を維持する。
2. chapter構造診断を追加して異常構造を全体拒否できるようにし、ChapterSnapshotを公開する。
3. property変換を共通計画へ整理し、with_propertiesを追加する。

タグ・chapter同時保存は既存File#saveを使う。新しい保存APIは追加しない。既存の保存準備と一時出力の再読込検証で公開ChapterSnapshotを使い、完全読取できない原本または出力を原本置換前に拒否する。save/save_chaptersの拒否はMdtaSaveError(committed: false)で伝える。呼出側独自の期待タグsnapshotの保存前照合を自動追加するものではなく、外部保存後だけの比較を原本保護とみなさない。

試作で検証済みの範囲と再現手順は[Memos](Memos/2026-10-09-snapshot値取得とchapter公開APIの試作検証.md)、決定理由は[ADR](ADR/2026-10-09-snapshot値取得とchapter公開APIの設計.md)を参照。
