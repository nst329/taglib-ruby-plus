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

Then install taglib-ruby-plus 2.3.2.1:

    gem install taglib-ruby-plus --version 2.3.2.1

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

    TAGLIB_DIR=/opt/homebrew/opt/taglib gem install taglib-ruby-plus --version 2.3.2.1

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
