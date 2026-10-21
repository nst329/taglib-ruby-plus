# MP4別出力保存: ハードリンク非対応ボリュームでの安全な確定

日付: 2026-10-21
状態: 実装済み。ローカル実renameと故障注入による回帰を確認済み。実SMB試験は未実施。

実装方針: 正しさ・原本保持・既存先の保護・公開API契約を満たしたうえで、**実装でもI/Oが少なくなる方針を優先する**。同じ候補・取得済みdigest・snapshot・世代handleを再利用し、修復と検証の再実行、追加の全面コピー、確定判定のための全体再読取を避ける。必要な保持検証は省略しない。

## 目的と前提

`save!(to: output)`が候補生成・独立検証を終えた後、SMBのFile.link非対応で停止する問題を扱う。既存出力の非上書き、原本保持、media・metadata保持の検証を維持し、同じ検証済み候補を追加コピーせずに確定する。

テスト共有は指定されていない。SMBの排他的rename対応、切断時の挙動、サーバー側の原子性は未確認。利用者のMP4・既存共有・実データには操作しない。

## 現行実装の確認

対象は`lib/taglib/plus_mp4.rb`と`plus_mp4_io.rb`。

1. `save!`は出力と同じディレクトリにTempfile.createで候補を作り、書込用Fileを閉じる。
2. `prepare_candidate`がコピー・必要な編集を行う。コピー時に原本digestとmedia署名を取る。
3. 候補にGenerationを作り、独立走査で出力digestを取得する。別handleで保持条件と要求snapshotを検証する。
4. 候補と原本の世代を確認する。
5. `publish_candidate`は原本置換ならFile.rename、別出力ならFile.linkを使う。成功return後にcommitted=trueとなる。
6. 原本置換だけがGeneration.publish_toでpathを引き継ぎ、検証済みbaselineを採用する。別出力では原本セッションを維持する。
7. ensureで候補Generationを閉じ、候補pathをunlinkする。ENOENTは既に移動済みとして許容する。

現行Errorはcode/area/phase/committed/output_path/temporary_path/issuesとcauseを持つ。cleanup失敗は新しいErrorのcauseに元の保存Errorを保持する。確定前失敗なら候補編集を保持して再試行でき、確定後失敗ならセッションを再利用不可にする。

問題は、publish例外が必ずcommitted=falseになる点である。ネットワーク経由の名前変更がサーバー側で反映されても、応答を受け取れない可能性を現在のbooleanだけでは表現できない。また`ensure_current!`の再利用拒否は現在committed=trueを固定するため、不明状態への拡張ではここも修正が必要になる。

## 方式比較と選択

| 方式 | 既存先の保護 | 追加の本文I/O | 判断 |
| --- | --- | --- | --- |
| File.linkのみ | 排他的作成 | なし | 既存経路として維持。非対応共有では保存できない |
| 最初から排他的renameのみ | OS/FSが対応すれば保護 | なし | link対応環境までOS依存を増やすため採用しない |
| link非対応時だけ排他的rename | OS/FSが対応すれば保護 | なし | 採用。変更範囲が確定処理に限られる |
| 存在確認→通常rename | 競合中に上書き可能 | なし | 不採用 |
| O_EXCL作成→コピー | 既存先は保護するが部分出力が見える | 全面読取・書込が追加 | 不採用 |
| mvコマンド・FileUtils.mv | 実装によって置換やコピーになる | 保証できない | 不採用 |

出力の予約用空ファイル、lockファイル、失敗候補からのアプリ側救済、成功後の再編集・再検証は追加しない。

## 確定フロー

原本置換の方式は今回変更しない。別出力の確定を内部の専用helperへ分離する。

1. File.link(candidate, output)を一回だけ試す。
2. 成功したら確定成功とし、renameは呼ばない。
3. EOPNOTSUPPまたはENOTSUPだけを捕捉する。OSに定義されたErrno定数で判定し、同じerrno値のaliasは重複排除する。メッセージ文字列では判定しない。
4. macOS対応bindingを準備し、同じcandidateへrenamex_np(candidate, output, RENAME_EXCL)を一回だけ呼ぶ。
5. return=0なら確定成功。candidateの名前は消えていることが正常となる。
6. binding/OS/FSが非対応なら明示的に失敗する。通常rename・コピー・link再試行へは進まない。

EEXIST、EACCES、EPERM、ENOSPC、EIO、通信エラーなどはfallbackの条件にしない。排他的renameから戻ったEOPNOTSUPP/ENOTSUPも失敗で終了する。EXDEVもコピーせず失敗する。

