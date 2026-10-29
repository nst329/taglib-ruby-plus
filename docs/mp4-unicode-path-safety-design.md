# MP4ファイル経路のUnicode安全設計

日付: 2026-10-30
状態: ローカルfixture・失敗注入で検証済み。今回の実SMB試験は未実施。

## 前提と解決条件

入口は`require 'taglib_plus'`と`TagLib::Plus::MP4.open`である。NFC/NFDへ統一せず、入力・OS/APIが返したアクセス可能なパス表記を、open、保存、公開、結果、再読取り、cleanupへ引き継ぐ。正規等価な文字列でも同一実体とは判断しない。原本世代確認、公開状態、内容・章・媒体の保存検証は従来のまま維持する。

2026-10-30の監査で、以前の本書にあった「親dev/inoの公開直前照合」「正規等価basenameの列挙照合」は現コードにないと判明した。本書は現コードの保証へ訂正した。境界別根拠・試験範囲は[監査記録](Memos/2026-10-30-MP4のUnicode経路監査と検証.md)、判断理由は[今回のADR](ADR/2026-10-30-POSIXの経路bytesとcleanup不在確認を保持する.md)を参照する。[従来ADR](ADR/2026-10-21-MP4のUnicode経路は原表記と実体で確定する.md)の原表記・実体照合方針を継承する。

## 原本openとセッション

1. `Path.expand_path`で相対経路へ作業ディレクトリを結び付け、要求表記を`lstat`する。macOSの通常相対経路はPOSIX `getcwd(NULL, 0)`の返却bytesをbaseとしてRuby `File.expand_path`へ渡す。絶対経路とtildeによるhome展開は従来のRuby展開を維持する。Unicode正規化、NFC/NFD候補探索はしない。EACCES/EIO等を不存在へ変換しない。
2. 末尾が通常ファイルなら、その表記を保持する。原本pathで開いたGenerationのfdとpathのdev/ino、size、mtime、ctimeを照合する。内容SHA確認は既存の`verification:`契約による。
3. 末尾がsymlinkなら解決先を固定する。macOSでは`Path.realpath`がPOSIX `realpath(path, NULL)`の返却bytesをRubyへコピーし、割当領域を必ず`free`する。NULLならerrno付きで失敗する。macOS以外は従来のRuby `File.realpath`を使う。
4. symlink要求と返却先を`File.identical?`で照合する。返却先が別実体なら`:path_conflict`で拒否し、別候補を試さない。返却文字列の正規等価性や存在だけでは採用しない。途中消失・循環・権限失敗等は既存の`:open`／`:read`失敗とする。
5. 公開`File#path`、native open、構造reader、コピー、世代検証、計画のownershipはこの同じ経路へ結び付ける。変更時に再openや計画再発行で回避しない。

Ruby `File.realpath`と`Dir.pwd`は、本環境でNFD名をNFCへ変えて返すことを実測した。通常の`File.expand_path(relative)`にもRubyのcwd表記が入るため、POSIX realpathとgetcwdの返却bytesを保持して両境界を変更する。通常ファイルへcanonical化を追加しない。末尾が通常ファイルで親だけにsymlinkがある場合は、その親symlinkをcanonical化して固定しない。親の外部付替えを原子的に防ぐ保証はなく、必要なら利用側がwriterを調停する。

## 同一path保存・別出力保存

