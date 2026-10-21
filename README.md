# taglib-ruby-plus

Extended Ruby interface for the [TagLib C++ library][taglib], based on the
original [taglib-ruby][original], for reading and writing metadata (tags) of
many audio formats.

In contrast to other libraries, this one wraps the full C++ API, not
only the minimal C API. This means that all tag data can be accessed,
e.g. cover art of ID3v2 or custom fields of Ogg Vorbis comments.

`taglib-ruby-plus` currently supports the following:

* Reading/writing common tag data of all formats that TagLib supports
* Reading/writing ID3v1 and ID3v2 including ID3v2.4 and Unicode
* Reading/writing Ogg Vorbis comments
* Reading/writing MP4 tags (.m4a)
* Reading/writing FFmpeg `mdta` metadata in MP4 files
* Reading/writing Nero and QuickTime MP4 chapters
* Reading/writing MP4 iTunes properties and multiple artwork items
* Reading audio properties (e.g. bitrate) of the above formats

開発版には、読み取り専用のMP4 [`file.sample_boundaries(track_id:)`](docs/mp4-sample-boundaries-design.md)
を追加しています。sample tableを検証し、先頭・末尾の位置とraw media時刻を返します。
対応外構造・予算上限・破損を区別し、media本文は読みません。未リリースです。

Contributions for more coverage of the library are very welcome.

