# MP4通常プロパティの正規化設計

状態: 基本経路を実装（2026-09-20）。TagLibパッチ、C++ binding、Ruby API、fixtureテストへ反映済み。
以下の必須検証表は完了報告ではない。未知子atom・曖昧な構造・native失敗注入・参照寿命などの
全契約の検証と、SWIG再生成・既存テスト全体の実行は未完了。
基準: v2.3.2.3。

## 目的と責任境界

`set_properties`で明示的に編集した通常プロパティはilstを正本にする。
同じ意味のmdtaキーを削除し、古い値との併存を解消する。
対応付けと更新方針はRubyの高水準APIに置き、atomの解析・削除・再構成は
TagLib本体に置く。通常のC++ `Tag::save()`には自動正規化を追加しない。

これは従来の「通常プロパティを編集しても同名mdtaを保持する」契約の変更である。
未編集のmdtaを保持する契約と、低水準APIで明示的に併存させる機能は維持する。

## 対応表

| 公開プロパティ | ilst | 削除するmdtaキー |
| --- | --- | --- |
| title | ©nam | title |
| artist | ©ART | artist |
| description | desc | description |
| TVShowName | tvsh | show |

完全一致のみを対象にする。大文字小文字や未知の別名を推測しない。
公開名`show`は既存のproperty_atomでTVShowNameへ解決される別名として維持する。
読み書きとも正規名TVShowNameへ解決してから対応表を参照する。
propertiesの列挙名は引き続きTVShowNameとし、showを重複して列挙しない。
その他の通常プロパティは従来どおりilstだけを更新する。

## 公開契約

- `set_properties(hash)`は指定キーだけを更新する部分更新API。空Hashは無操作。
- `set_property(name, value)`も同じ経路を使用し、同じ正規化を行う。
- 対応するmdtaの全値を削除して、ilstの値を置換する。値が既存値と同じでも正規化する。
- `remove_property(name)`はilstと対応mdtaの両方を削除する。存在しない場合は無操作。
- `remove_property(name)`は変更を適用したTagを返し、`set_property`と同じく連鎖呼び出しできる。
- `nil`は引き続き不正値。削除にはremove_propertyを使う。
- 空文字は削除の別名にしない。既存の文字列入力契約に従う。
- 読み取りはilst itemの存在を優先し、存在しない場合だけmdtaへフォールバックする。
  空値を理由にmdtaへフォールバックしない。
- mdtaの読み取りは既存のtext判定を維持し、非文字列型を文字列化しない。
- `set_mdta_item`、`remove_mdta_item`、ItemMap直接操作、nativeの`title=`は
  低水準操作として自動正規化しない。高水準APIに限定した動作変更とする。
- setterはメモリ上の変更。ディスクへの反映はFile#saveで行う。

たとえばset_propertiesでtitleを更新した後にset_mdta_itemでtitleを設定すれば、
再び併存する。呼び出し順を尊重し、saveが後から勝手に削除しない。

## 型・未知データの扱い

明示的に編集した対応キーは、そのキー全体の置換要求と扱う。
対応mdtaの非UTF-8型、locale別値、複数dataも削除対象になる。文字列へ変換はしない。
この破壊的な意味をAPI文書に明記する。

audio_normalization、audio_normalization_target、未知キー、未指定の既知キーは保持する。
保持するのは名前・型・locale・値と未知構造であり、keys削除に伴うインデックスの
再採番は許容する。インデックスと値の対応が変わらないことを必須とする。

解析不能なatom、重複keys、複数mdta metaなどで対象を安全に特定・削除できない場合、
一部だけ正規化して成功にしない。高水準操作を変更適用前にMdtaItemErrorで拒否する。
現在の本体パッチは単一mdtaを前提にするため、この検出能力は実装時の確認事項である。

対象の同一性は`meta`のhandlerが`mdta`であることと、`keys`エントリの名前で判断する。
MP4の`keys`エントリにはnamespaceを表すフィールドがあるが、現行のTagLib APIでは
それをRubyのキーごとのnamespaceとして公開しない。別のmeta文書にある同名キーを
削除しないため、対象は最初に選択したmdta meta文書へ限定する。
複数のmdta meta文書が存在して選択を証明できない場合は操作全体を拒否する。
拒否判定は対応mdtaを正規化する操作に限定する。空Hashや対応表にない項目の更新に
正規化用の追加制限を課さない。

### 本体の削除実装に対する必須変更

