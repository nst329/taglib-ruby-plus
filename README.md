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

Then install taglib-ruby-plus 2.3.2.6:

    gem install taglib-ruby-plus --version 2.3.2.6

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
      gem 'taglib-ruby-plus-arm64-darwin', '2.3.2.6'
      # Intelの場合は上記の代わりに次を指定
      # gem 'taglib-ruby-plus-x86_64-darwin', '2.3.2.6'
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

    TAGLIB_DIR=/opt/homebrew/opt/taglib gem install taglib-ruby-plus --version 2.3.2.6

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

For MP4 chapters, use the explicit chapter save operation when only chapter
data should be changed:

    file = TagLib::MP4::File.new('sample.m4a', false)
    chapters = [
      TagLib::MP4::Chapter.new(start_time: 0, title: 'Opening'),
      TagLib::MP4::Chapter.new(start_time: 500, title: 'Main')
    ]
    file.set_chapters(chapters, style: :preserve)
    file.save_chapters
    file.close

`style: :preserve` keeps the existing Nero/QuickTime chapter format. If no
chapter format exists, both formats are created. SWIG is only needed by
contributors regenerating wrappers; it is not needed to install the gem.
Chapter comparison allows a 1ms start-time difference. Chapter input duration
is validated even when the file was opened with `read_properties: false`.

MP4 iTunes properties and artwork can be accessed through the high-level API:

    file = TagLib::MP4::File.new('sample.m4a', false)
    file.tag.set_property('TVShowName', 'Example Show')
    artworks = file.tag.artwork
    file.tag.set_artwork(artworks)
    file.save
    file.close

`Artwork` returns Ruby-owned image data and supports JPEG, PNG, and BMP. GIF is
not supported by the safe artwork API. `contentRating` uses a
`TagLib::MP4::ContentRating` value object because its MP4 representation is a
reverse-DNS item.

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

MP4の複数値mdta復元には、2.3.2.7と同改訂のTagLibパッチが必要です。
`replace_mdta_items` の使用例・対応構造は
[設計書](docs/mp4-mdta-replace-design.md)を参照してください。

提案用のgrouped mdta APIにもRuby bindingを接続しています。native要件は
TagLib 2.3.2基準＋`proposals/0001`＋binding用`proposals/0002`です。
`TAGLIB_DIR`で指定したライブラリのAPIをビルド時に判別し、既存Ruby APIを維持します。
本体への適用は行っておらず、一時コピーでの再現手順とMListNew向け使用例は
[Ruby binding結合検証](docs/Memos/2026-10-08-mdtaのRubyBinding結合検証.md)を参照してください。
`tag.mdta_status`はgrouped版で`:absent`、`:editable`、`:unsupported`を返し、
legacy版では推測せず`:unknown`を返します。

公開MP4 snapshot／一括復元／構造診断は2.3.2.8から利用できます。

```ruby
snapshot = TagLib::MP4::File.open(source, false) { |f| f.tag.metadata_snapshot }
TagLib::MP4::File.open(output, false) do |f|
  raise 'snapshot native API unavailable' unless f.tag.metadata_capabilities[:atomic_restore_v1]
  raise 'unsupported metadata' unless f.tag.metadata_diagnostics.restorable?
  f.tag.restore_metadata_snapshot(snapshot)
  f.save
  raise 'metadata mismatch' unless snapshot.logical_equal?(f.tag.metadata_snapshot)
end
```

字幕mux／音声変換後の一時出力へ復元する例です。字幕の保持検証と原本置換はMListNew側で行います。
対応構造・native要件・保存失敗時の契約は[設計書](docs/mp4-metadata-snapshot-design.md)、
判断理由は[ADR](docs/ADR/2026-10-08-mp4公開snapshotの実装.md)を参照してください。

### MP4 snapshotの部分編集・差分とcopyright

`MetadataSnapshot#without`は指定キーを除いた新snapshot、`with`は指定キーの型付き値を置換・追加した新snapshotを返します。
元snapshotは不変です。復元は全体置換なので、除外した値は復元先からも削除されます。mdtaのkeys表には値なしキーが残る場合があります。

```ruby
expected = original.without(items: ['©cpy'], mdta: ['gain'])
expected = expected.with(mdta: { 'gain' => [[1, 0, 'new'.b]] })
changes = expected.diff(actual) # 空ならlogical_equal?。binaryと画像はサイズ・SHA-256で表示。
effects = tag.property_update_effects(:title) # ©nam設定、mdta title削除
native_effects = tag.property_update_effects(:title, via: :native_setter) # mdtaを保持
tag.set_property('copyright', '著作権表示') # ©cpyの単一値を設定
```

`copyright`の読み取りは先頭値、`property_values('copyright')`は全値です。更新・削除は©cpyだけを対象とし、cprtとmdta copyrightを保持します。
2.3.2.9のnativeビルドには`0003-mp4-property-atoms.patch`も必要です。
保存幅などnative writer固有の制約は復元時にcommit前検証します。変更許可範囲の保持確認と変換後の原本置換は[連携設計](Docs/mp4-snapshot-extensions-design.md)を参照してください。
