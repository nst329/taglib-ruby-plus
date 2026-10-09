# 未対応mdtaの保持保存とchapter時間修復の設計

状態: テスト検証後に製品実装・両backendの実ファイルコピー検証を完了。

## 前提とテスト順序

ユーザーの指示に従い、まずtest/mp4_repair_investigation_test.rbと独立したfixture helperを追加し、合成fixture・実ファイルのコピーで現行挙動と候補処理を検証した。その結果を根拠として本設計を作成した。テスト内の試作を製品の修復APIとして提供するものではない。

対象は010226_001.mp4の別問題である。複数trefの欠落参照修復とは分けて保存する。原本への書込みは禁止し、実ファイルのコピーでだけ保存を試す。上流TagLibの個別コミット選定・比較は扱わない。

## 確認できた原因

### index 0のmetadata

実ファイルのmoov/udta/metaはhandler=mdta、keys21件に対し、先頭21件のilst item名がすべて00000000だった。mdtaのindexはkeysを参照する1始まりの値であり、0は対応先を持たない。その後に通常のiTunes itemがある。

legacyでは複数の0 itemが空文字キー1件として見え、writerで消え、keys情報も変わる。通常saveのverifyが置換を拒否する。groupedでは0 itemを公開viewに出さず、metadata status=Unsupportedによりnative保存自体がfalseとなる。この違いを合成fixtureで確認した。正常な1/2 indexと通常titleの混在は保存できる。

keysの順序を逆にしても、0 itemのnative viewは同じになる。keys件数と0 item件数が一致しても、位置順で対応を復元できる証拠にはならない。空キーを単に削除したり、1〜21を推測で割り当てたりしない。

### chapter writerの単位と幅

高timescaleのmvhdだけを合成fixtureへ設定し、未変更のnative writerに15章を生成させたところ、以下の値とffprobeの1章表示を両backendで再現できた。chapterの時間atomを手で注入する必要はなかった。

| フィールド | 生成値 |
|---|---:|
| mvhd v1 timescale | 441000000 |
| mvhd duration | 1605653349300 |
| mdhd v0 timescale | 1000 |
| mdhd duration / stts合計 | 3640937 |
| stts sample数 | 16（padding＋15章） |
| tkhd v0 duration | 3640937 |
| elst v0 segment_duration | 3630547892 = 0xd865c3b4 |

検証に使用したnative sourceのmp4qtchapterlist.cppでは、readMovieInfoが64bitのmovie durationをunsigned intへ縮め、buildChapterTrakのmovieDuration引数もunsigned intである。tkhdにはmedia timescaleから算出したtotalDurationを書いている。elstには縮めたmovieDurationをv0で書く。

したがって、このwriterに対する生成原因は「tkhdの単位誤り」と「movie durationの32bit切捨て」と特定できた。実ファイルがどのソフト・版で生成されたかの履歴までは断定しない。値の一致をあらゆるファイルに対する自動修復根拠にはしない。

mvhdは3640.937300秒、mdhd/sttsは3640.937000秒で、0.3ms異なる。mediaからの厳密換算値は1605653217000、movie durationは1605653349300で差は132300 movie ticks。writerがmovie durationをmsへ丸める動作とも一致する。

## metadata: 採用する保持保存方式

### API案

既存saveは引数なしという契約を維持する。追加APIは次の形とする。

```ruby
# 明示的な通常タグ保持保存API。
file.tag.title = '更新する通常タグ'
file.save_preserving_unindexed_mdta
```

このAPIは不正indexの意味を復元する修復ではない。対応先のないraw itemとkeysをそのまま保持しながら、通常itemだけを安全に更新する保存ルートである。metadata_diagnosticsはinvalid_indexを引き続き報告し、完全なmetadata_snapshot/restoreは従来どおり拒否する。成功をmetadata構造全体の正常化とは扱わない。

### 初期対応条件

