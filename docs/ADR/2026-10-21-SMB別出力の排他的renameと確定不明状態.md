# ADR: SMB別出力へ排他的renameを追加し確定不明を表現する

日付: 2026-10-21
状態: 採用・実装済み（実SMB試験は未実施）

## 背景

別出力のFile.linkがSMBで非対応になる。候補生成と保持検証が済んでいても確定できない。原本保持・出力競合防止と既存検証を維持し、追加全面コピーを避ける必要がある。

## 決定案と理由

- File.linkを優先し、EOPNOTSUPP/ENOTSUPだけでmacOS renamex_np(RENAME_EXCL)へ進む。link対応環境の挙動を維持し、不要なOS依存を増やさないため。
- 既に検証した同じ候補を一回だけrenameする。編集・コピー・hash・独立検証を再実行せず、追加本文I/Oをなくすため。
- 排他的renameが非対応なら明示的に拒否する。通常renameは競合上書きを防げず、O_EXCL後のコピーは全面I/Oと部分出力の公開を伴うため使わない。
- 初期fallbackをmacOSに限定し、他OSは従来のlinkを維持する。source gemのLinux CIや旧Windows記載を踏まえ、ライブラリ全体をDarwin専用にしない。SMB対応はOS関数の有無だけでは宣言しない。
- 小さい内部helperと明示Fiddle実行時依存を使う。既存native拡張とSWIGへentrypointを追加する案より、TagLib ABI・生成コードへの影響を抑えられるため。依存の隔離installとbindingの検証は必須とする。
- Errorにpublication_statusを追加し、確定不明ではcommitted=nilとする。通信失敗後のfalseは未確定を誤って断定するため。boolean拡張の互換性変更とMListNewの失敗処理変更を明示する。
- unknown時は候補を自動削除せず、自動再試行・推測による確定を行わない。既存outputを他writerの出力と区別できない可能性があるため。再利用拒否でもunknownをtrueへ変換しない。
- cleanup失敗でも元保存失敗をcause chainに維持し、cleanup自身の原因をissuesに保持する。temporary_pathは履歴値であり、残存保証として扱わない。

## リファクタリング判断

- `Publication::State` の公開状態と公開方式を `publication_method` / `mark_method!` に分離した。Rubyの`Object#method`と同名の状態取得を避け、診断値の意味を明確にするため。
- `save!` の公開失敗診断とセッション無効化を小さな内部メソッドへ分け、原本候補の生成・検証・公開順序を変えずに責務を局所化した。
- 原本置換と別出力公開を専用メソッドへ分離した。fallback時の候補再生成・再検証・追加コピーは行わず、既存のI/O回数を維持する。
- `State` は製品内部の保存一回に限定して使い、公開APIの`Error`には従来の`committed`と追加の`publication_status`だけを返す。別アプリから内部stateへ依存させない。

## I/O・複雑さの評価

通常の別出力確定はlink 1回。fallbackは失敗link 1回と排他的rename 1回。候補生成・修復・コピー・独立検証の全面処理は追加0回とする。状態オブジェクトと短い診断、Fiddle bindingの管理が増えるが、ネットワーク再照合・再コピー・ボリューム能力キャッシュは作らない。サーバー内部I/Oと性能効果は未計測。

**実装でもI/Oが少なくなる方針を優先する。** 原本と競合先の安全性を満たしたうえで、確定helper内だけを切り替え、save!の再実行を避ける。既取得digest/snapshot/世代handleを再利用し、追加全面コピー、再hash・再検証、事前の共有能力probeを行わない。安全性に必要な保存前検証は継続する。

## 互換性と未確認条件

成功時の公開API・結果値は維持する。MListNewの正常処理はgem更新で接続できるが、失敗処理にはunknownで停止する変更が必要。既存先・原本を削除しない。原本置換の方式は維持し、共通例外状態の曖昧さだけ同じ規則で表現する。

製品helperとError状態を実装した。ローカルの合成fixtureと実renameは次節の範囲で確認済み。各配布CPU/Ruby、依存の隔離install、実SMBは未検証。テスト共有・切断試験の許可がないため実SMBを操作しない。公開はvタグ等で自動実行され得るため、リリース操作は別途範囲確認する。

## テストによる設計の更新

- Ruby 4.0.7 / arm64-darwin27 / Fiddle 1.1.8で、実renamex_np(RENAME_EXCL)の成功とEEXISTを確認した。既存symlinkとその参照先も保持された。Fiddle方式を初期案として維持するが、他環境の対応を推定しない。
- テスト専用の確定probeを現行保存処理へ差し込み、ENOTSUP/EOPNOTSUPPの両方で同じ候補dev/ino/sizeを持つ出力を確認した。Nero/chpl・metadata/artwork・非対象track・packet内容と時刻を保持した。
- link/fallbackともprepare_candidate、repair write_copy、verify_candidateが各1回、Stream.scanが2回だった。名前操作以外の全面処理を増やさない実装条件を確定した。OS/サーバー全体のI/O削減率は未計測。
- 実装前のタイムアウト故障注入では、出力ありにもかかわらず現行APIがcommitted=falseを返し、セッション再利用を許した。rename前の同じエラーでは候補を削除した。実装ではunknownをbindingの例外だけに付けず、save!・cleanup・再利用拒否の共通状態として管理した。
- rename成功後にcleanupを故障注入するとtemporary_pathは記録されても実在しなかった。path履歴と残存保証を分ける方針を維持する。元保存失敗+cleanup失敗のcause chainは利用し、cleanup自体の型・errnoをissuesへ補う。
- 新規13 tests / 236 assertions、失敗・エラー・省略0。実装helperを通したlink成功、fallback、競合、cleanup、unknown、I/O回数を確認した。chapter関連72 tests / 869 assertions、既存設計probe21 tests / 151 assertionsも成功した。`shoulda-context`不足のため`plus_mp4_io_test.rb`は未実行。実SMB、非Darwin、Ruby 3.2/Intel、symbol不在、非同期割込み、handle close失敗は未検証である。

[詳細設計・検証計画・MListNew使用例](../mp4-separate-output-publication-design.md)
