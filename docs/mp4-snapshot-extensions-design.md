# MP4 snapshot追加API

2026-10-09。状態: 2.3.2.9に実装、legacy/grouped両backendで検証済み。

## 前提と保持範囲

対象はMetadataSnapshotが完全に表現できる通常itemとmdta。未知atomや全ファイルのbyte一致は保証しない。
MListNewの要件は「変更を許可したタグ以外は保持し、保持確認できない場合は原本を置換しない」。
復元は管理対象の全体置換。部分編集はその前に期待snapshotを作る操作であり、暗黙mergeや比較対象の除外とは別。

## 部分編集

```ruby
expected = original.without(items: ['©cpy'], mdta: ['gain'])
expected = expected.with(
  items: [['©cpy', :string_list, original_atom_type, ['新しい著作権']]],
  mdta: { 'gain' => [[1, 0, 'new'.b], [1, 1041, 'new'.b]] }
)
```

withoutは領域ごとに指定キーを除いた新snapshotを返す。存在しないキーの除外は何もしない。
withはキーごとに値全体を置換・追加する。appendや型推測はしない。
itemsは取得時と同じ `[key, kind, atom_data_type, payload]` の行配列、mdtaはキーを指定するHashで値は順序付き `[data_type, locale, binary]` 配列。

元snapshotは不変。新snapshotもdeep freezeする。通常atom型、画像format、mdta型・locale・binary、値順・重複・空値を保持する。
通常itemのキー順は従来どおりsortする。mdtaの既存source_indexは維持し、新キーは元最大indexの次から採番する。index上限超過は拒否。
source_structureは取得元の観測情報であり、編集後の復元先構造の予測ではない。

除外した通常itemは復元先から削除される。mdtaの除外は値を削除し、復元先のkeys表には値なしキーが残り得る。
入力形状・型・encodingはMetadataSnapshot.newと共通検証し、MetadataSnapshotError（invalid_snapshot / validate）で拒否する。
キーと型の組・writerの保存幅はrestore時に全候補を検証し、メモリcommit前に拒否する。編集完了だけで保存可能とは保証しない。
たとえばtmpoの65536はRuby整数範囲内でも復元時に拒否される。writer制約の対応表をRubyへ重複して持たせない。

## 論理差分

`expected.diff(actual)`は不変の差分配列を返す。actualはMetadataSnapshotを要求し、別型はMetadataSnapshotErrorで拒否する。
`expected.diff(actual).empty? == expected.logical_equal?(actual)` を必須契約とし、両APIでlogical_valuesを共有する。

```ruby
# localeだけ変更された場合の差分要素
{
  area: :mdta, key: 'gain', change: :changed, changes: [:locale],
  before: [{ data_type: 1, locale: 0, data: { bytesize: 3, sha256: '...' } }],
  after: [{ data_type: 1, locale: 1041, data: { bytesize: 3, sha256: '...' } }]
}
```

areaはitems/mdta。changeはadded/removed/changed。追加・削除のchangesはpresence。
既存キーのchangesはkind、atom_data_type、image_format、data_type、locale、value_count、value、orderの該当項目。
同じ型付き値集合を重複数込みで持ち、配列順だけ異なる場合はorderとする。
それ以外は値数と、重なる位置の各フィールドを比較する。挿入位置がずれる場合に複数フィールドを報告することがあるが、推測による列の対応付けは行わない。
複雑な編集距離やLCSは導入しない。before/afterで実際の列を確認できる。

通常itemのbefore/afterはkind、atom_data_type、payload。mdtaはdata_type、locale、dataの値列。
判定は生値で行う。全binary・画像・mdta payloadは表示上bytesizeとSHA-256に縮約し、画像formatを別に残す。
通常文字列は256 bytes以下なら文字列を返し、それを超える場合はサイズとhashを返す。

通常itemとmdtaは別領域。高水準propertyへの読み替えはしない。
index・異なるキー間の順序・source_structure・値なしmdtaキーは論理差分へ含めない。構造差分は追加せず、既存structure_equal?を使う。

## property更新影響

```ruby
tag.property_update_effects(:title)
# => { items: { set: ['©nam'], remove: [] }, mdta: { remove: ['title'] } }
tag.property_update_effects(:title, operation: :remove)
# => { items: { set: [], remove: ['©nam'] }, mdta: { remove: ['title'] } }
tag.property_update_effects(:title, via: :native_setter)
# => { items: { set: ['©nam'], remove: ['©nam'] }, mdta: { remove: [] } }
```

結果は現在値によらない「変更し得る対象」であり、実差分ではない。deep frozen Hashを返す。
viaの既定値はset_property、operationはset/remove。set_propertiesの各キーも同じ規則。
show別名はTVShowNameへcanonical化する。未知property・未知操作・未対応setterはArgumentErrorで拒否。
native_setterはtitleのみ対応し、operationはsetのみ。値に依存して通常itemを設定または削除するので、双方の可能性を返す。

