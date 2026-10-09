# MP4公開metadata snapshot設計

状態: 2.3.2.8向け実装済み・未配布。隔離したlegacy/grouped nativeとRuby bindingで検証。

## 前提と対象

問題確認時のMListNew導入版は2.3.2.6。字幕muxと音声変換で共通の復元処理を使い、set_mdta_itemの反復で同一キーの複数値が最後の一値に縮退する。MListNewは2.3.2.7のreplace_mdta_itemsへ移行し、利用者が保持成功を確認済み。

本設計はgemのタグ退避・復元と、MListNew側の字幕保持を連携させる。TagLib C++本体への適用は行わず、必要なnative変更は提案パッチと隔離ビルドで検証する。チャプター復元は初版の対象外。FFmpeg操作、Finder属性、作品DB、バックアップ、自動修復の判断はMListNewの責務とする。

MListNewのタグsnapshot・上位snapshot・構造診断と該当複数値テストを実ファイルで確認した。提供された `/tmp/mp4_zero_index_repair_test.rb` も確認済み。MListNewのソース変更は行っていない。

## 公開API

```ruby
snapshot = source.tag.metadata_snapshot
# sourceをcloseしてもsnapshotは利用できる。
report = destination.tag.metadata_diagnostics
raise 'destination cannot restore metadata' unless report.restorable?
destination.tag.restore_metadata_snapshot(snapshot)
destination.save

actual = destination.tag.metadata_snapshot
raise 'metadata mismatch' unless snapshot.logical_equal?(actual)
```

restore_metadata_snapshotはメモリ上の編集だけを行い、成功時にTag自身を返す。保存やcloseは行わない。呼出側は既存File#saveで確定する。取得・復元に黙って省略するモードや自動修復を設けない。

### MetadataSnapshot

Ruby所有で再帰的に不変な値。native wrapper、File、Tag、Atomポインタを保持しない。バージョン1の形式識別子を持つが、初版ではJSON/Marshalなどの永続化形式を公開契約にしない。

| フィールド | 内容 |
|---|---|
| format_version | 1。未対応版は復元前に拒否 |
| items | 通常ItemMapのキーとItemValue。画像はcovrの一部として一度だけ格納 |
| mdta | キー単位のMdtaEntry列。元のkey_indexと順序付きMdtaValue列 |
| source_structure | 読み取り時の診断結果・mdta keys表の観測情報。復元命令には使わない |

ItemValueはkind、atom_data_type、payloadの組。native Item::typeとatomDataTypeは別の情報であり、どちらも保持する。bindingにatom_data_type/set_atom_data_typeを追加した。bool/int/int_pair/byte/uint/long_long/string_list/byte_vector_list/cover_art_listを明示する。型ごとに値域とpayload形状を検証する。配列の順序・重複・空値を保持する。画像はnative format番号とバイナリを保持し、高水準Artworkのsignature検証を経由して既存画像を拒否しない。読み書きできない画像formatは明示的に拒否する。

MdtaEntryはkey、source_key_index、valuesを持つ。MdtaValueはdata_type、locale、dataの組。例えばvaluesが [{data_type: 1, locale: 0, data: "first".b}, {data_type: 1, locale: 1041, data: "second".b}] なら、その順序と両値を維持する。dataはASCII-8BITの独立コピーとする。

未知Item型を[:unknown, type]として受理しない。未知atomの完全な生bytesは公開snapshotに含めない。値を持たないmdta keysエントリはflat APIで消えるため、grouped nativeからkeys表と空valuesを含めて取得する。初版のnative一括復元は空valuesのキーも明示的に扱う。公開replace_mdta_itemsの空配列拒否は維持し、一括復元の内部操作でensure-key/clear-valuesを行う。keys表を観測できないbackendではsnapshot_v1を拒否する。

## 比較契約

logical_equal?は通常itemのキー・型・atom_data_type・payloadと、mdtaキーごとの型・locale・バイナリ・値数・順序・重複を比較する。通常itemのキー順、mdtaの異なるキー間の順序、source_key_index、物理offsetは比較しない。値なしmdtaキーは論理値を持たないため論理比較から除き、構造比較で扱う。通常itemとmdtaは別領域であり、title等の高水準propertyへ読み替えない。

