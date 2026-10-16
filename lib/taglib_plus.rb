# frozen-string-literal: true

# Loads the complete taglib-ruby-plus API while retaining TagLib as the
# namespace of the wrapped C++ library.

platform = RUBY_PLATFORM.split('-')[1]
if platform == 'mingw32'
  # Enable loading of pre-compiled libtag.dll
  ENV['PATH'] += (File::PATH_SEPARATOR + __dir__)
end

require 'taglib/version'
require 'taglib/base'
require 'taglib/mpeg'
require 'taglib/id3v1'
require 'taglib/id3v2'
require 'taglib/ogg'
require 'taglib/vorbis'
require 'taglib/flac'
require 'taglib/mp4'
require 'taglib/aiff'
require 'taglib/wav'
require_relative 'taglib/plus_mp4'
