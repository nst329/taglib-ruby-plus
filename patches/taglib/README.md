# TagLib 2.3.2 パッチ

このディレクトリは、TagLib本体へ適用するパッチを管理します。HomebrewのTagLibや
`/opt/homebrew`配下は変更しません。

- upstream: `https://github.com/taglib/taglib.git`
- base tag: `v2.3.2`
- base commit: `deadc2990767dfbda0701e0ab35fdeea653db08f`
- patch: `0001-mp4-mdta-preservation.patch`

## 内容

`moov/udta/meta`の`hdlr=mdta`を検出し、`keys`のindexと`ilst`の数値itemを分離して
読み込みます。各`data` atomのdata type、locale、生payloadを保持し、通常の`ilst`
保存時にもmdta itemを再出力します。既存キーの更新・削除、新規キー追加APIと、UTF-8 type 1の
`title`／`artist` fallbackも含みます。

通常の`ItemMap`へmdta itemを混在させないことが重要です。未知の型は生bytesとして
保持し、文字列へ暗黙変換しません。

さらに`IOStream::hasError()`と`File::ioError()`で短いwrite、seek、truncate、flushの失敗を
報告し、MP4保存の成功判定へ反映します。

## 適用と検証

```sh
git clone --branch v2.3.2 --depth 1 https://github.com/taglib/taglib.git /tmp/taglib-2.3.2
git -C /tmp/taglib-2.3.2 apply /path/to/taglib-ruby/patches/taglib/0001-mp4-mdta-preservation.patch
cmake -S /tmp/taglib-2.3.2 -B /tmp/taglib-build -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/taglib-build --parallel
```

パッチ適用済みTagLibを`TAGLIB_DIR`へインストールし、Ruby拡張をそのprefixへリンク
してください。TagLibパッチなしのライブラリへ自動fallbackしてはいけません。