structure_equal?は論理一致に加え、対応範囲内で観測したmdta keys表の順序・index・値を持たないキーとmetadata配置を比較する。同一ファイルでの保持検証に使う。MP4全体のバイト一致や未知atomの一致を意味しない。別出力への復元では使用しない。

同じ保存先への復元では既存mdtaキーのindexを維持し、新しいキーはsnapshotのキー順で追加する。元indexの強制指定は行わない。

## 復元の範囲と原子性

初版の復元はTagLibが完全に扱える通常itemとmdtaの全体置換とする。保存先にだけ存在する管理対象itemは削除し、mdtaは値だけ消す。mdta keysエントリを物理削除すると他のindexも詰め直されるため、既存keys表は維持する。muxが追加した管理対象タグを残したい場合は、呼出側がsnapshotを明示的に構成する将来APIを別途設計する。初版に暗黙のmergeを入れない。TagLibのkey→Item変換とwriterが完全に往復できる組だけを受け入れ、例えばtmpo/intの16bit保存限界を32bit APIの値域と混同しない。入力snapshotの型だけでなくキーと型・atom_data_typeの組を事前検証する。

未知atomは削除対象に含めない。ただし未知atomのある保存先について安全な編集可否を診断し、保証できない配置は拒否する。通常保存で破損項目を暗黙に削除しない。

1. snapshot全体、形式版、各型、復元先の構造・能力を検証する。
2. 全通常itemと全mdtaの候補モデルをnativeで構築する。
3. 候補モデルが完全に成立した場合だけ、既存Tagへ一回で反映する。
4. 失敗時は呼出前のItemMap、mdta、dirty状態を維持する。Tag/公開ItemMapの同一性を維持する。

現行applyChangesは通常item更新とmdta削除を扱うが、複数キーのmdta置換とindexを維持する値削除をまとめてcommitする機能がない。Rubyでreplace_mdta_itemsを反復するだけではこの契約を満たさない。binding専用native層へ一括復元を追加し、既存の候補作成・状態移送を再利用する。grouped nativeのmdtaStatusはilst参照を必要とするため、default構築したTagをpublic APIで編集する方法は使わない。TagPrivate内部でItemMap/MdtaState候補を作り、実Tagの構造文脈で検証する。一キー置換のサイズ検証も再利用する。対象Fileをcloseして作り直すrollbackは使わない。

保存は既存の一時コピー、native状態移送、独立再読込、照合、rename、再openを使う。新しい保存基盤は作らない。保存前失敗・一時ファイル検証失敗は原本を置換せず、編集状態を残す。rename後の再open失敗は既存MdtaSaveErrorのcommitted=true/phase=:reopenで報告する。その他のphaseも既存契約を維持する。flush/close・電源断までの永続化保証は追加しない。

## 読み取り専用診断

Tag#metadata_diagnosticsはstatus、issues、capabilitiesを持つRuby所有の不変reportを返す。issueは安定したcode、metadata領域、atom path、観測indexと必要な説明を持つ。診断自体は修復も書き込みも行わない。

handler/keys不整合、zero/out-of-range index、複数meta、未知namespace、曖昧な混在、未対応Item型を分類する。診断不能は:unknownとし、restorable?をfalseにする。mdta_statusだけから詳しい理由を推測しない。非対応構造でも読み取り可能な診断を返し、snapshot取得は完全性が証明できなければ例外とする。

mdir-only通常タグは通常item snapshotを対象とする。editable mdtaと対応可能な混在は扱う。mdir-onlyへのmdta新設、複数meta、曖昧な混在、fragmented等の既存native非対応構造は拒否する。mdtaのないsnapshotをeditable出力へ復元する場合は管理対象mdta値を消し、既存keys表を残す。native一括復元のclear-values操作を用い、removeMdtaItemによるkeys表の詰め直しは行わない。

## 字幕保持: 初版から必須

字幕のsampleとtrack構造はmetadata snapshotへ格納しない。MListNewは字幕保持用manifestを別に取得し、mux/音声変換でコピーし、出力照合の成功後にだけ原本を置換する。

manifestは字幕の本数、codecと必要なcodec設定、言語、名称、default/forced等の属性、表示タイミング、sample payloadの内容を観測する。複数の同一字幕も多重集合として数え、一つに縮退させない。mux後に変わるtrack ID、stream index、chunk offsetは同一性に使わない。