現行MdtaState::removeはkeys削除後に全残存キーをchangedKeysへ登録する。
renderItemsは変更キーを解析済みitemsから再生成するため、未編集キーの未知子atomが
失われる可能性がある。既存remove_mdta_itemを呼ぶだけでは保持契約を満たすと判断しない。

本体で、未編集の数値itemはraw bytesを再利用し、再採番が必要な場合は外側の
数値item IDだけを更新する。payloadと未知子atomを再生成しない。
複数dataや同じindexの複数itemも順序を維持する。安全に外側IDを解釈できない場合は拒否する。
削除対象のkey-only entryも削除し、残存key-only entryは保持する。
正規化対象のhandler判定と重複keys・meta検出も本体側の事前検証対象とする。

## 適用手順と失敗契約

1. Hash全体の名前・値・文字コードを検証する。
2. 正規名へ解決し、同一プロパティの重複指定（文字列キーとSymbolキーなど）は拒否する。
3. native Item生成とmdta削除可否の確認を済ませる。
4. 本体側で編集用の一時状態に全変更を適用し、成功後に既存Tagの状態へ一括反映する。
5. File#saveの既存の一時ファイル保存・再読込検証・置換へ渡す。

入力不正・未対応構造の検出時はメモリ上のilst/mdtaも変更しない。
回復可能なnative例外・拒否でも元のメモリ状態を維持する。
そのため既存の逐次insert/erase呼び出しだけでは実装しない。
TagLib側に「ilst変更集合と明示的mdta削除集合を一括適用する」最小限の公開補助APIを置く。
対応表はRubyが解決し、本体側は通常プロパティ名を知らなくてよい。

具体的なシグネチャは次のとおりに決定する。

```cpp
bool Tag::applyChanges(const ItemMap &setItems,
                       const StringList &removeItems,
                       const StringList &removeMdtaKeys);
```

`setItems`は置換するilst項目、`removeItems`は削除するilstキー、
`removeMdtaKeys`は削除するmdtaキーを表す。各リストの重複、setとremoveの同一キーは
Ruby bindingの入口で拒否する。本体APIは通常プロパティ名を解釈しない。

戻り値`true`は要求をすべて適用できたことを示す。対象mdtaキーが存在しない場合や
mdta文書自体がない場合の削除は成功扱いの無操作とする。`false`は複数mdta文書、
handler不一致、raw itemを安全に再採番できない構造など、状態を変更できない場合だけ
に限定する。

補助APIは、既存Tagを変更せずに検証・構築した一時状態を受け取り、成功した場合だけ
ilstとmdtaの状態を同じTagへ反映する。Tagオブジェクト自体は差し替えない。
`d->items`のMapオブジェクト自体も差し替えず、候補状態を同じメンバーへcommitする。
そのため既に取得したItemMap wrapperは引き続き同じTagを参照できる。
一方、commit前に取得したItemMapのiterator、Itemへの参照、Itemのポインタは無効化する。
Ruby APIはそれらを保持する契約を公開しない。C++直接テストではwrapperの再利用と、
古いiteratorを使わずに再検索できることを確認する。

保存期待値は正規化後のmetadata_snapshotを用い、削除前のmdtaとの一致を要求しない。
検証基準を緩めず、残存キー・型・値・artwork・chapter・mdatを確認する。
ディスク保存失敗時は既存の原本保護契約を維持する。
正規化でmetadataが変更された状態のsave_chaptersは、既存契約どおり拒否する。

## 実装対象

- lib/taglib/mp4.rb: 対応表を読み書きで共用し、set_properties/remove_propertyへ適用。
- docs/taglib/mp4.rb、README.md、CHANGELOG.md: 更新・削除・型付き値削除の公開契約。
- test/mp4_metadata_api_test.rb等の既存APIテストとmdta fixtureテスト。
- test/mp4_mdta_taglib_core_test.cpp: 削除・再採番・残存データ保持の直接検証。
- TagLibパッチとbinding: raw保持した再採番、削除可否検出、一括適用を追加する。
  C++ APIは上記の`applyChanges`、Ruby bindingは`_apply_changes`として公開する。
  `_apply_changes`はRubyのItemMap・文字列配列を受け取り、falseをMdtaItemErrorへ変換する。
- extconfの能力検査とCI: 新しい本体APIへのリンクを検証し、旧パッチ利用時に構築を拒否する。

実装結果:

