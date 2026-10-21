# MP4ファイル経路のUnicode安全設計

日付: 2026-10-21
状態: 実装済み。正規等価な別実体を持つFSでの受入は継続中。

## 前提と解決条件

パス文字列をNFC/NFDへ統一せず、入力・列挙・OS/APIが返したアクセス可能な表記を保持する。正規等価性は照合の補助であり、ファイルの同一性、削除権限、上書き権限の根拠にしない。実在する原本を別ファイルと取り違えず、アクセス失敗を不存在と見なして削除しないことを解決条件とする。

MListNewの`Docs/Modules/unicode_safety.md`、`MovieVideoScanner`、音声抽出のSwift/Ruby実効パス契約を確認した。scannerの補完は探索の責務であり、編集libraryへ同じ探索を自動追加する必要はない。taglibのopenでは原表記が使えなければ明示的に失敗する方針を基本とする。MListNewのファイルは今回変更しない。

## 現在の実装評価

`File#stable_path`は通常ファイルの原表記を優先し、symlinkだけは解決先の実体を確認してcanonical化する実装へ変更済みである。`save!`の出力検査は`lstat`、一時候補のcleanupは作成時のdev/ino照合を使う。残る不足は、正規等価な別名を別実体として扱うFS、通信断、複雑なsymlink階層を実機で受入できていないことである。

前の実機確認ではNFD原表記へのアクセス成功、realpathが返したNFC経路へのアクセス失敗を観測した。これは当該環境の観測であり、Unicode正規化の実行主体やSMB/OS内部の原因を確定するものではない。ctime揺れの原因確定とも区別する。

## 原本openとセッション

1. 入力経路を元の表記でlstatする。相対入力には作業ディレクトリを結び付けるが、Unicode変換を行わない。EACCES、EIO、ESTALE等はそのまま失敗させ、ENOENTでもtaglib内でNFC/NFD候補を探索しない。
2. 通常ファイルは元経路で開き、開いたfdのdev/inoを直前のpath statと照合する。世代基準は取得したfdへ結び付ける。別実体ならsource_changedで停止する。
3. realpathの返却文字列だけでアクセス用経路を置き換えない。canonical経路を使う必要がある場合は、元経路と同じ実体であることをFile.identical?またはfd/pathのdev/inoで確かめる。存在する別実体は衝突として停止する。
4. 以後のnative open、構造reader、コピー、原本検証には同じアクセス用経路を渡す。別APIが返した表示用・比較用経路を再投入しない。キャッシュ参照時にも既存のGeneration検証を実施する。
5. generationとplan ownershipは元のセッションへ固定する。ENOENTや別実体を契機に候補探索、再open、plan再発行、旧API再試行をしない。

symlinkは既存の「open時のリンク先を固定する」契約を維持する。単純に入力経路を保存してrenameするとリンク自体を置換してしまうため、それだけの変更は採用しない。実装は入力を`lstat`し、`realpath`後に`File.identical?`で要求経路と同じ実体であることを確認する。解決中の途中消失、循環、境界不明は`open/read`失敗とし、安全なtarget経路を確定できないケースを成功扱いしない。公開File#pathもこの検証済みアクセス経路を返し、NFC表記であることを保証しない。複雑なsymlink階層を正規化別名FSで受入する試験は未完了である。

## 別path保存と原本置換

- `save!`のto省略は、検証済み原本entryへの既存の置換要求とする。限定修復が別path保存を要求する契約は維持する。
- `save!(to:)`は要求表記を保持し、既存先をlstatする。別表記でも原本と同じdev/inoなら、暗黙の原本置換へ昇格させずoutput_existsで拒否する。hardlink・symlink・dangling symlinkも既存出力として拒否する。
- 親ディレクトリは元経路で実在・実体確認し、公開までdev/inoを保持する。親のNFC/NFD別表記へ黙って移動しない。不存在や権限失敗を別親の探索で隠さない。
- 別出力のbasenameと正規等価な既存entryがある場合は、同じ実体なら既存出力、別実体なら衝突として停止する。比較には親の列挙名を使い、Unicode変換した名前へ書き込まない。要求先そのもののlstatも別途維持する。
- 出力未存在は公開権限を保証しない。既存の排他的link/renameを最終の非上書き保証として維持し、チェック後にできた出力を削除しない。
- 正規等価な別名の同時作成まで原子的に排除するOS共通APIはない。この競合まで防ぐ必要がある利用側は、親ディレクトリ単位の外部writerとの調停が必要である。文字列比較だけで完全保証したとは扱わない。