- 単一のmoov/udta/metaで、通常8byte metadata header、meta version/flags=0、単一hdlr/keys/ilst。
- handler=mdta、keysの件数・境界・namespace・UTF-8が正常で、重複keyがない。
- 不正numeric itemはindex0だけで、ilstの先頭に連続している。後続は対応済みの通常itemだけ。
- 有効numeric itemとの混在、非0の範囲外index、interleavedな0 item、未知の通常item、複数meta、handler不一致、不正境界は初期版では拒否する。
- 0 itemは各atomのraw bytesとして保持し、件数・順序・重複・data flags/locale/bytesを解釈せず保持する。
- 未保存のchapter編集、参照修復計画、時間修復計画との混在を拒否する。既存のchapter snapshot/read制限も維持する。
- legacyの空文字キーはnativeの代理viewであり、編集対象にしない。ユーザーがこの代理itemを変更した場合はprepareで拒否する。他の通常itemも型・encodingが復元可能でなければ拒否する。

この限定は実ファイルと最小再現fixtureで検証できた範囲を守るためであり、未対応を汎用的に受け入れるfallbackは作らない。

### 保存フロー

1. 原本からhandler、keys、先頭0 item群のraw bytes・場所・順序・digestを解析し、不変の保持計画を作る。ここでは原本やnative handleを変更しない。
2. 既存と同様に一時コピーを作る。
3. 一時コピー内だけで0 itemとkeysを外し、handlerをmdirにして、nativeが保存できる通常itemの作業用contextを作る。moov変更後のstco/co64も補正する。
4. 原本handleの通常itemから型付きsnapshotを作り、一時handleへ復元する。unsupportedな原本native状態の_copy_state_toは使わない。代理の空キーと不明なnumeric値はsnapshotへ入れない。
5. nativeに通常タグを保存させる。
6. 一時出力へ元handler、元keys、元0 item群を元の位置・順序で戻す。metadata外を再シリアライズせず、必要なoffsetだけを補正する。
7. 通常itemの期待値に加え、handler/keys/0 itemのraw bytes・件数・順序・位置、chapter、media、原本digestを別handleと独立した保持基準で検証する。
8. 成功した場合だけ原子的置換して再openする。

「保存後に戻すだけ」の案はgroupedのnative保存拒否を解消しないため不採用。二段階の作業用contextを、対象profileに明示的に限定する。テスト内ではこの方法で両backendの合成fixtureと実ファイルコピーの保存が成功した。

既存のnative snapshot比較だけでは不十分である。試作後に2件目の0 itemを落とす故障を入れても、native viewが同じなので現行verifyは通ってしまう。製品化時にはraw保持signatureを必須とし、喪失・順序変更・重複削除・payload改変をverifyで拒否する。

### 失敗と資源管理

準備・native書込・raw再挿入・verify・replace・reopenを区別する。置換前の失敗は原本とpending通常タグを維持する。cleanup失敗は元の失敗をcauseに残してphase=cleanupとし、残った一時パスを示す。置換後の再open失敗だけcommitted=true。

moovをサイズ上限付きで読み、mdatは逐次コピーする。raw保持計画にFile/native/IOを保持しない。stco/co64の補正とoverflow拒否、source digestの再確認、mode保持は既存修復と同じ契約とする。

## chapter時間: 生成防止と既存ファイル修復を分離

### 新しいchapter生成の予防

このnative writerは最後のchapterをmovie終端まで作り、単一identity editを新設している。この新規生成では、tkhd durationとelst segment_durationは同じ64bit movie durationを使うことが正しい。mdhd/sttsには従来のmedia単位を使う。

