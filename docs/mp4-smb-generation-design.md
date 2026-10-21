# SMB上の原本世代検証とctime反映遅延

日付: 2026-10-21
状態: 製品実装・設計probe検証済み。全体点検による追加変更は開発中。

## Unicode経路に関する設計の追補

NFD原表記を保持できた実機確認に加え、通常ファイルの原表記優先、symlinkの実体確認、出力lstat、候補dev/ino照合を実装した。realpath先が実在する別実体の場合や、正規等価な別名を作れるFS・通信断は未受入である。詳細は[Unicode経路安全設計](../Docs/mp4-unicode-path-safety-design.md)と[ADR](../Docs/ADR/2026-10-21-MP4のUnicode経路は原表記と実体で確定する.md)を参照する。原表記の優先、実体確認、探索と編集の責務分離を維持し、taglib内で別表記の候補探索は行わない。

## 対象と確認範囲

報告対象はtaglib-ruby-plus 2.3.2.37のMListNew字幕併用修復経路。実装は2.3.2.38へ追加した。
ユーザー指定の`/Volumes/WD60EZAZ-00SF3B0`は`smbfs`であり、問題のMP4はNFDのファイル名で存在することを実機確認した。fd/pathのdev/ino/size/mtime/ctimeは5回連続で一致した。一方、Rubyの`File.realpath`はNFCへ正規化した存在しない経路を返すため、従来実装では`source_changed`以前に`open/read`の`ENOENT`になることを再現した。共有原本への書込みは行っていない。

## 現行実装の失敗箇所

Generationはdev/ino/size/mtime/ctimeの配列を開いたfdのstatから取得する。`verification: :sha256`でopen時に基準SHAを確立した世代だけ、dev/ino/size/mtimeが基準と一致しctimeだけが異なる場合にfd/pathのSHA256を比較して継続する。stat既定は基準SHAがないため従来どおり停止する。内容が一致しない、または別属性が変わった場合は`source_changed`で停止し、issuesへexpected/handle/pathのstat差分を残す。

stat既定では基準SHAがないため、check_stat!はctime差も拒否する。`verification: :sha256`では基準SHAとfd/pathの内容が一致し、照合後のdev/ino/size/mtimeも一致すればctime差を許容する。read_checked内の世代競合はarea/issues/causeを保持してread phaseへ変換する。save!は内部begin内のErrorを保存中のphaseで包み直すため、検証中の原本世代差はverifyになる。一方、save!入口のensure_current!はbeginより前なのでprepareのままになる。

`File`の初期経路は通常ファイルの`expand_path`を原表記として保持する。symlinkだけは`realpath`後に`File.identical?`で同じ実体であることを確認して解決する。これにより、SMBでrealpathが返すNFC経路へ通常ファイルを黙って置き換えず、元のNFD経路をそのままfd/path検証へ渡す。

なお、MListNewの既存`TagLib::Plus::MP4.open(input)`は既定の`:stat`を使うため、ctime-onlyの許容を有効にするには呼出側で`verification: :sha256`を明示する統合作業が残る。今回のtaglib変更だけでstat既定のctime誤検知を自動許容するものではない。

## テストによる設計検証

`test/probes/mp4_smb_generation_design.rb`をRuby 4.0.7とローカルnative bindingで実行した。8 tests / 39 assertions / 0 failures / 0 errors / 0 omissions。既存MP4をローカル一時領域へコピーし、不正mdta indexを独立fixture editorで追加した。`test/plus_mp4_io_test.rb`にはctime-onlyの許容と内容変更拒否の回帰assertを追加した。

- 旧check_stat!: fdだけ、pathだけ、両側で異なるctimeを模擬し、内容SHAが不変でもsource_changedとなることを確認。
- 旧sha256モード: ctime差でSHA照合より先に拒否することを確認。
- 製品Generation: ctimeだけの差とfd/path同一内容は継続し、内容差はsource_changedとなることを回帰検証した。
- phase: read_checked途中の世代差は開発中変更でread/area=:sourceとし、保存後段の世代差はverify/committed=falseとして、最終出力を公開しないことを検証する。
- テスト専用のctime許容probe: open時点からsha256モードで基準SHAを取得済みとし、fd/pathのdev/ino/size/mtime固定と双方のSHA一致を確認した場合だけctime差を許容。plan tokenを変更せず、同じFileのplan→apply→別path save→独立reopenでunchangedを確認。原本bytesも不変。
- 同サイズ内容変更とmtime復元、inode差し替え、size変更、mtime差を拒否。plan後の内容変更はapply前・save前のどちらでもsource_changedとなり、出力を作らない。

path正規化のfallbackは入力経路の保持だけを行う。旧APIへのfallback、plan再発行や自動再適用はしない。

開発中の`test/plus_mp4_generation_test.rb`ではprobe moduleを適用せず、製品Generationそのものを検証する。fd/path別々のctime遅延、内容・inode・size・mtime変更、SHA走査中のmtime変更、plan後のapply/save拒否、結合文字名での別path保存・独立再open・cleanup、検証後の候補差し替え保持を通常CIへ含める。