[![Gem version][gem-img]][gem-link]
[![ci](https://github.com/nst329/taglib-ruby-plus/actions/workflows/ci.yml/badge.svg)](https://github.com/nst329/taglib-ruby-plus/actions/workflows/ci.yml)

## Installation

Before you install the gem, make sure to have the patched [TagLib 2.3.2][taglib]
from `patches/taglib/0001-mp4-mdta-preservation.patch` installed with header
files and a C++17 compiler. The MP4 extension checks the mdta API at build time
and does not fall back to an unpatched TagLib. This is a source gem: its native
extensions are compiled against the TagLib installed on your system.
The TagLib shared library is also required at runtime.

* Debian/Ubuntu: `sudo apt-get install libtag1-dev`
* Fedora/RHEL: `sudo dnf install taglib-devel`
* Brew: `brew install taglib`
* MacPorts: `sudo port install taglib`

パッケージマネージャー版のTagLibを使う場合も、MP4のmdta機能には上記パッチを
適用したTagLibを別prefixへ構築して指定してください。

Then install taglib-ruby-plus 2.3.2.35:

    gem install taglib-ruby-plus --version 2.3.2.35

### macOS platform gem

2.3.2.5から、macOS向けにパッチ済みTagLibを同梱したplatform gemを提供します。
対象はApple Silicon（`arm64-darwin`）とIntel版OS X 12.7（`x86_64-darwin`）です。
platformごとに配布gem名が異なるため、利用環境に対応するgemを明示してください。
これらのgemはパッチ済みTagLibを同梱するため、Homebrewや外部TagLibは不要です。
現行platform gemはRuby 4.0以上を対象とし、Ruby 3.2系ではsource gemを使用します。
CPUは配布gem名で分離するため、gemspecのplatformは`ruby`です。Bundlerでは対応する
CPU名のgemを指定してください。

platform gemはGitHub PackagesのRubyGems registryから取得します。GitHub Packagesは
同じgem名・versionのplatform違いを登録できないため、配布名をplatformごとに分けています。
GitHubリポジトリを`github:`で指定するとsource gemが再ビルドされるため、Bundlerでは
次のようにregistryを指定してください。GitHub Packagesのローカル取得にはPAT classicの
`read:packages`権限が必要です。

    bundle config set --global https://rubygems.pkg.github.com/nst329 USERNAME:TOKEN

Gemfile:

    source 'https://rubygems.org'
    source 'https://rubygems.pkg.github.com/nst329' do
      # Apple Siliconの場合
      gem 'taglib-ruby-plus-arm64-darwin', '2.3.2.35'
      # Intelの場合は上記の代わりに次を指定
      # gem 'taglib-ruby-plus-x86_64-darwin', '2.3.2.35'
    end

platform gemがまだ公開されていない環境、または対応外platformでは、同じregistryの
`taglib-ruby-plus-source`を指定し、従来どおりパッチ済みTagLibを`TAGLIB_DIR`で指定してください。

### MacOS

Depending on your brew setup, TagLib might be installed in different locations,
which makes it hard for taglib-ruby-plus to find it. To get the library location, run:

    $ brew info taglib
    taglib: stable 2.3.2 (bottled), HEAD
    Audio metadata library
    https://taglib.org/
    /opt/homebrew/Cellar/taglib/2.3.2 (files installed by Homebrew) *
    ...

Note the line with the path at the end. Provide that using the `TAGLIB_DIR`
environment variable when installing, like this:

    TAGLIB_DIR=/opt/homebrew/opt/taglib gem install taglib-ruby-plus --version 2.3.2.35

If you're using bundler, like this:

    TAGLIB_DIR=/opt/homebrew/opt/taglib bundle install

Another problem might be that `clang++` doesn't work with a specific version
of TagLib. In that case, try compiling taglib-ruby-plus's C++ extensions with a
different compiler:

    TAGLIB_RUBY_CXX=g++-4.2 gem install taglib-ruby-plus

## Usage

Complete API documentation can be found on
[rubydoc.info](https://rubydoc.info/gems/taglib-ruby-plus/frames).

Load the gem with `require 'taglib_plus'`. The Ruby namespace remains `TagLib`
because it represents the wrapped C++ library:

    require 'taglib_plus'

Begin with the `TagLib` namespace.

MP4の独自機能は`TagLib::Plus::MP4`を入口にします。読取・編集候補・保存を一つのセッションで扱います。

```ruby
TagLib::Plus::MP4.open('sample.m4a') do |file|
  file.metadata = file.metadata.with(properties: { title: '作品名', tv_show: '番組名' })
  file.chapters = file.chapters.with(nero: [
    TagLib::Plus::MP4::Chapter.new(start_ms: 0, title: '開始')
  ])
  file.save!
end
```

`save!(to: output_path)`は既存出力を上書きせず別ファイルを作ります。ブロック終了時の自動保存はありません。
別出力の公開結果が通信等で不明な場合は`TagLib::Plus::MP4::Error#publication_status == :unknown`
および`committed == nil`で通知されるため、出力の再試行や候補削除を行わずセッションを閉じてください。
診断は`file.diagnose(:chapter_references)`、参照解除は診断行を選択して
`file.detach_chapter_references(references: selected)`、保存は同じ`save!`を使います。

壊れたQuickTime chapterだけを除去する場合は、形式別完全読取と計画判定を使います。正常Neroは独立して取得され、正常QuickTimeは削除計画になりません。

```ruby
TagLib::Plus::MP4.open(stage_path) do |file|
  nero = file.read_chapters(style: :nero) # 不在はnil、異常はError
  plan = file.plan_quicktime_chapter_removal
  if plan.status == :removable
    file.remove_quicktime_chapters(plan: plan)
    file.save!
  end
end
```

映像sourceでも、全chap参照が同じ専用text trackへ収束し他用途共有がなければ削除対象にできます。字幕source、欠落参照、共有字幕、未知構造、Nero異常、I/O失敗は削除成功へ変換されません。詳細な判定・保存前後の比較・MListNewとの責務境界は
[QuickTime限定除去設計](docs/mp4-quicktime-chapter-removal-design.md)を参照してください。

不正mdta indexの限定除去と併用する場合は、両領域を独立診断して一回の別出力保存へまとめます。
次の例は、数値indexと既知の通常fourccが混在する生成規約が分かっている入力を対象とします。

```ruby
TagLib::Plus::MP4.open(source_path) do |file|
  plan = file.plan_limited_repairs(mdta_layout: :mixed_known_fourcc)
  if plan.status == :repairable
    file.apply_limited_repairs(plan: plan, allow: [
      :remove_invalid_mdta_indices, :remove_broken_quicktime_chapters
    ])
    result = file.save!(to: new_stage_path)
  end
end
```

`:unchanged`は修復不要、`:blocked`は安全な限定修復ができない状態です。
許可設定は要否判定に影響せず、正常な領域は変更しません。
不正indexは0とkeys件数を超える数値で、ilst内の位置や連続性に限定しません。
数値専用contextには`:indexed`を指定します。layoutはitem名の解釈を決めるため、入力の規約に合わせて指定してください。
未指定で解釈が曖昧なら削除を拒否します。詳細・保存結果・失敗状態は
[併用修復設計](docs/mp4-combined-limited-repair-design.md)を参照してください。

旧fork追加メソッドは公開APIから除外しました。内部writer・構造検証用の
`TagLib::MP4::Internal`には互換性を保証しません。元のtaglib-ruby由来の低水準APIは
`TagLib::MP4::File`に残します。新しい利用例・診断schema・保存失敗時の状態は
[Plus API仕様](docs/taglib-ruby-plus-api-redesign.md)を参照してください。
過去の機能別仕様にある旧APIの例は、内部実装と履歴の説明です。

## Documentation

[ドキュメント一覧](docs/README.md)から、機能別の設計・検証記録を参照できます。

## Release Notes

See [CHANGELOG.md](CHANGELOG.md).

## Contributing

### Dependencies

Fedora:

    sudo dnf install taglib-devel ruby-devel gcc-c++ redhat-rpm-config swig

### Building

Install dependencies (uses bundler, install it via `gem install bundler`
if you don't have it):

    bundle install

GitHub Actions installs the optional `kramdown` dependency automatically. To
generate YARD documentation locally, install it explicitly:

    gem install kramdown -v '~> 2.3.0'

Regenerate SWIG wrappers if you made changes in `.i` files (use version 3.0.7 of
SWIG - 3.0.8 through 3.0.12 will not work):

    rake swig

Force regeneration of all SWIG wrappers:

    touch ext/*/*.i
    rake swig

Compile extensions:

    rake clean compile

Run tests:

    rake test

Run irb with library:

    irb -Ilib -rtaglib_plus

Build and install gem into system gems:

    rake install

Build a specific version of Taglib:

    PLATFORM=x86_64-linux TAGLIB_VERSION=2.3.2 rake vendor

The above command will automatically download TagLib 2.3.2, apply the local
mdta preservation patch, build it and install it in
`tmp/x86_64-linux/taglib-2.3.2`.

The `swig`, `compile` and `test` tasks can then be executed against that specific
version of Taglib by setting the `TAGLIB_DIR` environment variable to
`$PWD/tmp/x86_64-linux/taglib-2.3.2` (it is assumed that TagLib headers are
located at `$TAGLIB_DIR/include` and taglib libraries at `$TAGLIB_DIR/lib`).

To do everything in one command:

    PLATFORM=x86_64-linux TAGLIB_VERSION=2.3.2 TAGLIB_DIR=$PWD/tmp/x86_64-linux/taglib-2.3.2 rake vendor compile test

### Workflow

* Check out the latest `main` branch to make sure the feature hasn't been
  implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone hasn't already
  requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch from `main`.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so that I don't break it
  in a future version unintentionally.
* Run `rubocop` locally to lint your changes and fix the issues. Please refer to
  [.rubocop.yml](.rubocop.yml) for the list of relaxed rules. Try to keep the
  liniting offenses to minimum. Preferably, first run `rubocop` on your fork to
  have a general idea of the existing linting offenses before writing new code.
* Please try not to mess with the Rakefile, version, or history. If you
  want to have your own version, or is otherwise necessary, that is
  fine, but please isolate to its own commit so I can cherry-pick around
  it.

## License

Copyright (c) 2010-2022 Robin Stocker and others, see Git history.

`taglib-ruby-plus` is distributed under the MIT License, see
[LICENSE.txt](LICENSE.txt) for details.

In the binary gem for Windows, a compiled [TagLib][taglib] is bundled as
a DLL. TagLib is distributed under the GNU Lesser General Public License
version 2.1 (LGPL) and Mozilla Public License (MPL).

[taglib]: http://taglib.github.io/
[original]: https://github.com/robinst/taglib-ruby
[gem-img]: https://badge.fury.io/rb/taglib-ruby-plus.svg
[gem-link]: https://rubygems.org/gems/taglib-ruby-plus
