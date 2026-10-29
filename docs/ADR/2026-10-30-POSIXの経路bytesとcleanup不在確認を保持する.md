# POSIXの経路bytesとcleanup不在確認を保持する

日付: 2026-10-30
状態: 採用。実SMBの受入は未実施。

## 背景と確認した原因

通常ファイルの原表記、POSIX native Filename、Tempfileの返却path、rename/linkの引数には正規化がない。一方、末尾symlinkの解決で使っていたRuby `File.realpath`は、本環境のNFD名をNFC表記へ変えて返した。アクセス可能な表記を保持する要件をこの境界で満たしていなかった。APFSでは別表記でも同じ実体へアクセスできたため、今回のローカル試験でSMBのENOENTを再現したとは扱わない。

追加の相対経路試験では、Ruby `Dir.pwd`と`File.expand_path(relative)`にもcwdのNFC表記が入ることを確認した。POSIX getcwdの返却はNFD bytesを保持したため、相対入力・相対出力の絶対化も修正対象とする。

外側候補のcleanupはunlink成功だけで完了とし、unlinkのENOENTも包括rescueで不在扱いしていた。metadata用の小さなTempfileは標準のblock cleanupに任せ、所有実体と削除後の不在を確認していなかった。これらはSMB cache ONの削除不整合の原因確定とは別の、libraryで検出すべき不足である。

## 決定と理由

- macOSの末尾symlink解決だけPOSIX realpathの返却bytesへ置き換える。割当文字列をコピーしてfreeし、失敗はerrnoとともに伝える。通常ファイルへcanonical化を追加せず、macOS以外は既存経路を維持する。
- macOSの通常相対経路はPOSIX getcwdの返却bytesを絶対化のbaseへ渡す。絶対入力・絶対出力、tilde展開へ追加のcwd取得を行わない。File API全体の変更はせず、Plusの入口と出力指定の二箇所だけ変更する。
- 既存の`File.identical?`、Generation、独立保存検証、公開状態管理を維持する。正規等価名の同一視、別表記の順次試行、探索、cache、monkey patchを追加しない。
- Tempfile返却pathの初回照合はpath自身から得たidentityではなく作成fdのdev/inoを基準にする。差替えられた候補を所有物として採用・削除しないためである。
- 候補とmetadata作業ファイルのcleanupは、所有dev/inoを照合して一度だけunlinkし、lstatのENOENTだけを不在と認める。残存、EACCES、EIOは失敗として経路を返し、再削除しない。内側metadata経路はissuesに保持し、外側候補経路と区別する。
- 既存仕様に書かれていた未実装の親固定・正規等価名列挙を、実装済みの保証から外して訂正する。今回新たな親固定や衝突ポリシーを導入することは、確認したUnicode変換境界の最小修正に含めない。

## 選択肢

NFC/NFDへの統一は既存entryの表記を失うため採らない。Ruby realpath返却先が失敗したら別候補を探す方式も、別実体の採用とI/O増加につながるため採らない。symlinkを解決せず入力pathへrenameするだけではリンク自体を置換するので採らない。削除後の残存を再削除で隠す方式は原因を分離できず、利用者が許可していないため採らない。

## I/O・CPU・メモリ

- 通常openに全体走査は追加しない。相対経路の絶対化では明示的なPOSIX getcwd一回を使い、絶対base付きのRuby展開へ渡す。絶対経路にはgetcwdを追加しない。末尾symlinkのrealpath一回をPOSIX呼出一回へ置き換え、名前bytesのコピーとfreeを行う。Fiddle関数生成の小さなCPUコストはあるが、永続cacheを追加しない。
- 外側候補は作成fdのstat一回を追加し、既存の初回lstatと照合する。実際のunlink後にlstat一回を追加する。原本へのrename後に候補が既にない場合は既存のlstatで終了する。
- metadata作業ファイルはfd stat一回、削除前lstat一回、unlink後lstat一回を追加する。payload読取・全体hash・全体コピー・再open・全階層列挙は増えない。
- I/O削減より正しさと所有物の保護を優先すべき、必要最小限の属性確認である。性能効果・SMB遅延は未計測。

## 検証と制約

[監査・検証記録](../Memos/2026-10-30-MP4のUnicode経路監査と検証.md)を参照。ASCII/NFC/NFDの親子9通りを公開APIで通し、異常応答と差替えは失敗注入で補完した。ローカルFSではNFC/NFDが同一実体となり、正規等価な別実体の実FS受入は未完了。SMB専用領域未指定のため実SMB、cache ON/OFF、`.smbdelete`、rmdir残存は未検証。旧互換保存経路全体のcleanup変更は本ADRの範囲外である。