QuickTime chapter参照で使われるtext trackを、handler=textという理由だけで字幕と判定しない。subtitle handler/codecとchapter参照を併せて識別する。stpp等の未対応字幕、sample/timing解析不能、識別不能は保持確認不能として明示的に拒否する。

コピー経路ではcodec設定・payload・有理数として正規化した表示タイミング・必要属性の完全一致を求める。字幕変換や意図的な時間移動は初版の保持成功としない。字幕muxで追加する字幕は、既存字幕保持と追加字幕の期待値を分けて検証する。初版の検証済みcodecはmov_textのみとし、その他は保持確認不能として拒否する。確認したFFmpeg n9.0.2はコピー時にbtrtを追加/重複し、extradata hashを変える。これを黙って無視しない。-write_btrt 0で生成・コピーしたfixtureでは設定とpayload/timingが一致した。MListNewでのオプション採用はMListNew側で判断し、設定不一致の出力は原本を置換しない。字幕の追加によるdefault属性変更も期待値を明示する。

gem単独の通常保存では既存mdat照合を維持し、字幕付きfixtureでtrack/sample/timing/属性も壊さないことを確認する。mdat一致だけを字幕構造の完全保持の証拠にしない。チャプターは復元しないが、通常保存で既存チャプターを壊さない回帰テストは残す。

## property互換性

snapshot復元でset_property/title=等は使わない。高水準setterによる正規化を発生させないため。

現在のset_property/set_properties/remove_propertyで通常itemを更新・削除し、対応mdtaを削除する関係は以下。既存実装は変更しない。

| property | ilst | 削除するmdta |
|---|---|---|
| title | ©nam | title |
| artist | ©ART | artist |
| description | desc | description |
| TVShowName / show | tvsh | show |

その他PROPERTY_ATOMSのpropertyは対応するilstキーのみを操作する。native title=は両backendの試作テストでtitle mdtaを残した。set_property(title)のmdta削除と混同しない。今回snapshot実装で個別setterの意味は変えない。その他のnative個別setterもこの表の対象とはしない。copyright高水準APIと更新影響APIは後続機能。

## 機能検出・バージョン

最低実装versionは2.3.2.8（未配布）。2.3.2.7には公開snapshotはない。legacy nativeはTagLib 2.3.2＋patches/taglib/0001＋0002、grouped nativeはproposals/0001＋0002＋0003を必要とする。既存nativeでもbindingはビルドできるが、snapshot能力はfalseになり取得・復元を拒否する。配布artifactの動作確認は別途必要。

新実装ではTag#metadata_capabilitiesを設け、snapshot_v1、atomic_restore_v1、diagnosticsの対応と拒否理由を返す。respond_to?はRuby APIの存在確認に使い、native能力と対象ファイルの対応可否はcapabilities/reportで確認する。legacy backendの:unknownをeditableとして扱わない。

## 実装と受入検証

内部File#metadata_snapshotは比較用で未知型を省略しており、そのまま公開しない。共通の型付き読み取りを切り出し、内部比較と公開snapshotから利用する。mdta indexを含む既存保存検証は維持し、別ファイル間の論理比較だけ新契約にする。

実装順: 診断とcapabilities → 不変snapshot/比較 → native一括復元 → 既存保存検証との接続 → MListNew移行。先行してMListNewの復元を2.3.2.7の一キー一括置換へ移す。

合成実MP4と一時コピーのみを使い、以下を確認する。

- source close/GC後の利用、snapshotの深い不変性、画像複数枚・順序・バイナリ。
- 全Item型、mdta同/異locale、異型、重複、NUL、空バイナリ、新規キー、異なるindex、繰返し復元/保存。
- 別ファイルの論理一致と同一ファイルの構造一致を区別。未知型・値なしkeys・不正index・handler不整合・非対応構造を黙って省略しない。
- 最後のキーで不正入力/候補構築失敗を注入し、全キーとdirty状態が呼出前と一致。保存失敗とrename後再open失敗を区別。
- 字幕muxと音声変換の両経路で、タグ・画像・既存字幕を保持。字幕の脱落・重複縮退・属性変更・timing変更を検出。
- property更新・単一値setter・通常保存・既存チャプターの互換性。