- `to:`省略またはアクセス用原本経路と同じ文字列は既存の原本置換要求である。無変更の同一path保存はコピー・保存・公開を行わない。限定修復の別出力必須契約も維持する。
- `save!(to:)`は絶対化後の要求表記を保持する。既存先を`lstat`し、hardlink、symlink、切れたsymlinkも`:output_exists`で拒否する。原本の別表記が同じ実体としてアクセスできても、文字列が異なる`to:`を暗黙の原本置換へ昇格させない。
- 要求親に候補を生成し、親の別表記を探索しない。親dev/inoを公開まで固定・照合する処理は現状ない。正規等価basenameを列挙して衝突とする処理もない。FSが正規等価な別entryを許す場合、それだけで同一視しない。
- `Tempfile.create`が返した`File#path`とfdのdev/inoを記録し、初回path照合を行う。後続native編集、独立検証、公開、cleanupは返却された同じ表記を使う。native編集が候補を置換する既存経路では、準備完了後の所有実体を再記録する。
- 別出力は排他的linkを優先し、非対応時だけ既存のmacOS排他的renameを使う。同一pathは通常renameで置換する。公開状態がunknownの候補は削除しない。公開後の原本世代引継ぎ・独立検証を省略しない。
- 正規等価な別名の同時作成や親の外部差替えを原子的に排除する契約はない。文字列比較だけで完全保証したとは扱わない。

## 保存結果・復旧情報・cleanup

成功結果の`output_path`、Errorの`output_path`／`temporary_path`には実際に使用した表記を渡す。native FilenameのPOSIX境界では入力bytesを直接渡し、返却bytesにはfilesystem encodingのラベルを付けるだけでUnicode正規化しない。

候補を削除する前に`lstat`のdev/inoを所有実体と照合する。別実体へ交換されていれば削除しない。unlink後も`lstat`し、**lstatのENOENTだけ**を不在と認める。unlink成功またはENOENTでもentryが残ればcleanup失敗とし、EACCES/EIOも伝播する。再削除・権限変更・sleep/retry・再接続は行わない。

native metadata型変換用の`PurlSnapshot.metadata_only`も同じ所有実体照合・削除後確認を行う。失敗時の実効経路は`MetadataSnapshotError#issues[].temporary_path`へ格納し、Plus保存経由でもissuesを保持する。内側metadata workspaceと外側候補の経路を区別する。両者ともblockなしの`Tempfile.create`が返すFileを明示管理し、cleanup失敗後のGCによる削除を避ける。Plus保存フローにbackup生成や作業ディレクトリのrmdirはない。

lstatとunlinkの間の外部置換を完全に防ぐ保証はない。専用領域で外部writerとの調停が必要になる。旧`TagLib::MP4::File#save`等の独立した互換保存経路には`rm_f`等が残るが、今回その公開契約を変更する改修は行わない。Plusの候補編集はそれらの原本置換saveを呼ばず、native writerを候補へ適用する。

## I/O予算と受入範囲

通常ファイルopenに追加走査・hash・コピーはない。相対経路ではPOSIX getcwd一回の返却値を絶対化のbaseに使い、絶対経路にはgetcwdを追加しない。symlinkのRuby realpath一回をPOSIX realpath一回へ置き換える。いずれも返却文字列の小さなコピーとfreeを行う。全階層列挙、正規等価名探索、追加再openはない。既存の候補初回lstatは維持し、fdのstat一回を所有実体の根拠として追加する。候補を実際にunlinkした後のlstat一回、metadata作業ファイルのfd stat、所有確認lstatと削除後lstatを追加する。媒体bytesの追加読取・全体hash・コピーはゼロ。性能改善の実測値はない。

ローカルAPFSでASCII/NFC/NFDの親子9通り、合成MP4の変更保存・別出力・unchanged・返却パス再open・cleanupとmetadata/章/媒体保持を確認する。候補差替え、canonical先の別実体、権限・公開・cleanupの異常は失敗注入を分けて記録する。ローカルAPFSでは正規等価名が同一実体になったため、別実体を許すFSや実SMBの保証へ一般化しない。

SMB専用領域は未指定のため今回の実SMB試験は行わない。過去のcache ONでのrmdir成功後残存や`.smbdelete`削除失敗は原因未確定の別問題であり、このUnicode修正で解消したとは扱わない。通信断、SMB cache ON/OFF、複雑なsymlink階層、Intel macOSと他OSの実機受入も未実施である。
