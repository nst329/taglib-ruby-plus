# sample境界APIの検証（2026-10-19）

## 条件

Ruby 4.0.7 / arm64-darwin27。checkoutのRuby実装と、既にインストール済みの2.3.2.25 native bindingを使用した。今回nativeコードの変更・公開は行っていない。`bundle exec rake compile`と`SKIP_SWIG=true bundle exec rake compile`は、既存のext生成物警告後に`tmp/arm64-darwin27/taglib_base/4.0.7/taglib_base.bundle`のリンク段階で`taglib_base_wrap.o`が見つからず失敗した。既存extや未追跡dSYMを削除して再生成する操作は行っていない。ローカルextのbundleは依存する`/usr/local/lib/libtag.2.dylib`が不在のため使えず、/private/tmpの2.3.2.26 artifactを明示ロードする試みも終了137となったため、それらを成功証拠には使用していない。

変更前にAGENTS.md、現行header・chapter sample・構造診断・I/O仕様、関連ADR、MListNewのcombined mux主資料と2つの試作を確認した。既存の未追跡.tmp、chapter ADR、dSYMは保持した。

## 実行

```sh
bundle exec ruby -Ilib \
  -I/opt/homebrew/lib/ruby/gems/4.0.0/gems/taglib-ruby-plus-arm64-darwin-2.3.2.25/lib \
  test/plus_mp4_sample_boundaries_test.rb

bundle exec ruby -Ilib \
  -I/opt/homebrew/lib/ruby/gems/4.0.0/gems/taglib-ruby-plus-arm64-darwin-2.3.2.25/lib \
  -e 'Dir["test/plus_mp4*_test.rb"].sort.reject { |p| p.end_with?("plus_mp4_structure_test.rb") }.each { |p| require_relative p }'
```

新規・更新19 tests / 280 assertions、既存構造診断ファイルを除くPlus回帰81 tests / 888 assertionsが成功（failure/error/omission 0）。

Rakeの`test:plus_mp4`はローカルnative extensionがload pathにないため`taglib_base`のLoadErrorで起動前に停止した。上記の明示installed bindingによるコマンドをRuby実装の成功証拠とした。

全Plus回帰では、変更していない`plus_mp4_structure_test.rb`の2件が失敗する。`assert_equal ..., range.map do ... end`のblockがmapへ結び付かず、実際値がEnumeratorになるためである。HEADのlibと当該テストをgit archiveで/private/tmpへ独立展開して同じ環境で実行し、同じ2失敗（10 tests / 108775 assertions）を再現した。無関係のテストは変更していない。

## 独立fixtureで確認したこと

- 7 samples、chunk offset 8/20/40、size 3/5/2/4/6/1/3を独立生成。firstはoffset=8,size=3,DTS=PTS=0,duration=100、lastはoffset=47,size=3,DTS=PTS=540,duration=80、decode_end=620。
- stts/stsc複数行、固定stsz、可変stsz、stz2 4/8/16bit、stco/co64。物理順が逆のchunkも非重複なら受理。
- elst v0/v1、media_time=100と10 movie ticksのeditで、priming/末尾切詰めの宣言とraw時刻が別であること。
- size/timing/chunk対応件数、短いtable、正duration、mdhdとsttsの不一致、decode/CTTS時刻overflow、mdat外、file外、chunk重複、stsc開始/昇順/範囲/description不正。
- CTTSなし/全0/nonzero、sample group、暗号化、未知table/entry拡張、fragment、複数edit、外部data reference、複数descriptionと途中変更、未知entryの拒否。
- AAC rollの限定形式（sgpd v1 roll/default_length 2/entry 1/-1、sbgp v0 roll/全sample→index 1）をcompleteとして確認。distance違い、default_length違い、partial／複数run／index 0、片側／重複、description範囲外、payload切断・長さ不一致・全sample数超過をそれぞれunsupportedまたはmalformedへ分類した。sample_groupsは再帰的にfreezeし、group payloadをtable bytes、description/runをentry数へ加算した。
- aggregate bytes/entriesのぴったり境界と1不足、atom深さ上限。unsupported boxがあっても既知table破損は例外。
- 公開API接続、native禁止、不変返却値、close後の利用、原本bytes/mtime/size不変。I/O失敗の同一cause、読取中書換え、path置換のsource_changed伝播。

## I/O実測

独立File#read observerで要求offset・lengthを記録し、API countsとの一致を検証。媒体payload範囲へのreadは0。通常statモードの初回呼出しで測定した。

| fixture | read要求回数 | 要求bytes | table bytes | 備考 |
| --- | ---: | ---: | ---: | --- |
| 128 bytes mdat、7可変samples（roll group） | 44 | 445 | 218 | mdat本文へのread 0 |
| 64 MiB sparse mdat、同じtables | 36 | 375 | 180 | groupなし比較。mediaサイズ増加でも同量 |
| 100,000,000固定samples、約100MB sparse mdat | 35 | 319 | 124 | 6 entries、last index=99,999,999 |

table prefixと残りを分けて一度ずつ読み、headerの重複readを避けた。table_bytesはdref/stsd等を含むpayload合計。bytes_readにはatom header、mdhd等も含む。既存atom indexをinfoで取得済みの場合はheader read回数がさらに減る。ディスクの物理I/O・read-ahead・seek回数・Generationの明示sha256走査はこの値に含まない。

巨大固定sample試験の割当object数は1,194（統合runner時）で、10,000未満を検証した。sample数分のRuby配列・繰返しを生成しない。80,008 bytesのsttsに1,024 bytes予算を指定した試験では、table本体を取得せずlimit、実readの最大長・合計とも1,024 bytes未満、割当object数10,000未満を確認した。allocator/RSSそのものの厳密上限は測っていない。

## ffprobeとの照合

既存`test/data/mp4.m4a`の45 samplesと先頭/末尾packetのpos/sizeを照合し、edit原点を差し引いてDTS/PTSを比較した。

実ffmpegで44.1kHz／48kHz × mono／stereoの4条件を生成し、限定roll sgpd/sbgpを検証してcompleteとなること、先頭／末尾sample境界を返すことを確認した。44.1kHz monoではraw first PTS=0、elst media_time=1024、ffprobe first PTS=-1024となり、先頭／末尾offset/size、raw PTSから1024を引いた値とpacket PTSが一致した。raw first/lastはgroupの有無で変わらない。復号PCMの一致はMListNew側試作で確認済みだが、本APIは復号を行わない。

全packet列挙はテストoracleだけで、製品APIは外部コマンドを一切実行しない。使用したffmpeg/ffprobeは`/Users/nasu/Bin`。利用できない環境では比較2件をomitする。

## 残る制限

対応外roll形式、roll recoveryの実際の復号挙動、他codec/handler、nonzero CTTSの公開PTS、複数edit、fragment、暗号化等は未対応。入力のcodec設定・payloadの正当性は未検証。MListNewの限定packet取得・planner・Tool/convdir接続、実作品、実ストレージの物理I/O・時間・RSSは検証していない。2.3.2.28 arm64 native artifactの隔離install smokeは成功し、x86_64 artifactとregistry公開はtag後workflowで検証する。

MListNewは確定schemaへ接続し、completeだけを採用し、edit原点・timescale・last packet・skip/discardを照合する必要がある。ffmpeg生成のroll付き入力は初期範囲では従来経路を維持する。単にstatusをcompleteへ変更して対応済みとみなしてはならない。