`validate_output!`の事前チェックは早いエラー表示として残せるが、競合防止の根拠はFile.link/RENAME_EXCLの排他的操作とする。壊れたsymlink、ディレクトリ、別プロセスが直前に作成した出力も上書きしない。失敗・cleanup時にoutputを削除しない。

## 対応OSとbinding

リポジトリの配布workflowはarm64-darwin/x86_64-darwin、deployment target=12.0、Ruby 4.0。source gemはRuby>=3.2で、CIにはUbuntu上のRuby 3.2/4.0がある。Windows向けの説明も残るため、Plus全体をmacOS専用にしない。

初期fallbackはmacOSのみ。Linux・Windows等は従来のlink成功経路を維持し、link非対応時は`:exclusive_publish_unsupported`で終了する。Linux renameat2(RENAME_NOREPLACE)等への拡張は別の実装・試験とする。対応OSでも共有が排他的renameを実装しているとは見なさない。

採用案は、内部`ExclusiveRename` helperからFiddleでmacOS関数だけを呼ぶ方式。Fiddleをgemspecの実行時依存に明示し、link非対応時のmacOS経路だけで遅延require/関数解決する。既存TagLib拡張のABI・SWIG生成物・TagLibパッチは変更しない。Fiddleが現在このホストで読めることは確認したが、隔離配布環境での解決は実装時の確認事項である。

既存native拡張への小さなC helper追加案も安全性は確保できるが、今回だけのsyscall接続にnative再生成・各CPUの再ビルドと新entrypointが必要になる。Fiddle案では依存追加と型宣言の検証が必要だが、Ruby側の保存処理を小さく保てる。両案の確定時の本文I/Oは同じ。

bindingの条件:

- renamex_npの引数はpath pointer 2つとunsigned int flags、戻り値はint。RENAME_EXCL=0x4。他のflagは渡さない。
- パスは絶対pathを使い、NULとfilesystem encodingをRubyのファイル操作と整合させる。native呼出し中の文字列寿命を保持する。
- blocking呼出しでGVLを解放できるbindingを使用し、errnoは失敗直後にFiddle.last_errorから取り込む。別のnative呼出しを挟まない。
- symbol不存在・LoadErrorは確定操作前の非対応として扱う。未対応OSでmacOS symbolを探索しない。symbol参照はプロセス内で再利用できるが、ボリューム能力の永続キャッシュは作らない。
- Ruby 3.2/4.0と両macOS配布gemで実際のABIとerrnoを検証する。依存versionの下限はその確認後に確定し、上限を理由なく固定しない。

