# frozen-string-literal: true

$LOAD_PATH.push File.expand_path('lib', __dir__)

require 'taglib/version'

native_platform = ENV['TAGLIB_RUBY_NATIVE_PLATFORM']
gem_name = ENV.fetch('TAGLIB_RUBY_GEM_NAME') do
  native_platform ? "taglib-ruby-plus-#{native_platform}" : 'taglib-ruby-plus'
end

Gem::Specification.new do |s|
  s.name        = gem_name
  s.version     = TagLib::Version::STRING
  s.authors     = ['Robin Stocker', 'Jacob Vosmaer', 'Thomas Chevereau']
  s.email       = ['robin@nibor.org']
  s.homepage    = 'https://github.com/nst329/taglib-ruby-plus'
  s.metadata    = {
    'github_repo' => 'ssh://github.com/nst329/taglib-ruby-plus'
  }
  s.licenses    = ['MIT']
  s.summary     = 'Extended Ruby interface for the TagLib C++ library'
  s.description = <<~DESC
    Extended Ruby interface for the TagLib C++ library, for reading and writing
    meta-data (tags) of many audio formats.

    In contrast to other libraries, this one wraps the C++ API using SWIG,
    not only the minimal C API. This means that all tags can be accessed.
  DESC

  s.require_paths = ['lib']
  s.required_ruby_version = '>= 3.2'
  s.requirements = if native_platform
                     []
                   else
                     ['TagLib C++ >= 2.3.2 (libtag1-dev in Debian/Ubuntu, taglib-devel in Fedora/RHEL)']
                   end

  s.add_development_dependency 'bundler', '>= 2.4', '< 5'
  s.add_development_dependency 'minitest', '>= 5.0', '< 7'
  s.add_development_dependency 'rake-compiler', '~> 0.9'
  s.add_development_dependency 'shoulda-context', '~> 2.0'
  s.add_development_dependency 'test-unit', '~> 3.5'
  s.add_development_dependency 'yard', '~> 0.9.26'

  s.extensions = [
    'ext/taglib_base/extconf.rb',
    'ext/taglib_mpeg/extconf.rb',
    'ext/taglib_id3v1/extconf.rb',
    'ext/taglib_id3v2/extconf.rb',
    'ext/taglib_ogg/extconf.rb',
    'ext/taglib_vorbis/extconf.rb',
    'ext/taglib_flac/extconf.rb',
    'ext/taglib_flac_picture/extconf.rb',
    'ext/taglib_mp4/extconf.rb',
    'ext/taglib_aiff/extconf.rb',
    'ext/taglib_wav/extconf.rb'
  ]

  if native_platform
    s.platform = Gem::Platform.new(native_platform)
    s.required_ruby_version = '>= 4.0'
    s.extensions = []
  end
  s.extra_rdoc_files = [
    'CHANGELOG.md',
    'LICENSE.txt',
    'README.md'
  ]
  s.files = [
    '.github/FUNDING.yml',
    '.rubocop.yml',
    '.yardopts',
    'CHANGELOG.md',
    'Gemfile',
    'Guardfile',
    'LICENSE.txt',
    'README.md',
    'docs/taglib-2.3.2-upgrade-design.md',
    'docs/ADR/2026-09-07-taglib-2.3.2対応.md',
    'Rakefile',
    'docs/default/fulldoc/html/css/common.css',
    'docs/mp4-chapter-api-design.md',
    'docs/mp4-atomicparsley-replacement-design.md',
    'docs/mp4-atomicparsley-replacement-validation.md',
    'docs/mp4-mdta-preservation-design.md',
    'docs/mp4-mdta-taglib-core-proposal.md',
    'docs/mp4-property-normalization-design.md',
    'docs/ADR/2026-08-28-taglib-ruby-plusへの名称変更.md',
    'docs/ADR/2026-08-28-mp4-chapter-read-ownership.md',
    'docs/ADR/2026-08-28-bundler4-ci-compatibility.md',
    'docs/ADR/2026-09-01-swig-tracking-moving-gc.md',
    'docs/Memos/2026-09-01-ruby4-mp4-item-map-segfault-investigation.md',
    'docs/taglib/aiff.rb',
    'docs/taglib/base.rb',
    'docs/taglib/flac.rb',
    'docs/taglib/id3v1.rb',
    'docs/taglib/id3v2.rb',
    'docs/taglib/mp4.rb',
    'docs/taglib/mpeg.rb',
    'docs/taglib/ogg.rb',
    'docs/taglib/riff.rb',
    'docs/taglib/vorbis.rb',
    'docs/taglib/wav.rb',
    'ext/extconf_common.rb',
    'ext/taglib_aiff/extconf.rb',
    'ext/taglib_aiff/taglib_aiff.i',
    'ext/taglib_aiff/taglib_aiff_wrap.cxx',
    'ext/taglib_base/extconf.rb',
    'ext/taglib_base/includes.i',
    'ext/taglib_base/taglib_base.i',
    'ext/taglib_base/taglib_base_wrap.cxx',
    'ext/taglib_flac/extconf.rb',
    'ext/taglib_flac/taglib_flac.i',
    'ext/taglib_flac/taglib_flac_wrap.cxx',
    'ext/taglib_flac_picture/extconf.rb',
    'ext/taglib_flac_picture/includes.i',
    'ext/taglib_flac_picture/taglib_flac_picture.i',
    'ext/taglib_flac_picture/taglib_flac_picture_wrap.cxx',
    'ext/taglib_id3v1/extconf.rb',
    'ext/taglib_id3v1/taglib_id3v1.i',
    'ext/taglib_id3v1/taglib_id3v1_wrap.cxx',
    'ext/taglib_id3v2/extconf.rb',
    'ext/taglib_id3v2/relativevolumeframe.i',
    'ext/taglib_id3v2/taglib_id3v2.i',
    'ext/taglib_id3v2/taglib_id3v2_wrap.cxx',
    'ext/taglib_mp4/extconf.rb',
    'ext/taglib_mp4/taglib_mp4.i',
    'ext/taglib_mp4/taglib_mp4_wrap.cxx',
    'ext/taglib_mpeg/extconf.rb',
    'ext/taglib_mpeg/taglib_mpeg.i',
    'ext/taglib_mpeg/taglib_mpeg_wrap.cxx',
    'ext/taglib_ogg/extconf.rb',
    'ext/taglib_ogg/taglib_ogg.i',
    'ext/taglib_ogg/taglib_ogg_wrap.cxx',
    'ext/taglib_vorbis/extconf.rb',
    'ext/taglib_vorbis/taglib_vorbis.i',
    'ext/taglib_vorbis/taglib_vorbis_wrap.cxx',
    'ext/taglib_wav/extconf.rb',
    'ext/taglib_wav/taglib_wav.i',
    'ext/taglib_wav/taglib_wav_wrap.cxx',
    'ext/valgrind-suppressions.txt',
    'ext/win.cmake',
    'patches/taglib/README.md',
    'patches/taglib/0001-mp4-mdta-preservation.patch',
    'lib/taglib_plus.rb',
    'lib/taglib/aiff.rb',
    'lib/taglib/base.rb',
    'lib/taglib/flac.rb',
    'lib/taglib/id3v1.rb',
    'lib/taglib/id3v2.rb',
    'lib/taglib/mp4.rb',
    'lib/taglib/mpeg.rb',
    'lib/taglib/ogg.rb',
    'lib/taglib/version.rb',
    'lib/taglib/vorbis.rb',
    'lib/taglib/wav.rb',
    'taglib-ruby-plus.gemspec',
    'tasks/docs_coverage.rake',
    'tasks/build_native_gem.rb',
    'tasks/build.rb',
    'tasks/ext.rake',
    'tasks/gemspec_check.rake',
    'tasks/swig_ruby_runtime_patch.rb',
    'tasks/swig.rake',
    'test/aiff_examples_test.rb',
    'test/aiff_file_test.rb',
    'test/aiff_file_write_test.rb',
    'test/base_test.rb',
    'test/data/Makefile',
    'test/data/add-relative-volume.cpp',
    'test/data/aiff-sample.aiff',
    'test/data/crash.mp3',
    'test/data/flac-create.cpp',
    'test/data/flac.flac',
    'test/data/flac_nopic.flac',
    'test/data/get_picture_data.cpp',
    'test/data/globe_east_540.jpg',
    'test/data/globe_east_90.jpg',
    'test/data/id3v1-create.cpp',
    'test/data/id3v1.mp3',
    'test/data/mp4-create.cpp',
    'test/data/mp4.m4a',
    'test/data/relative-volume.mp3',
    'test/data/sample.mp3',
    'test/data/unicode.mp3',
    'test/data/vorbis-create.cpp',
    'test/data/vorbis.oga',
    'test/data/wav-create.cpp',
    'test/data/wav-dump.cpp',
    'test/data/wav-sample.wav',
    'test/file_test.rb',
    'test/generate_mp4_mdta_fixture.rb',
    'test/fileref_open_test.rb',
    'test/fileref_properties_test.rb',
    'test/fileref_write_test.rb',
    'test/flac_file_test.rb',
    'test/flac_file_write_test.rb',
    'test/flac_picture_memory_test.rb',
    'test/helper.rb',
    'test/id3v1_genres_test.rb',
    'test/id3v1_tag_test.rb',
    'test/id3v2_frames_test.rb',
    'test/id3v2_header_test.rb',
    'test/id3v2_memory_test.rb',
    'test/id3v2_relative_volume_test.rb',
    'test/id3v2_tag_test.rb',
    'test/id3v2_unicode_test.rb',
    'test/id3v2_unknown_frames_test.rb',
    'test/id3v2_write_test.rb',
    'test/mp4_file_test.rb',
    'test/mp4_file_write_test.rb',
    'test/mp4_chapters_test.rb',
    'test/mp4_metadata_preservation_test.rb',
    'test/mp4_mdta_atom_probe.rb',
    'test/mp4_mdta_atom_probe_test.rb',
    'test/mp4_mdta_design_contract_test.rb',
    'test/mp4_mdta_direct_baseline.cpp',
    'test/mp4_mdta_io_fault_probe.cpp',
    'test/mp4_mdta_taglib_core_test.cpp',
    'test/mp4_mdta_taglib_test.rb',
    'test/mp4_metadata_api_test.rb',
    'test/mp4_items_test.rb',
    'test/mpeg_file_test.rb',
    'test/tag_test.rb',
    'test/unicode_filename_test.rb',
    'test/vorbis_file_test.rb',
    'test/vorbis_tag_test.rb',
    'test/wav_examples_test.rb',
    'test/wav_file_test.rb',
    'test/wav_file_write_test.rb',
    'docs/native-gem-design.md'
  ]

  if native_platform
    s.files.concat(Dir['lib/*.bundle'])
    s.files.concat(Dir['lib/taglib_plus/native/**/*'].select { |path| File.file?(path) })
    s.files.concat(Dir['licenses/taglib/**/*'].select { |path| File.file?(path) })
  end
end