MListNewのtests/mp4_zero_index_repairer_test.rb内のtest_multiple_values_after_existing_mux_are_detected_not_acceptedを再現fixtureの出発点とする。このテストを実ファイルで確認した。消失検出・拒否を証明するもので、保持成功を証明しない。旧版で消失を再現するケースと新版で完全一致する成功ケースを分ける。元fixtureを変更せず一時コピーで実行する。

引渡しでは使用例、対応構造、最低version、能力検出、保存エラー契約とbackend/OS/配布artifactごとの検証結果を提示する。未検証native、正式な上流取り込み、全ABI/各配布先、字幕codecごとの検証は未完了として明記する。

## 提供テストの確認

`/tmp/mp4_zero_index_repair_test.rb` は確認した。合成動画・音声・mov_text字幕にmdtaを追加し、customのindexを0へ破損させた後、限定修復とtitle実更新を検証する。原本SHA-256の不変、修復許可領域外bytes、画像、チャプター、ffprobe streams、警告の増加を検証している。

このファイルには `test_multiple_values_after_existing_mux_are_detected_not_accepted` は含まれていない。同一キーの二値を作成して復元するケースも含まれないため、複数値消失の再現テストとしては未確認。その後MListNew本来のテストファイルで該当メソッドを確認した。

提供テストは相対requireでprototypeとMListNew libsへ依存し、単独配置では実行できない。今回実行済みと扱わない。修復テストをsnapshotの通常保存へ混ぜず、診断・拒否ケースと明示的修復ケースを分ける。

字幕の確認はffprobe streams比較に加え、字幕sample payload・表示timing照合を追加する。warning-originsの字幕title/画像による警告は、利用するFFmpeg版も記録し、警告だけを破損や保持失敗の判定にしない。

## 設計試作の結果

[試作検証記録](Memos/2026-10-08-mp4公開snapshotの設計試作検証.md)に実行手順と成功/反例の区別を記録した。Ruby試作は本番公開APIではない。単純なcapture/restoreが実MP4で論理往復する一方、atomDataType欠落・keys削除のindex変化・flat一覧のキー欠落を再現した。これらを許容する実装にはしない。

MListNewの現行preserved_by?は重複数を比較するが同一キー内の順序を比較しない。gemのlogical_equal?は順序を比較する。MListNew移行時にはpreserved_by?のsubset契約とgemの完全一致を混同せず、期待する追加タグを明示する。

読み取り専用診断、native一括commit、atomDataType binding、空valuesのkeys APIを実装した。実装検証は[検証記録](Memos/2026-10-08-mp4公開snapshotの実装検証.md)を参照。macOS arm64の隔離grouped/legacy bindingとmov_text以外の配布先/codecは未検証。

## 実装形式と明示的な制限

snapshot.itemsは `[key, kind, atom_data_type, payload]`、snapshot.mdtaは `[key, source_index, [[data_type, locale, binary], ...]]`。mdtaには値のないキーも含める。取得値はRuby所有でdeep freezeする。手動構成にはMetadataSnapshot.newを使い、取得時と復元時の両方で入力を検証する。

診断statusのabsentはmdta不在を表し、通常mdirタグが存在しないという意味ではない。

対応構造はmetadataなし（通常itemのみ復元可能）、または単一のmoov/udta/metaで、mdir＋ilst（mdtaなし）、またはmdta＋keys＋ilst（通常iTunes項目を併存可能）。mdirへmdtaキー表を新設する復元は初版で拒否する。複数meta、別scope、fragmented MP4、handler/keys不整合、不正index、未知/未表現の通常itemは拒否する。構造診断は修復しない。診断はmetadata最大64MiB、atom最大50,000個、探索深度8の上限を持つ。

mdtaと通常binary itemのNUL・空binaryを保持する。通常textのNUL/不正UTF-8はnative parserが完全保持できないため拒否する。通常itemの重複atom、非ゼロlocale、異種data型の混在（covrの画像formatは除く）、scalarの複数dataも拒否する。通常itemの型とwriterの実際の往復を候補commit前に検証する。

成功したメモリ復元では既存ItemMap wrapperは利用できるが、置換前の借用Item/画像wrapperは無効になる。復元失敗では借用wrapperも編集状態も維持する。save成功時は既存のclose/reopen契約どおり古いnative wrapperを再利用しない。rename後のreopen失敗時も元snapshotは利用可能だが、Fileは閉じているため独立して開き直す。