根拠: [Appleのrename仕様](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/rename.2)、[Appleのheader](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/stdio.h)、[Ruby Fiddle::Function](https://docs.ruby-lang.org/en/3.4/Fiddle/Function.html)、[Fiddle.last_error](https://docs.ruby-lang.org/ja/latest/method/Fiddle/s/last_error.html)。SDK headerでもrenamex_npとRENAME_EXCLの定義を確認した。仕様の存在はSMB共有の対応を意味しない。

## 世代とhandleの扱い

候補のGenerationは確定直前まで元pathと開いたhandleを照合する。rename成功後の別出力に旧候補pathのcheck!を実行しない。別出力はbaseline採用を行わず、候補Generationのhandleはensureで閉じる。File.link成功時もこの寿命を維持する。

RENAME_EXCLは候補の名前を変える操作なので、既に検証したbytesを再構成する必要はない。result生成には独立検証で得たdigestとsnapshotをそのまま使用する。原本置換用のpublish_toを別出力へ流用しない。

## 確定有無を表す公開契約

ネットワークでsyscallのエラーが返っただけでは、常に「未確定」を証明できない。SMB切断時にoutputのexist?/statが失敗しても、不在の証拠にはならない。名前・size・digest一致だけでも他writerの出力との所有関係は確定しない。このため自動再照合で成功へ読み替えず、不明を独立状態として返す。

Errorに`publication_status`を追加する。値は次の3つとし、内部の「未試行」は`:not_committed`へまとめる。

| publication_status | committed | 意味と対応 |
| --- | --- | --- |
| :not_committed | false | 確定未試行、binding準備失敗、または明確な拒否。既存の再試行可能性は維持 |
| :committed | true | link/renameの成功を受け取った。後続失敗でもtrueを維持 |
| :unknown | nil | 呼出しを試行したが確定有無を保証できない。自動再試行せずセッションを閉じる |

`committed: nil`は既存boolean契約の拡張であり、パッチ更新に無条件で紛れ込ませない。リリースノート・API仕様・MListNewの失敗処理を更新し、互換性変更を明示する。`publication_status`だけを追加してcommitted=falseを残す案は「未確定」と誤認させるため採用しない。

原本置換のFile.renameも応答不明になり得るため、共有する保存状態の報告は同じ規則に合わせる。置換方式自体は変更しない。新しい状態管理をfallback経路だけに限定して、既存link経路の不明をfalseへ隠すこともしない。

内部はsave一回ごとに確定状態を所有する。操作直前にunknownへ置き、成功return直後にcommittedへ、明確な拒否ならnot_committedへ移す。link非対応→fallback準備中はnot_committed。追加I/Oを伴う推測は行わない。

明確な拒否として扱うerrnoは実装時の表で固定する。初期案はEEXIST/EACCES/EPERM/ENOSPC/EDQUOT/EROFS/EXDEV/EINVAL/ENOTSUP/EOPNOTSUPP/ENOSYS/ENOTDIR/ENAMETOOLONG/ELOOP。EIO/ETIMEDOUT/ECONNRESET/ENOTCONN/EHOSTUNREACH/ENETDOWN/ESTALE/EINTR、既定外の例外、呼出し後に発生したRuby側エラーはunknownとする。ENOENTもネットワーク再送等による不明を否定できないため初期案ではunknownとする。errnoの分類はfallback判定とは別に管理する。

この表はOSが返したエラーの意味に基づくクライアント側の判断であり、サーバー・OS内部の再送や非準拠実装まで含む完全保証ではない。後日の試験で曖昧さが判明したerrnoはunknownへ寄せ、推測でfalseにしない。gem側は名前操作を自動再試行しない。

Rubyの非同期割込みでも、syscall試行から成功記録までに中断した場合はunknownが残る設計にする。例外を握り潰したり、通信失敗を通常の非対応へ変換しない。

## 例外・cleanup・残存物

既存phaseとpath情報、causeを維持し、issues.detailsへ`publication_method`（link/exclusive_rename/replace）、元のlink非対応errno、実際の失敗errnoを追加する。通常ログは方法・errno・状態の短い一行に留め、payloadや全snapshotを出さない。

- binding非対応はcode=:exclusive_publish_unsupported、phase=:publish、committed=false。元のlink例外とbinding側の拒否をcause chainまたは構造化detailsに残す。
- その他のOSエラーは既存の保存Error境界へ伝達し、直接原因のSystemCallErrorをcauseに残す。一般のI/Oエラーを非対応codeに置き換えない。
- 確定成功直後に状態をcommittedへ更新する。結果組立・handle close・cleanupの失敗でも元に戻さない。
- link成功後は候補pathが残るのでunlinkする。rename成功後は元候補pathが消えるためunlinkのENOENTを正常とする。
- `temporary_path`は「候補に使ったpath」であり実在保証ではない。rename後のcleanupエラーでも履歴として記録できる。exists?失敗をfalseとして報告しない。
- 確定前の明確な失敗では従来どおり候補をcleanupする。競合先outputは絶対にcleanup対象へ含めない。
- unknownでは候補pathの自動unlinkを行わず、復旧判断のため残す。rename反映済みなら残っていない場合もある。再接続後の残存確認・削除は利用者が所有関係を確認してから行う。
- cleanup失敗はphase=:cleanup/code=:cleanup、同じpublication_status/committedとpathを持つ。元の保存Errorをcause、cleanupの型・errno・messageをissuesへ残し、両方を追えるようにする。
- unknownとcommitted後失敗はセッションを再利用不可にする。再利用拒否Errorにも元の状態を渡し、unknownをcommitted=trueへ変換しない。closeは可能とする。

不明時はcode=:publication_unknownを提案する。再利用拒否は未知状態なら同じcode、確定後失敗は既存:committed_failureとし、既存の確定成功後エラー判定を維持する。失敗した操作を再実行する自動復旧APIは追加しない。

成功結果のoutput_path/source_digest/output_digest/operations/removed/snapshots/verificationは維持する。限定修復結果のcommitted=trueも維持する。通常保存の結果に従来存在しないキーを無条件に追加する変更は行わず、状態拡張はErrorを中心に定義する。

## I/Oと安全性

link成功時は従来どおり1回の名前操作、link非対応時は失敗link 1回+排他的rename 1回となる。候補生成、修復、原本コピー、出力走査、native独立検証は各々の既存経路を一度だけ実行する。fallbackによる追加の本文読取・書込・hash走査・独立再読取は0回とする。

CPU/メモリの増加は状態値、短い診断、binding定義程度。Fiddle読込にはライブラリ自身のI/Oがあるが、MP4全面コピーではない。サーバー内部でrenameが実際に行うI/Oや転送量までは保証しない。速度改善率は未計測。電源断時の永続性、fsync、外部writerとの完全排他は今回拡張しない。

## 実装と検証

製品コードに内部`Publication::ExclusiveRename` helperを追加した。別出力では候補生成・独立検証後に`File.link`を一回試し、EOPNOTSUPP/ENOTSUPだけをmacOSの`renamex_np(RENAME_EXCL)`へ渡す。候補の本文を再コピーせず、Fiddle関数は遅延解決して再利用する。利用アプリのmonkey patchは不要である。

確定状態はsaveごとの`Publication::State`に集約した。syscall試行前はunknown、成功return直後はcommitted、明確な拒否はnot_committedとする。unknownでは候補をcleanupせず、`Error#publication_status`を`:unknown`、`committed`を`nil`として返す。確定後のcleanup・結果生成失敗はcommittedを戻さない。

製品コードの内部確定helperをテストだけで差し替えられる境界にし、保存一連を省略したmockだけでは保持検証済みとしない。

| ケース | 必須の確認 |
| --- | --- |
| link成功 | rename未呼出し、候補生成/検証各1回、原本hash不変、出力digest一致 |
| link非対応→実排他的rename成功 | 同じ候補inode/bytes、元候補path消失、cleanup成功、独立再読取で期待値一致 |
| 競合EEXIST | link直前とrename直前の両方に競合注入。既存先とsymlink先が不変、committed=false |
| linkのEACCES/ENOSPC等 | fallback 0回、原本保持、直接cause維持 |
| rename非対応/権限/容量等 | 明示失敗、コピー/通常rename/再試行なし、phase=:publish、原因情報保持 |
| binding不存在/非macOS | link対応経路は正常。link非対応時だけ明示拒否 |
| 生成/修復/検証失敗 | link/rename 0回、原本保持、一時生成物cleanup |
| rename成功後のresult/close/cleanup失敗 | committed=true、旧候補path消失を許容、output不変、再利用不可 |
| publish失敗+cleanup失敗 | 元保存Error→SystemCallErrorのcause chain、cleanup側詳細、状態/pathを保持 |
| 操作せずタイムアウト/操作後タイムアウト | 両方unknown/nil、候補削除・自動再試行なし、output有無から成功を推測しない |
| 割込み | 試行中unknownの維持と誤cleanup防止、例外伝播 |
| 通常保存/無変更コピー/原本置換 | 既存result、snapshot、世代採用、競合とcleanup契約の回帰 |
| 限定修復+snapshots | operations/removed/snapshots、Nero/chpl、track/packet/time、metadata/artwork、非対象atom保持 |
| I/O回数 | prepare_candidate、repair write_copy、verify_candidate、Stream.scanを観測。link成功時とfallback時で本文処理回数・範囲が同じ |

macOSローカルの実renamex_npでは未存在先への移動と既存先へのEEXISTを確認する。Linux等で通常renameを使って成功に見せかけるテストは行わない。rename非対応や通信状態は故障注入と明記する。

実SMB共有が明示されれば、共有内の専用一時ディレクトリに合成fixtureだけを生成し、正常・競合・残存物を確認する。切断試験は共有の他利用者へ影響するため、対象・切断方法・再接続手順の明示的許可がある場合だけ実施する。試験終了時もunknownで所有不明のoutputを無断削除しない。

## MListNewへの接続と配布

成功経路はgem更新後も既存の`plan_limited_repairs → apply_limited_repairs → save!(to:)`を使用できる。新しいoption、atom編集、候補救済処理は不要。

失敗処理ではunknownをfalseと同一視しない変更が必要となる。

```ruby
begin
  result = file.save!(to: repaired_path, snapshots: [:metadata])
rescue TagLib::Plus::MP4::Error => error
  if error.publication_status == :unknown
    # 出力・候補pathと原因を記録し、自動再試行せず処理を停止する。
    logger.error("save publication unknown: #{error.output_path}; #{error.message}")
  elsif error.committed == true
    # 確定済み。cleanup等の後処理失敗として記録する。
  else
    # 確定前失敗。phase/causeを使い、既存の再試行方針で判断する。
  end
  raise
end
```

旧gemも扱う場合はrespond_to?(:publication_status)で機能を判定する。旧gemのcommitted=falseから今回のunknownを再構成することはできない。unknown発生時には当該Fileをcloseする。

gemspecは明示ファイル一覧のため、新helper・テスト・Docs/ADRの同梱を確認する。Fiddle依存を加えたsource/native gemの隔離installとBundler解決を試験する。既存workflowはvタグpushまたはpublish指定のworkflow_dispatchでGitHub Packagesへ公開できるため、設計・実装依頼だけではそれらを実行しない。version更新・tag・push・公開は別途依頼範囲を確認する。

## 今回確認済みの範囲

保存・Error・Generation・cleanupと関連テスト、README・gemspec・CI/native配布workflowを読み取った。ローカルSDKにrenamex_np/RENAME_EXCL定義があり、ローカルRubyでFiddle 1.1.8をrequireできることを確認した。公開仕様を確認し、排他的renameがボリューム能力に依存することを確認した。

実SMB試験・配布操作は未実施。ローカルmacOSのrenamex_npが利用できることは確認したが、SMBサーバーの排他的rename対応や切断時の確定有無を保証しない。次節のローカル試験を「製品のSMB対応検証済み」とは扱わない。

## テストコードでの設計確認（2026-10-21追記）

追加ファイル:

- `test/support/exclusive_publication_design_probe.rb`: 製品からrequireしない試験専用の確定処理。File.linkの失敗を指定でき、fallbackは実際のrenamex_np(RENAME_EXCL)を呼ぶ。通常rename・全面コピーは使用しない。
- `test/mp4_separate_output_publication_design_test.rb`: 製品の確定helperへ故障注入境界を差し込み、本物の候補生成・限定修復・独立検証・結果生成・cleanupを実行する。アプリ用monkey patchは追加していない。

環境はRuby 4.0.7 / arm64-darwin27 / Fiddle 1.1.8。日本語名の原本・別出力を専用一時ディレクトリに作り、映像・音声・通常字幕mov_text、JPEG artwork、metadata、正常Neroを含む合成MP4を使った。全試験はローカルボリューム上で実施した。

| 確認対象 | 実測結果 | 設計への反映 |
| --- | --- | --- |
| 現行File.link成功 | 別出力digest、原本hash、metadata/chapters snapshotを維持 | 現行成功経路を継続 |
| ENOTSUP/EOPNOTSUPP→実rename成功 | 両errnoのfallbackが成功し、元候補pathは消失。出力dev/ino/sizeが候補と一致 | 同じ検証済み候補の移動で完結できる。本文コピー不要 |
| link直前の競合 | 実File.linkがEEXIST。競合ファイル不変 | 事前exists?に依存しない |
| rename直前の競合・symlink | 実RENAME_EXCLがEEXIST。競合ファイル、symlinkと参照先が不変 | 排他的renameだけを使用する |
| linkのEEXIST/EACCES/ENOSPC/EIO/ETIMEDOUT注入 | renameは0回 | fallback条件を非対応errnoだけに限定 |
| renameの非対応/権限/容量/I/O故障注入 | 一回のrenameで終了。出力なし、原本hash不変 | 次の方式へ切り替えず失敗 |
| 候補生成・検証失敗 | 確定処理0回、原本保持、部分生成物cleanup | 保存の順序と検証境界を維持 |
| rename成功後のcleanup失敗 | committed=true、outputあり、temporary_path文字列はあるがファイルはない | temporary_pathを残存保証と説明しない |
| rename権限失敗+cleanup失敗 | causeは保存Error→EACCES、cleanup文言も保持。候補は残る | 元保存原因を失わず、cleanup自身の詳細もissuesへ残す |
| 実rename後にETIMEDOUT注入 | outputは検証済みdigestで存在し、committed=trueを維持 | 確定後の失敗で状態を戻さない |
| rename前にETIMEDOUT注入 | 候補を保持し、committed=nil/publication_status=:unknown | unknownでは候補をcleanupせず、セッションを再利用しない |
| timeout+cleanup失敗 | unknownではcleanupを呼ばず候補を保持 | 候補保持をcleanupエラー頼みにしない |
| 通常metadata編集の別出力+snapshots | 実rename経路で保存・digest・要求snapshotが一致 | 通常保存と限定修復で同じ確定helperを使える |
| 原本置換 | 世代採用後のmetadata取得・変更なし状態が正常 | 別出力renameへ原本置換用の世代採用を追加しない |

「非対応」「権限」「容量」「タイムアウト」は故障注入であり、実共有の障害を起こした結果ではない。unknownの試験は、確定有無を断定せず候補を保持する実装契約を確認する。

## I/Oの測定結果と実装条件

限定修復のlink成功、ENOTSUP fallback、EOPNOTSUPP fallbackで、候補生成・修復・検証をTracePointで観測した。各save一回につき次が一致した。

| 観測した処理 | 各経路の回数 |
| --- | --- |
| prepare_candidate | 1 |
| ChapterReferenceRepair#write_copy | 1 |
| verify_candidate | 1 |
| Stream.scan | 2（原本から候補へのコピー走査1、候補の独立走査1） |

出力digestも全経路で一致した。原本SHA、Nero/chplとmetadata/artworkを含むudta全体、解除対象以外のtrack atom・参照、mdat hashを比較し、ffprobeでpacket data_hash・PTS/DTS・duration等をpos以外すべて比較した。streamのcodec/time_base/duration_tsも一致した。

これはRubyの主要全面処理回数の観測であり、nativeの部分読取、全syscall数、OSキャッシュ、ネットワーク転送、サーバー内部I/Oの測定ではない。候補のdev/ino/size取得はprobeの検証用で、製品へ追加するI/O要件ではない。

実装では次を必須にする。

1. fallbackをsave!全体のrescue/retryで実現しない。確定helper内の名前操作だけを切り替える。
2. binding準備時に候補の再コピー・再hash・再openをしない。既存の候補Generationを確定直前まで保持する。
3. 結果生成は既取得digest/snapshot/operationsを使う。rename成功後に候補pathを再解析しない。
4. probeが都度作るFiddle関数は、製品では遅延解決した関数を再利用する。ボリューム能力判定の事前probeや常設lockファイルは作らない。
5. unknown判定のためのexist?/全体hash照合や、自動再試行を追加しない。I/O失敗を不在へ変換しない。
6. unknownでは自動unlinkを省き、pathと状態だけを報告する。明確な未確定・確定成功のcleanupは既存どおり実施する。
7. 保存前検証は省略せず、通常保存・限定修復の両方で上記処理回数を回帰検証する。

## 実装で固定した追加事項

確定状態は内部helperからErrorへ属性を渡すだけでは足りない。現行save!の外側rescueがcommittedのlocal値で上書きし、ensureが候補を削除するため、save!が所有する状態を単一の根拠とする。handle close・unlink・再利用拒否も同じ状態を見る。renameを呼ぶ前のbinding失敗と、呼出し試行後の応答不明を区別する。

現行cleanupのcause chainは元保存失敗を維持できたため、互換性を保って再利用する。ただしcleanup自身の型・errnoは現在messageだけになるため、新設計ではissuesへ明示的に加える。close失敗で後続unlinkへ到達できない経路も、実装時の追加試験対象とする。

実行結果: 新規13 tests / 236 assertions、失敗・エラー・省略0。chapter関連72 tests / 869 assertions、既存設計probe21 tests / 151 assertionsも成功した。`plus_mp4_io_test.rb`は環境に`shoulda-context`がないため未実行である。試験用Rubyファイルの構文チェック成功。実SMB共有、Ruby 3.2、Intel macOS、非Darwin、symbol不在、非同期割込み、handle close失敗は未検証である。

## 実装後のAPI使用例

通常の保存呼出しは変更しない。通信結果が不明な場合だけ、`publication_status`を確認して処理を停止する。

```ruby
begin
  file.save!(to: repaired_path, snapshots: [:metadata])
rescue TagLib::Plus::MP4::Error => error
  file.close if error.publication_status == :unknown
  raise
end
```

MListNewは既存の計画結果とこのError契約をそのまま利用し、unknownを成功や未確定前失敗として再試行しない。gem更新後にatom書換えや候補救済を追加する必要はない。

未検証: 製品へのbinding組込、Fiddle依存の隔離install、Ruby 3.2、Intel macOS、非Darwinの非対応結果、binding symbol不在、非同期割込み、handle close失敗、unknown状態の新API実装、実SMBの排他的rename/切断/残存物。実共有での応答喪失はローカル故障注入で保証できない。既存errno分類表も実共有の再送挙動まで検証したものではない。
