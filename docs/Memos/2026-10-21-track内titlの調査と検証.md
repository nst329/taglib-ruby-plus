# track内titlの調査と検証

## 実原本の調査

- 対象: ALDN-046（依頼されたMP4）、566,152,960 bytes。
- `/moov[1]/trak[3]/udta[1]/titl[1]`: offset=5,110,176、size=44、header=8、payload=36。
- `/moov[1]/trak[3]/udta[1]/titl[2]`: offset=5,110,220、size=44、header=8、payload=36。
- payloadは両方同一: `0000000055c4e697a5e69cace8aa9eefbc88537065656368416e616c797a6572efbc8900`。
- version/flags=0、packed language=0x55c4 (`und`)、UTF-8「日本語（SpeechAnalyzer）」＋NUL。
- 独立したread-only parserで既知containerとmeta/ilstを走査し、titlを2個検出。構造境界の破損なし。media sampleの内部bytesをatomとして探索してはいない。
- track udtaという配置は対応可能。同一言語の重複は規格の個数制約に適合しないが、位置依存情報のない非対象データとしてraw保持できる。重複解消は行わない。

## 公開APIによる実ファイルの検証

`TagLib::Plus::MP4.open` → `plan_limited_repairs` → `apply_limited_repairs` → `save!(to:)` → 別openで再計画を実行した。

- 計画: unchanged、metadata_complete、quicktime_absent、track IDs=[1,2,3]。
- 適用: 操作なし。別出力保存: changed=false、verification=independent_reopen。
- 原本・出力SHA-256: `16ee7ee3a4c3b706823e486458aea15d3dc8bf22256123de4db111b4fe475c96`。
- 独立parserでtitlの番号付き配置・個数・header込みraw bytesの一致を確認。
- 出力: `/private/tmp/titl-real-20261021-2593-m1enjj/repaired.mp4`。
- 原本を上書きせず、実行前後SHAも一致。実原本に必要な限定修復はなく、実修復成功の証拠は合成fixtureで確認した範囲と区別する。

## 自動検証

- 実例と同じ第3trackのudta内に同一titlを2個注入し、movie/他track内titlと混在。metadataの不正indexと欠落chap参照を同時に修復し、公開計画→適用→別出力→独立再読込を確認。
- 配置・順序・個数・通常/拡張header込みraw bytes、非対象metadata item、Nero、mdat保持を独立parserで比較。既存保持署名でも非対象track、chapter sample表、media相対位置を照合。
- 不正payloadでmetadata/quicktimeが同時blockedになり、共通原因・未完了診断と実path/offset/sizeを確認。未対応階層、version/flags/言語、UTF-8不正列・内部NUL、UTF-16不正終端・surrogate、size=0を拒否。
- 正常UTF-8/UTF-16BEを受理。16-bit境界をまたぐ00 00の誤検出回帰を確認。
- 削除する専用chapter trackにtitlがある場合、具体的な座標と保持不能理由でblocked。失敗時の原本保持・出力未作成を確認。
- 保存検証失敗時のtitl付き原本保持と一時出力cleanup、既存movie titl保持、titl不在、正常/不在chapter、session/世代・publication_status契約を関連テストで確認。
- 構文チェック: 変更Rubyファイルすべて成功。対象テスト: 93 tests / 1191 assertions、失敗・エラー0、省略1（既存の環境変数指定型実ファイルテスト）。実ファイルは上記の専用手順で別検証した。

全体テスト（`bundle exec rake test`）: test-unit 631 tests / 113,835 assertions、失敗・エラー0、省略13。minitest 12 runs / 24 assertions、失敗・エラー0、skip 5。既存の環境依存テストの省略であり、省略条件を解除しての他環境検証は行っていない。

## 制限と利用側

対象はmovie/trackのudtaにある、検証済みのTitle profileだけ。任意box・任意配置のraw保存を許可しない。size=0、非対応version/flags/言語、LE BOM、不正文字列、既存未対応構造は引き続きblocked。parser入口で境界が壊れている場合は共通構造失敗として停止し、確定できないatom座標は報告しない。他OS・別native backendの実行は未検証。

MListNewの変更は不要。blockedを尊重する現状を維持し、修正版gemへ更新する。gem公開・バージョン変更は未実施。

## リファクタリング後の検証

単一Title検証の分離、contextのArray化、エラー診断補完の共通化後に、変更Rubyファイル4件の構文チェックと`git diff --check`が成功した。Plus MP4公開API全テスト、chapter計画の安全性、chapter参照、atom修復をまとめて実行し、193 tests / 110,931 assertions、失敗・エラー0、省略1（環境変数指定型の既存実ファイルテスト）。

既存fixtureでraw保持・実座標付き拒否・共通構造失敗・世代検証・publication_statusと、moov再利用によるtitlの追加readなしを確認した。上記の全体テスト・実原本検証は保持対応実装時の結果であり、リファクタリング後は影響範囲の対象テストに限定して検証した。実原本への追加書込み・保存は行っていない。
