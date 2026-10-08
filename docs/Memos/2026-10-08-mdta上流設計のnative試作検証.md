# mdta上流設計のnative試作検証

日付: 2026-10-08

本記録は先行試作の履歴。現在の実装と再現手順は[隔離実装の検証](2026-10-08-mdta上流向け隔離実装の検証.md)を参照する。

## 前提と結果

上流への取り込みを想定した設計を検証する。本体への適用、投稿、システムへのインストールは行わない。TagLib 2.3.2原始ソースを一時コピーへ展開し、公開API案と保存後tree更新を試作した。原本動画は使わず、FFmpegで動画・音声・字幕付きMP4を合成し、各ケースのコピーを使用した。

12テストのnative 33ケース・328アサーションと、追加3テストのnative 3ケース・13アサーションが成功した。合計15テスト、36ケース・341アサーション。追加範囲のみを再実行し、成功済み範囲は不要に繰り返していない。

## 確認内容

- 複数値、同じ/異なるlocale、重複、異なる型、未知32-bit型、NUL、空バイナリを完全比較。
- 新規キー追加、既存index維持、値なしキー、空keys、削除による再採番、strip後に値が復活しないこと。
- 同じFile/Tag/ItemMapを維持する連続3回保存、独立再読込、変更キーが一つのnumeric親に複数data子を持つこと。
- 通常title/freeform、JPEG画像、Nero/QuickTimeチャプター、動画・音声・字幕のtrack情報と元packetのhash/時刻の維持。
- 繰り返すnumeric親から読み取り、通常タグだけ変更した際の未編集mdta raw一致。
- mdir-onlyではmdta編集を拒否し通常タグ保存は可能。混在ilstは編集可能。複数meta/udta、別scope、断片化、64-bit/non-FullBox、未知namespace、壊れたkeys/handler/index等は明示拒否。
- 不正入力で編集状態不変、非対応構造・読取専用・無効Fileでディスク不変。overflowは実際に4GBを確保せず共有長さ計算の境界で確認。
- 公開Pimpl値型のコピー・代入・swap、返却snapshotとバイナリの独立性。

## 原因を確認して修正した試作箇所

既存native APIの反例は `test/mp4_mdta_native_lifetime_test.cpp`。既存値を拡大して保存し、同じFileで新規キーを追加すると2回目の保存後にInvalid atom sizeを再現した。保存済みatomの長さ/offsetがキャッシュに残ることが原因。試作はmetadataとchapter保存後に共有treeを再構築する。現行配布コードにはこの変更を適用していない。Ruby側の保存時再読込とnativeの同一File寿命は別の検証対象。

handler欠落をAbsentと判定する問題はkeysの存在も調べて修正した。ItemFactoryは未知fourCCも文字列として受理するため、通常item分類には既知登録を確認する。変更キーは一つのnumeric親に順序付きdata子として出力する。

NUL入力のテストではString(ByteVector)がAPI到達前にNULで切れるため、String(std::string(...), UTF8)を使用した。ファイル内のキーはString変換前のraw bytesを検証する。字幕はchapter追加でstream indexが変わるためtrack IDで比較した。

## 未達と既知制約

書き込みを全て破棄するカスタムIOStreamではsaveがtrueになる反例を確認した。この1ケースの成功は制約の再現であり、保存成功の証明ではない。既存IOStreamにエラー照会契約がないため、別のABI設計が必要。

ABI互換性、途中write/insert/truncateとflush/close失敗、全親atom/ファイル長の事前overflow計画、co64変換は未検証または未実装。試作ではmetadata保存時にもsnapshotを再読込するため、後段chapterを含む全File保存成功後だけ状態確定する設計は未完成。全未知atomの位置・順序保持やItemMapの全直接操作も網羅済みとは扱わない。

## 再現手順

Python 3.12以上、git、cmake、C++17コンパイラ、FFmpeg/FFprobeが必要。builderはbase-sourceのHEADから原始ソースを展開し、mp4tag.cppのSHA-256を検証する。作業ディレクトリは新しい一時パスを指定する。基準はTagLib 2.3.2、commit deadc2990767dfbda0701e0ab35fdeea653db08f相当の原始ソース。IOStreamへのvirtual追加は適用しない。

```sh
python3 test/support/build_mp4_mdta_upstream_probe.py \
  --base-source /private/tmp/taglib-2.3.2 \
  --workdir /private/tmp/mdta-upstream-check-new
clang++ -std=c++17 -Wall -Wextra \
  -I/private/tmp/mdta-upstream-check-new/install/include \
  test/mp4_mdta_upstream_probe.cpp \
  -L/private/tmp/mdta-upstream-check-new/install/lib -ltag \
  -Wl,-rpath,/private/tmp/mdta-upstream-check-new/install/lib \
  -o /private/tmp/mdta-upstream-check-new/mdta-upstream-probe
MDTA_UPSTREAM_PROBE=/private/tmp/mdta-upstream-check-new/mdta-upstream-probe \
  python3 test/mp4_mdta_upstream_probe_test.py
```

先行試作builderの `--without-refresh` はtree更新を外す反例用だった。現在のbuilderは単独パッチを適用するため、このオプションは提供しない。既存native反例C++はローカル既存パッチ版TagLibへリンクして別途実行する手動テストであり、自動テストには登録しない。

今回のログ: `/private/tmp/mdta-upstream-probe-verified-test.log` と `/private/tmp/mdta-upstream-probe-additional-test.log`。一時ログは永続成果物ではないため、本記録に結果と再現手順を残した。