## 候補とcleanup

Tempfile等の作成APIから得た実効経路と候補fdのdev/inoを保存する。保存結果、Errorのoutput_path/temporary_pathにも実際に使用した表記を渡す。候補のunlink前にlstatで所有候補かを確認し、別実体なら削除せずcleanupエラーとして残す。ENOENTだけを削除済みとして扱い、EACCES/EIOは警告または既存Error契約で伝える。

publication_statusがunknownの経路は既存どおり保持する。NFC/NFDが一致することを理由に原本・出力・候補を削除しない。lstatとunlinkの間の外部置換を完全に防ぐ保証はなく、専用候補領域と所有権確認の範囲を明記する。

## 診断とctime検証の分離

open失敗は既存code=:open、phase=:read、セッション開始後の実体変更はsource_changedとする。Unicode衝突はopenまたは出力検証の失敗として返し、issuesの既存code/message/location/details形式へ入力表記、返却表記、失敗操作、errno、実体情報を載せる。既存messageや公開APIのHash構造を一律変更しない。

ctime-only許容は別の世代検証判断である。NFC/NFD比較、fdとpathの現在SHA一致だけではplan時点の原本を証明しない。事前基準SHA、非ctime属性、hash前後の実体検証が必要であり、この文書のパス解決を理由にGeneration検証を緩和しない。

## I/O予算

通常ファイルopenはlstat・fd/path statのメタデータI/Oだけを使用し、追加の全体読込・hash・コピー・ディレクトリ走査は行わない。symlinkは解決する構成要素数に応じたlstat/readlinkが必要になる。得られた初期観測はGeneration初期化へ渡し、同一stageの重複statを避ける。

別出力の正規等価衝突確認は準備時に親ディレクトリを一回列挙し、比較対象だけlstatする。大きい親ではentry数に比例したメタデータI/Oが増えるため、原本openや各readには組み込まない。不在結果をセッション全体へcacheせず、最終公開は既存の排他的操作で保護する。media payloadの追加読込はゼロを目標とし、効果は未計測である。

## 実装時の受入試験

| 条件 | 期待結果 |
| --- | --- |
| NFD原表記が存在、realpathのNFC先が不存在 | 原表記の同じfdを使用できる |
| 原表記が存在、NFC/NFD別名が別inode | 原表記を優先し、別実体を採用・変更・削除しない |
| canonical化が必要な場面でrealpath先が別inode | 衝突で停止する |
| 原表記がENOENT、別表記だけ存在 | taglibはopen失敗。探索側が実効経路を渡す |
| 原表記または親のEACCES/EIO | 不存在と扱わず、原因を保持して失敗する |
| symlinkと親symlink、相対target、target内の`..` | open時の同じtargetを固定する。曖昧なら失敗する |
| 原本aliasをtoに指定 | 原本を置換せずoutput_exists |
| 正規等価な既存出力が別実体 | 公開せず両方を保持する |
| plan後のinode置換・size/内容変更 | apply/saveを拒否する |
| 検証後の出力作成・親置換 | 排他的公開または世代検証で失敗し既存出力を保持する |
| cleanup前に候補を別inodeへ交換 | 別実体を削除せず残存pathを報告する |
| native/APIが要求と異なる表記を返す | 実体を確認し返却された実効表記をアクセスに使う |

単体試験は正規等価名を区別するFSを模擬して必須化し、ローカル一時fixtureの公開API試験と分ける。Unicodeを同一視するAPFSだけの成功で別実体ケースを保証しない。実SMBは指定原本への読取と、許可された専用領域の合成fixtureに限定する。OS/Ruby/backendを記録し、未再現の衝突・通信断・別OSを検証済みと扱わない。

判断理由は[ADR](ADR/2026-10-21-MP4のUnicode経路は原表記と実体で確定する.md)を参照する。
