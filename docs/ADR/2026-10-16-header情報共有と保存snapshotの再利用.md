# header情報共有と保存snapshotの再利用

状態: 採用・実装・受入検証済み

## 決定と理由

公開情報は `file.info(sections: [:movie, :tracks])` に集約する。不変Hashで原本のheader宣言を返し、追加選択は `:chapters`（件数宣言）と `:artwork`（metadata画像の形式・長さ）とする。既存のchapter診断・sample APIを複製せず、atom境界の解析を同じFile世代で共有する。nativeを開くと旧metadataや画像を読み込むため、header取得はRubyの境界parserだけを使う。外部コマンドとsample payload読取は行わない。

movieのmvhd、trackのtkhd、mediaのmdhd、edit listのelstは別の時間軸として返す。日時は1904-01-01 UTC基準のraw整数で、ゼロは未設定、秒以下は存在しない。日時の推測補正はしない。codec名をfourccから推測しない。chapter参照はtrack IDでありstream indexではない。役割の根拠が競合するとambiguous、textだけ等の弱い根拠はunknownにする。artworkはcovrとして別扱いにし、JPEGのvideo trackを勝手にcoverとしない。

完全metadata置換は保存先の構造だけを検査し、旧値のnative変換と旧artwork snapshotを作らない。取得済みbaselineがあれば厳密比較で無変更を検出する。未取得baselineへの完全代入は、値が同じか不明なため置換予定として扱う。無変更を証明するためだけに旧値を読み直さない。

`save!(to:)` は原本から出力先と同じディレクトリの候補へ直接一回出力し、検証後に排他的公開する。stageを使用側で先に作る必要はない。既存出力を上書きしない契約は維持する。

save!の返却Hashに `snapshots` を追加する。変更保存時は既に独立再読込するmetadataを返し、chapterは必要時または `snapshots: [:chapters]` 指定時だけ再読込する。未読領域を期待値で埋めない。別path保存でも原本セッションを切り替えず、返却snapshotから出力結果を取得できる。

不変snapshot内の凍結済みStringは共有する。可変入力は所有コピーし、Array/Hashは再構成して凍結する。bytesのencoding変換が不要な場合だけ同じbinary Stringを再利用し、with/withoutのたびの大きい画像複製を避ける。

## 受入方針

先に公開入口のテストで、native/probe/sampleへの禁止呼出し、headerの時間軸・日時・不明値・役割分類、cacheと失効を確認する。保存側は構造検査を維持した旧値変換の省略、一回のstage出力、実出力snapshotの再利用、画像bytesの同一object共有を検証する。大きいmdat/artworkで論理I/Oと走査・コピー・外部probe回数を計測する。

## 実装で確定した判断

- 原本世代にatom境界indexを保持し、共通parserをnative Fileとheader readerへ分離した。cacheはoffsetと不変値だけで、mdatを保持しない。
- 完全chapter readerをcacheするときはnative FileとIO参照を除去してfreezeする。logical観測とsample観測は別に遅延する。保存候補の観測も、原本置換後の世代へ引き継ぐ。
- 完全metadata置換では旧metaをmoov再構成のためにも読まない。生成済みudtaと保持leafだけからatom計画を作る。旧文書のcontainer-transform経路へ全metadataを渡す方式はやめた。
- 実測と禁止テストで、meta version確認が本文全体を読んでいることを確認し、4 bytes読取に変更した。snapshot取得でも未使用の全item raw digestを計算しない。purlのraw取得と出力署名照合は維持する。
- metadataのみの保存では、過去にchaptersを取得済みでも出力chapterを解析しない。未選択の古いchapter cacheを原本置換後に失効させ、必要なら次の明示取得で読む。snapshot選択がある場合だけ実出力値をcacheへ採用する。
- nameはtrackのudta/name、handler_nameはhdlr由来として分ける。旧QuickTime言語・encoding等の未対応値はrawとunknownを返す。ヘッダー情報をデコード済みstreamの状態として扱わない。

[公開仕様](../mp4-header-info-design.md)と[最終計測・回帰結果](../Memos/2026-10-16-headerと保存snapshotの再利用検証.md)を参照する。新しいRubyファイルとテスト・文書をgemspecへ追加し、native ABIとバージョンは変更しない。

header payloadの単一1 MiB・合計8 MiB上限は、File cacheを媒体サイズに比例させないために設けた。時間・寸法・sample rateはraw整数または有理数を使い、浮動小数点丸めを避ける。track日時はtkhdとmdhdを別々に保持し、表示寸法とsample entry寸法も分ける。回転はraw行列の規約を明示し、外部probeの正負規約へ推測変換しない。