- MovieInfo.durationと内部movieDuration引数を64bitにする。
- tkhdにmedia単位のtotalDurationを書かず、movie単位のdurationを書く。
- tkhd/elstの各durationが32bitに収まればv0、超えればv1を生成する。mvhdがv1というだけで必ずv1へ変更するものではない。
- timescaleとmvhdは変更しない。media durationのms丸め規約とsample時刻・paddingも今回変えない。
- durationの未知値、演算overflow、ゼロtimescale、atom/tableの幅超過を拒否する。換算の中間演算もoverflowさせない。

native private builderの改訂であり、個別の上流コミット取込み検討ではない。`0004-mp4-chapter-movie-duration.patch`として実装し、両backendを隔離ディレクトリで再ビルドしてwriter回帰を検証した。

### 既存ファイルの明示的な修復API案

```ruby
# 既存editの意味を推測せず、full-movie writer profileを明示する。
result = file.repair_native_chapter_timing(track_id: 4, profile: :taglib_full_movie)
file.save_chapters if result[:status] == :planned
```

診断だけで自動補正しない。初期修復は今回再現したprofileだけに限定する。

- 欠落参照修復済みで、strict readerが全chapter sampleを読める単一音声参照のtext/text track。
- mvhd v1、movie durationが32bit上限を超え、mdhd v0 scale=1000とstts合計が一致。
- tkhd v0 durationがmdhd durationと同じ数値になっている。
- elst v0、単一entry、media_time=0、rate=1、segment_durationがmovie durationの下位32bit。
- media durationがmovie durationをwriterのms丸め規約で換算した値に一致する。
- profileを呼出側が明示し、movie全域に対応するchapter trackとして直すことを選ぶ。

この条件から外れるものはunsupported/not_applicableとして理由を返し、計画を作らない。正常な短いeditを見た目だけで引き延ばさない。

profileが確定した場合の補正値はmovie duration=1605653349300とする。tkhdをv1へ、elstをv1へ昇格してこの値を設定する。生成writerのfull-movie意図を維持するためであり、mediaからの別値1605653217000を黙って採用しない。実ファイルはこの設計を採用するまで時間atomを変更しない。

tkhdのflags・track ID・creation/modification・reserved・matrix等、elstのmedia_time/rate、mvhd、mdhd、stts、chapter sample、他トラックを保持する。旧v0のcreation/modificationも値を保持してv1幅へ昇格する。

修復計画と通常タグ/metadata/参照修復を別保存にする。保存前に原本は変更しない。保存後は、昇格したatomの生成期待bytesとそれ以外のraw保持signatureを検証する。free領域を使える場合は消費し、不足時はmoovを拡張してstco/co64を補正する。offset overflowは昇格でごまかさず拒否する。

### readerの限定拡張

設計前のstrict readerはelst v0単一identity editしか受け付けなかったため、v1へ直しただけではchapter_snapshotが拒否する。v1、entry count1、media_time=0、rate=1、正しい長さ/flagsの読取を追加する。単一identity以外の制限は維持する。

テスト内のreader試作で、補正候補の15章を読めることを確認した。v1のトリミング、empty edit、速度変更、dwellは引き続きunsupportedとする。診断APIはそれらの生値を観測できるが、完全snapshotと時刻写像の対応範囲を混同しない。

### 自動修復してはいけない反例

| 入力 | 理由 |
|---|---|
| tkhdとelstが短い値で一致する | 正常なcropの可能性がある。下位32bit一致だけでは根拠にならない |
| media_timeが非0 / -1 | trim / empty editの意味を保持する必要がある |
| 複数editや同じmediaの反復 | 単純な合計値差では意味を復元できない |
| rateが1以外、rate=0 | speed変更/dwellの再生時間を持つ |
| mdhdとsttsが不一致 | どちらの値を正とするか決められない |
| mediaがmovieより短く、editなし | trackがmovie全域を占めるとは限らない |
| 正常なmovie tick丸め | editなしの換算差が1 movie tick以内なら不整合扱いしない |

## テスト済み事項と実装後の必須事項