setterと影響APIはproperty_targetsを共有し、PROPERTY_ATOMS/MDTA_PROPERTY_KEYSから同じ対象を解決する。
公開title=も同じatom定義を使い、既存Item.from_string_listのnative変換とItemMap更新を再利用する。
空文字・nilは©namを削除し、mdta titleは残す。NULを含む文字列、別encoding、to_strを含め、base Tagのvirtual native setterと一致を検証した。
新しいbinding APIは追加しない。他のnative setterを未検証の対応表から説明しない。

## copyright

Rubyのproperty/property_values/set_property/set_properties/remove_property/propertiesにcopyrightを追加し、©cpyだけを対象とする。
propertyは先頭値、property_valuesは順序と重複を保った全値、更新は文字列1値への置換。複数値の復元にはsnapshotを使う。
cprtとmdta copyrightは独立して保持する。fallback・自動移行・併存時の削除は行わない。
影響APIも通常item ©cpyだけを返す。専用copyright/copyright=は追加しない。

nativeのItemFactory::nameHandlerMapへ©cpyをTextとして登録する。mdir/mdta両構造で読み書き・snapshot復元を検証した。
既存の汎用native PropertyMapのCOPYRIGHT=cprtは変更しない。Rubyのproperty APIとは別契約。

## 実装後検証による設計の見直し

全propertyの影響とsnapshotを組み合わせた検証で、既存のldes/keyw/purdがmdta構造の既知atom判定で拒否されることを確認した。
©cpyと同じText登録を追加し、既存longdesc/keyword/purchaseDateもsnapshotと組み合わせられるようにした。
contentRatingはfreeformのatom型255をwriterがUTF-8型1へ推測し、保存前のsnapshot診断が拒否していた。
property setterでfreeform文字列型1を明示する。snapshot値の暗黙変換は追加しない。

native patchはpatches/taglib/0003-mp4-property-atoms.patch。legacyの0001/0002、groupedのproposals/0001/0002/0003に続けて共通適用する。
新しいpatchが独立したファイルを変更するため、ビルド時の最後のpatchだけのreverse確認では既存snapshot列の適用済み判定ができない。
ビルド処理はsnapshotの重複hunkを識別して、追加patchだけを適用する。新規適用・既存snapshotからの更新・再実行をテストした。

## 保存とMListNew連携

1. 原本から完全snapshotを取得する。取得・保持確認不能なら停止する。
2. 許可した変更だけを反映した期待snapshotを構成する。
3. 変換出力を原本とは別の候補ファイルとして扱い、期待snapshotを復元・保存する。
4. 独立再読込のsnapshotと期待snapshotの論理一致、字幕・media等の保持を確認する。
5. 差分・取得不能・保持確認不能なら原本を置換しない。成功後にだけ原本を置換する。

File#saveの既存一時コピー・再読込検証・rename・reopenの契約は維持する。期待snapshotを受け取るsave引数は追加しない。
既存saveは編集後の状態と保存結果を照合するため、許可範囲を単独では判定しない。変換と原本置換の判断はMListNewの責務。
テスト専用のverify_saved_copy拡張で、許可外comment変更をrename前に拒否し、committed=false・原本hash不変・再試行成功を確認した。
rename後のreopen失敗は従来どおりcommitted=trueで報告する。

## 検証結果と限界

関連範囲: legacy 81 tests / 838 assertions、grouped 81 tests / 843 assertions、全成功・省略なし。
全体Test::Unit: 各302 tests、legacy 1418 assertions/grouped 1423 assertions。両方とも既知のwrapper数1 failure、0 errors、手動試作10 omissions。
変更前HEADでも同じwrapper数の失敗を再現した。今回追加APIに失敗なし。
別プロセスMinitest: 両backend各12 runs / 54 assertions、成功・省略なし。
新規native patch列から生成したsourceと検証native sourceの一致も確認した。

検証はmacOS arm64/Ruby 4.0.7の隔離ビルドと合成ファイル。実動画原本・MListNew・インストール済みgemは変更していない。
他OS・配布gem artifactは未検証。2.3.2.9を利用するnativeには新patchを含めたビルドが必要。

## 内部責務整理

snapshotの再構築はedited_snapshot、mdta全値置換はreplace_mdta_valuesへ集約した。
mdtaの検索は挿入順序を保つHashで行い、既存indexとキー位置を維持する。
diffの領域比較・payload分類・診断表示を分け、propertyの更新対象は検証時に一度だけ解決してnative commitへ渡す。
公開API・論理比較・型・値順・重複の契約は維持。両backendの同じ関連81 testsが成功した。
[判断ADR](ADR/2026-10-09-snapshot追加APIの内部責務整理.md)を参照。