- TagLibパッチに`Tag::applyChanges`を追加し、通常ilst更新とmdta削除を一時状態へ適用してからcommitする。
- mdtaの未編集raw itemは再利用し、keysの再採番時も外側のkey indexだけを書き換える。
- Rubyの`set_properties`／`set_property`は対応プロパティをilstへ正規化し、対応mdtaを削除する。
- `remove_property`はilstと対応mdtaを同時に削除する。
- `set_mdta_item`／`remove_mdta_item`は低水準APIとして従来どおり明示操作を保持する。
- `_apply_changes`はbinding内部APIとし、Ruby公開APIにはItemMapと混同するmdta用ItemMapを追加しない。

Rubyでatomを再構成する処理や、別の永続的変更キューは追加しない。
通常プロパティの対応方針そのものを上流TagLibへ持ち込む必要はない。
本体の安全なキー削除、未知構造の保持、未対応構造の検出は上流提案対象になる。

## 必須検証と完了条件

FFmpeg生成fixtureと通常MP4のコピーを使用し、保存後にTagLibとffprobeの両方で確認する。

| ケース | 必須結果 |
| --- | --- |
| mdta-onlyのtitleを更新 | ilstに新値、mdta titleなし、再読込で新値 |
| ilstとmdtaの異なる旧値を更新 | 新値のみ。ffprobeで旧値との連結なし |
| 4対応プロパティを個別・一括更新 | 対応キーだけ削除、未指定値は保持 |
| artistだけ更新 | title/show/description/音量正規化情報を保持 |
| remove_property | 両領域から消え、旧値のfallbackなし |
| 同値、空文字、空Hash、再保存 | 契約どおりで、再保存による追加変化なし |
| Hash後半の不正値・重複指定 | 先行項目も含めてメモリ状態不変 |
| show/TVShowNameの別名衝突 | 単独では同一動作、同一Hashで両方指定したら変更前に拒否 |
| 型付き値・複数値・locale違い | 指定キー全体のみ削除、他キーの型・生値を保持 |
| 削除によるkeys再採番 | C++直接テストで残存キーと値の対応を確認 |
| 未編集itemの未知子atom・key-only entry | 独立atom解析でpayloadのバイト一致とindexの対応を確認 |
| 別meta文書の同名キー | 削除されない、または安全性を判定できず操作全体を拒否 |
| native一括適用途中の失敗注入 | ilst/mdtaとも操作前と一致、その後の正常操作も成功 |
| 未対応・曖昧な構造 | 原本を変更せず拒否。一部処理で成功しない |
| 低水準APIとの呼び出し順 | 明示的なmdta再追加を保持 |
| artwork/freeform/両chapter形式 | 通常プロパティ更新後も保持 |
| save失敗・save_chapters | 原本保護、未保存metadataの拒否を維持 |

Ruby構文、C++コンパイル、既存MP4テスト、fixtureテストを実行する。
通常mp4のnative setterを使うmdta保持テストは残し、高水準setterの期待だけを変更する。
ffprobeの表示については未検証の一般保証にせず、対象fixtureで結果を記録する。

## 設計レビュー結果

新規オプションや汎用トランザクションクラスは不要。既存高水準APIへの限定が最小構成。
単なるset_propertiesへのremove_mdta_item追加だけでは、削除後のfallback復活、
一括入力の途中失敗、未対応metaの取り残しを防げないため、上記契約を同時に実装する。
レビューでshow別名の誤認を訂正し、raw保持・一括適用を任意の改善から必須条件へ変更した。
metadata_snapshotは未知子atomを含まないため、その比較だけでraw保持の検証完了としない。
一括適用APIのシグネチャ、commit単位、参照の有効範囲を確定した。
`Tag`とItemMap wrapperは維持し、ItemMapのiteratorと個別Item参照はcommitで無効化する。
基本の更新・削除経路はC++直接テストとRuby fixtureテストで確認した。
参照の有効範囲を含む全契約を固定できたとは扱わない。公開済みv2.3.2.1のタグは変更せず、
本変更は次版で公開する。

## Ruby正規化経路の整理

読み取りfallbackと更新・削除の対応付けは`MDTA_PROPERTY_KEYS`一つを参照する。
入力は正規名をキーとするHashへ検証済み値を集約し、このHashで別名衝突も検出する。
別の重複検出Hashや同じ対応表を追加しない。
検証完了後にnative ItemMapを構築し、更新と削除は共通の非公開
`apply_property_changes`から一括適用する。空Hashは引き続き無操作とする。

整理後の検証: Ruby構文、mdta fixture 17 tests / 127 assertions成功。
