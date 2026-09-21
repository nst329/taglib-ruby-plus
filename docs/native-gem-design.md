# macOS platform gem設計

## 決定

`taglib-ruby-plus`は、外部TagLibを必要としないmacOS platform gemを別途生成する。
対象platformは次の2つとする。

- `arm64-darwin`: 現行環境（ログ上は`arm64-darwin-25`）およびApple Silicon macOS
- `x86_64-darwin`: Intel版OS X 12.7（Darwin 21）

GitHub PackagesのRubyGems registryは同じgem名・versionのplatform違いを登録できないため、
配布名は次のように分離する。Ruby側のrequire名は従来どおり`taglib_plus`とする。

- `taglib-ruby-plus-arm64-darwin`
- `taglib-ruby-plus-x86_64-darwin`
- `taglib-ruby-plus-source`（source gem）

platform gemには、パッチ済みTagLibの`libtag`とRuby native extensionを同梱する。
Ruby extensionのRPATHは`@loader_path/taglib_plus/native/<platform>`とし、Homebrewや
システムのTagLibを実行時に参照しない。TagLibの`COPYING.LGPL`と`COPYING.MPL`も
platform gemへ同梱する。

通常のsource gemは引き続き`TAGLIB_DIR`で外部TagLibを指定する。platform gemだけは
gemspecの`requirements`とextension buildを省略し、同梱済みの`.bundle`を使用する。

## ビルド契約

TagLibは`patches/taglib/0001-mp4-mdta-preservation.patch`を適用済みで、macOS向けに
次の設定で構築する。

- `CMAKE_MACOSX_RPATH=ON`
- `CMAKE_INSTALL_NAME_DIR=@rpath`
- `CMAKE_OSX_DEPLOYMENT_TARGET=12.0`

OS X 12.7で動作させるため、macOS native gemの最小deployment targetは12.0とする。
現行artifactはRuby 4.0でビルドするため、platform gemの最小Ruby versionも4.0とする。
Ruby 3.2向けはsource gemを使用し、別Ruby ABI用のplatform gemを追加するまでは同梱対象外とする。

## 生成

```sh
TAGLIB_RUBY_NATIVE_PLATFORM=arm64-darwin \
TAGLIB_RUBY_GEM_NAME=taglib-ruby-plus-arm64-darwin \
TAGLIB_DIR=/path/to/patched/taglib \
TAGLIB_SOURCE_DIR=/path/to/taglib-source \
NATIVE_GEM_OUTPUT_DIR=pkg \
  ruby tasks/build_native_gem.rb
```

Intel向けは`TAGLIB_RUBY_NATIVE_PLATFORM=x86_64-darwin`に変更する。

同じgem versionを維持しながら、GitHub Packages上のgem名を分けて公開する。利用者は
Apple Siliconなら`taglib-ruby-plus-arm64-darwin`、Intelなら
`taglib-ruby-plus-x86_64-darwin`を明示する。source gemは
`taglib-ruby-plus-source`として公開し、従来どおり外部のパッチ済みTagLibを要求する。

この実装を含むgem versionは`2.3.2.4`とする。既存の`v2.3.2.3`は上書きせず、公開時は
`v2.3.2.4`のタグを新規作成する。

## 運用契約

- GitHub Actionsの`native-gems` workflowでarm64 macOSとIntel macOSのTagLibビルド・
  Ruby ABI検証を行い、3つの配布名をGitHub PackagesのRubyGems registryへ公開する。
  通常の手動実行では公開せず、既存タグを公開する場合だけ`publish=true`を明示する。
- Ruby 4.0のnative extension loadとMP4 mdta保存を各runnerで確認する。
- Ruby 3.2向けplatform gemは、RubyGemsのplatform選択だけではABIを分けられないため別途設計する。
- GitHub Actions内の公開にはリポジトリに関連付いた`GITHUB_TOKEN`を使用する。利用者の
  Bundlerは`https://rubygems.pkg.github.com/nst329`を明示し、PAT classicで認証する。