テスト済み: 正常indexed mdta、0 itemの重複とnative viewの潰れ、非0範囲外、keys順の反例、backend間の失敗段階、二段階raw保持試作、2件目喪失を既存verifyが見逃す反例、原本不変、native writer自身による時間不整合生成、64bit補正候補でのmedia/章保持とffprobe16サンプル、v1 reader試作、正常editの反例、fixtureの外部パス・symlink編集拒否。

実装後に必要: raw保持signatureでのdrop/reorder/duplicate/payload故障拒否、各保存段階とcleanup/replace/reopen故障、pending変更混在拒否、co64/stcoとfree不足/overflow、全プラットフォーム、新native writerの境界値と生成時刻保持、通常APIの互換性、実ファイルコピーの明示profile時間修復後の再読込・タグ保存。これらを今回の試作テストの成功で代用しない。

[テスト結果](Memos/2026-10-09-metadataとchapter時間の設計前テスト.md) / [ADR](ADR/2026-10-09-未対応mdtaのraw保持とchapter時間修復の分離.md)


## 実装したAPIと結果例

実リポジトリの参照修復API名は`remove_dangling_chapter_references`であり、`repair_chapter_references!`というメソッドは存在しない。

```ruby
TagLib::MP4::File.open(copy_path, false) do |file|
  removed = file.remove_dangling_chapter_references
  file.save_chapters unless removed.empty?
  # 修復前 source_track_id=2, tref_index=1, reference_index=0, target_track_id=4
  # 保存後 source_track_id=2, tref_index=0, reference_index=0, target_track_id=4

  diagnostic = file.chapter_timing_diagnostics.first
  # observations: [:tkhd_elst_duration_mismatch, :elst_matches_movie_duration_low32]
  result = file.repair_native_chapter_timing(track_id: 4, profile: :taglib_full_movie)
  # {status: :planned, profile: :taglib_full_movie, track_id: 4,
  #  before: {tkhd_duration: 3640937, elst_duration: 3630547892},
  #  after: {version: 1, tkhd_duration: 1605653349300, elst_duration: 1605653349300}}
  file.save_chapters if result[:status] == :planned

  file.tag.title = '通常タグの更新'
  file.save_preserving_unindexed_mdta
  # index 0の診断は残る。完全metadata_snapshotは引き続き拒否する。
end
```

fingerprint不一致は`{status: :not_applicable, reason: :profile_mismatch, track_id: ...}`を返して計画を作らない。不正構造・未対応chapter reader・未保存更新の混在は既存の診断例外で拒否する。保存失敗は`MdtaSaveError`の`phase`と`committed`で区別する。metadata保持保存はprepare/taglib_save/reinsert/verify/replace/reopen/cleanupを報告する。

## 実装後の確認と制約

実ファイル010226_001のテストコピーを両backendで修復した。欠落参照3件を除去し音声2→章4を保持、時間atomをv1へ昇格、通常タグを保持APIで2回保存できた。strict readerの15章、ffprobeの16サンプル（先頭paddingを含む）、全mdatの一致、外部原本SHA-256不変を確認した。

時間修復は実ファイルの生成履歴を特定したという意味ではない。呼出側がfull-movie意図を明示するprofileに限定する。metadata index 0の対応キーは復元せず、不正indexの診断を残す。通常`save`でこの不正metadataを保存可能にはしていない。

chapter readerはv1単一identity editを読めるが、チャプター自体のco64、mdhd v1、trim/empty/multiple/rate変更、複数chapter参照、未知modifier等は従来どおり拒否する。動画・音声側のco64はoffset保持対象として扱う。nativeの新規章生成もmedia時間32bitとstco範囲を超える入力を拒否する。

macOS arm64以外のnativeビルド、Windows/Linux、AVFoundationを含む各playerの表示は未検証。gemの公開・インストール済みnative bundle置換は行っていない。

[実装判断ADR](ADR/2026-10-09-限定atom編集と原子的保存の共用.md)
