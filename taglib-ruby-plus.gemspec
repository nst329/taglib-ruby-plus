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
    # The CPU is encoded in the distribution name. Keep the RubyGems
    # platform neutral so the registry and installed specification match.
    s.platform = Gem::Platform::RUBY
    s.required_ruby_version = '>= 4.0'
    s.extensions = []
  end
  s.extra_rdoc_files = [
    'CHANGELOG.md',
    'LICENSE.txt',
    'README.md'
  ]
  s.files = [
    'docs/Memos/2026-10-09-2.3.2.12のバイナリgem検証.md',
    'docs/ADR/2026-10-09-2.3.2.12のリファクタリングとバイナリgem.md',
    'docs/Memos/2026-10-09-限定MP4修復の実装検証.md',
    'docs/ADR/2026-10-09-限定atom編集と原子的保存の共用.md',
    'lib/taglib/mp4_atom_repair.rb',
    'lib/taglib/mp4_unindexed_mdta.rb',
    'patches/taglib/0004-mp4-chapter-movie-duration.patch',
    'test/mp4_atom_repair_test.rb',
    'test/mp4_repair_investigation_test.rb',
    'test/support/mp4_investigation_fixture.rb',
    'docs/mp4-unindexed-metadata-and-chapter-timing-repair-design.md',
    'docs/ADR/2026-10-09-未対応mdtaのraw保持とchapter時間修復の分離.md',
    'docs/ADR/2026-10-09-複数trefの独立修復と時間情報の観測.md',
    'docs/Memos/2026-10-09-複数tref修復と時間診断の検証.md',
    'docs/Memos/2026-10-09-実MP4複数tref修復検証-010226_001.md',
    'docs/Memos/2026-10-09-metadataとchapter時間の設計前テスト.md',
    'lib/taglib/mp4_chapter_references.rb',
    'test/mp4_chapter_references_test.rb',
    'docs/mp4-chapter-reference-repair-design.md',
    'docs/ADR/2026-10-09-QuickTime欠落chapter参照の明示的除去.md',
    'docs/Memos/2026-10-09-QuickTime欠落chapter参照の検証.md',
    'lib/taglib/mp4_property_update_plan.rb',
    'lib/taglib/mp4_chapter_snapshot.rb',
    'lib/taglib/mp4_chapter_reader.rb',
    'test/mp4_snapshot_access_chapter_test.rb',
    'docs/mp4-snapshot-access-chapter-design.md',
    'docs/ADR/2026-10-09-snapshot値取得とchapter公開APIの設計.md',
    'docs/Memos/2026-10-09-snapshot値取得とchapter公開APIの試作検証.md',
    'docs/Memos/2026-10-09-snapshot値取得とchapter公開APIの実装検証.md',
    'docs/ADR/2026-10-09-snapshot追加APIの内部責務整理.md',
    'docs/Memos/2026-10-09-snapshot追加APIのリファクタリング検証.md',
    'docs/mp4-snapshot-extensions-design.md',
    'docs/ADR/2026-10-09-snapshot追加APIの試作結果に基づく設計.md',
    'docs/ADR/2026-10-09-snapshot追加APIの実装と検証後の見直し.md',
    'docs/Memos/2026-10-09-snapshot追加APIの試作検証.md',
    'docs/Memos/2026-10-09-snapshot追加APIの実装検証.md',
    'patches/taglib/0003-mp4-property-atoms.patch',
    'tasks/taglib_patches.rb',
    'test/mp4_copyright_test.rb',
    'test/mp4_snapshot_edit_diff_test.rb',
    'test/mp4_snapshot_extensions_test.rb',
    'test/support/mp4_snapshot_extensions_probe.rb',
    'test/taglib_patch_setup_test.rb',
    'ext/taglib_mp4/mdta_adapter.h',
    'patches/taglib/proposals/0002-ruby-mdta-state-transfer.patch',
    'test/mp4_mdta_binding_adapter_test.rb',
    'test/support/build_mp4_mdta_binding.py',
    'docs/ADR/2026-10-08-mdtaのRubyBinding接続.md',
    'docs/Memos/2026-10-08-mdtaのRubyBinding結合検証.md',
    'test/mp4_mdta_native_lifetime_test.cpp',
    'test/mp4_mdta_upstream_probe.cpp',
    'test/mp4_mdta_upstream_compat.cpp',
    'patches/taglib/proposals/0001-mp4-mdta-api.patch',
    'docs/Memos/2026-10-08-mdta上流向け隔離実装の検証.md',
    'test/mp4_mdta_upstream_probe_test.py',
    'test/support/build_mp4_mdta_upstream_probe.py',
    'test/support/mp4_mdta_upstream_limits.h',
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
    'docs/mp4-mdta-replace-design.md',
    'docs/Memos/2026-10-08-mdta一括置換の検証結果.md',
    'docs/ADR/2026-10-08-mdta複数値一括置換.md',
    'docs/mp4-mdta-taglib-core-proposal.md',
    'docs/mp4-mdta-upstream-design.md',
    'docs/mp4-metadata-snapshot-design.md',
    'lib/taglib/mp4_metadata_snapshot.rb',
    'test/mp4_metadata_snapshot_test.rb',
    'patches/taglib/0002-metadata-snapshot.patch',
    'patches/taglib/proposals/0003-ruby-metadata-snapshot.patch',
    'docs/ADR/2026-10-08-mp4公開snapshotの実装.md',
    'docs/Memos/2026-10-08-mp4公開snapshotの実装検証.md',
    'docs/Memos/2026-10-08-mp4公開snapshotの設計試作検証.md',
    'docs/ADR/2026-10-08-mp4公開snapshotと字幕保持の責務.md',
    'docs/Memos/2026-10-08-mdta上流設計のnative試作検証.md',
    'docs/ADR/2026-10-08-mdta上流向け公開API設計.md',
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
    'test/mp4_mdta_replace_native.cpp',
    'test/mp4_mdta_replace_test.rb',
    'test/mp4_snapshot_design_probe_test.rb',
    'test/mp4_snapshot_native_design_probe.cpp',
    'test/support/mp4_snapshot_design_probe.rb',
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