## 採用する実装方針

### 内容の基準を先に確立する

ctime差を検出した後に初めてSHAを取得し、それを正しい基準として採用してはならない。同じinode/size/mtimeに見えても、plan後に内容だけが変わった可能性を排除できないためである。保存copy時に初めて得られるSHAも、plan発行時点の原本を証明しない。

ctime差のSHA照合は、`verification: :sha256`で基準SHAを取得済みの世代に限り差分発生時だけ実施する。正常なstatモードで全体hashを追加せず、dev/ino/size/mtime差を先に拒否する。SMBの自動判定や共有名のハードコードは行わない。MListNewがSMB修復を許容する場合は、このverificationを明示的に選択する必要がある。

ユーザーが全SMB経路で自動許容を必要とする場合は、filesystem検出とopen前の基準SHA取得を別途設計する必要がある。初回ctime差の後付けhashで代替しない。

### 許容する差と再確認

dev/ino/sizeの差・path実体差し替えは直ちに拒否する。mtime差も初期実装では拒否し、今回許容する差をctimeだけに限定する。mtimeも許容する場合は事前SHA照合を必須とする別変更として扱う。

ctime差の際は、fdとpath双方のSHAが事前基準に一致し、hash前後もdev/ino/size/mtimeが基準に一致する場合だけ継続する。pathは開いたhandle自身のfstatも検証し、検証中の置換をチェックする。ctimeの収束待ち・sleep・自動リトライは行わない。継続中もSHA照合を省略せず、古い内容を同一と推定するfallbackを作らない。

初期化中のctime差は基準未確立のため許容しない。`verification: :sha256`で初期基準を確立した後のcheckでctimeだけが揺れた場合に、同じfdと元経路のSHA一致を確認して継続する。

### 世代とplanの寿命

基準のplan tokenはctime補正で差し替えない。ctime-onlyの許容後も元のtokenを維持する。SHA不一致・実体変更・検証I/O失敗はstaleを確定し、同じセッションを再利用しない。最新plan限定・同一File ownershipは維持し、既存planの再発行や旧APIへの再試行を修復経路へ追加しない。

### 公開後検証との共通化

次の責務をGeneration内の小さいhelperへ揃える。

- 名前付きstat観測と差分生成。
- dev/ino/size/mtimeが変わらずctimeだけが異なることの判定。
- 事前SHAを受け取るfd/path内容照合と、その前後の実体検証。

publish_toは候補SHA、原本check!はopen時に確立した原本SHAを渡す。共通helperが新しいSHAを正しい基準として採用してはならない。公開先pathの採用と原本tokenの保持は用途ごとに残す。既存committed/publication_status/cleanup契約を維持する。

### Error診断とMListNew連携

Errorのcode=source_changedとmessage=source changedを維持し、area=:source、phase=:prepareを設定する。Generationの比較失敗はissue.detailsへexpected/handle/pathを記録する。保存中は既存write/publish/adoptなどのphase契約を維持し、すべてをverifyへ丸めない。

実装済みissuesは既存code/message/location/details schemaで返す。locationはsource/generation、detailsはexpected/handle/pathの各stat配列で、要素順はdev/ino/size/mtime/ctime。時刻は既存tokenと同じRationalである。内容SHA不一致またはstat取得不能ではstat差分issueを持たない場合がある。named field、changed_fields、digest照合結果、整数時刻によるJSON向け診断拡充は未実装であり、実装済みと扱わない。

MListNew側のログ改善は製品修正と別の統合作業とする。code/area/phase、committed/publication_status、issuesとcauseの属性を保持し、messageだけで再判定しない。本文や字幕payloadをログへ出さない。今回はMListNewを変更していない。

## I/Oとトレードオフ

正常statモードは従来どおりstatのみ。sha256モードは元から原本全体N bytesをopen時およびcheck!時にhashする。ctime差の内容検証はfdとpathで各N bytesと前後statを追加するため、毎回ctimeが揺れる巨大SMB入力では高コストとなる。製品も安全性優先で既存strict checkとのhash重複を残しており、同じcheck!内のdigest再利用は未実装である。path同一性確認だけでpath hashを省略する最適化も今回証明していない。

mediaはhashの逐次走査では読むが、全体コピー・メモリ蓄積は増やさない。既存のコピーや出力scanで得たSHAを共有できる場合も、plan前基準と比較し、同じstage内の検証結果だけを再利用する。実SMBのI/O回数・bytes・時間は未計測。

## 製品化前に残る試験

実SMB上の対象MP4とコピーのfd/path stat差を計測し、ctimeだけが原因か確定する。原本は変更しない。共有へ検証コピーを書き出す場合は専用作業場所を決め、sandboxの書込承認を通す。
open時のctime差、hash中の変更、path交換、hash失敗、mtime差、plan ownership、継続的ctime差、公開後の遅延も同じhelperで検証する。実MP4ではopen前のNFD経路保持と限定修復計画の成功まで確認したが、実SMBでctimeが揺れる瞬間の再現、Linux/Windows/Intel、SMBサーバー側cacheや通知の影響は未検証。
