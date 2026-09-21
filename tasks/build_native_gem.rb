# frozen-string-literal: true

require 'english'
require 'fileutils'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'lib')
require 'taglib/version'

module NativeGem
  EXTENSIONS = %w[
    taglib_base
    taglib_mpeg
    taglib_id3v1
    taglib_id3v2
    taglib_ogg
    taglib_vorbis
    taglib_flac
    taglib_flac_picture
    taglib_mp4
    taglib_aiff
    taglib_wav
  ].freeze

  module_function

  def run
    platform = ENV.fetch('TAGLIB_RUBY_NATIVE_PLATFORM')
    gem_name = ENV.fetch('TAGLIB_RUBY_GEM_NAME', "taglib-ruby-plus-#{platform}")
    taglib_dir = File.expand_path(ENV.fetch('TAGLIB_DIR'))
    license_dir = File.expand_path(ENV.fetch('TAGLIB_SOURCE_DIR', taglib_dir))
    output_dir = File.expand_path(ENV.fetch('NATIVE_GEM_OUTPUT_DIR', 'pkg'), ROOT)

    validate_platform!(platform)
    validate_taglib!(taglib_dir)
    validate_taglib_license!(license_dir)
    build_extensions(platform, taglib_dir)

    Dir.mktmpdir("taglib-ruby-plus-#{platform}") do |stage|
      stage_repository(stage)
      stage_taglib(stage, taglib_dir, platform)
      stage_extensions(stage, platform)
      stage_taglib_license(stage, license_dir)
      build_gem(stage, platform, output_dir, gem_name)
    end
  end

  def validate_platform!(platform)
    return if %w[arm64-darwin x86_64-darwin].include?(platform)

    abort "Unsupported native gem platform: #{platform.inspect}"
  end

  def validate_taglib!(taglib_dir)
    include_dir = File.join(taglib_dir, 'include')
    lib_dir = File.join(taglib_dir, 'lib')
    libraries = Dir[File.join(lib_dir, 'libtag*.dylib*')]
    return if File.directory?(include_dir) && libraries.any?

    abort "A patched macOS TagLib installation is required: #{taglib_dir}"
  end

  def validate_taglib_license!(license_dir)
    missing = %w[COPYING.LGPL COPYING.MPL].reject do |name|
      File.file?(File.join(license_dir, name))
    end
    return if missing.empty?

    abort "TagLib license files are missing from #{license_dir}: #{missing.join(', ')}"
  end

  def build_extensions(platform, taglib_dir)
    rpath = "-Wl,-rpath,@loader_path/taglib_plus/native/#{platform}"
    ldflags = [ENV['TAGLIB_RUBY_LDFLAGS'], rpath].compact.reject(&:empty?).join(' ')
    environment = {
      # The repository must resolve as the source gem while compiling its
      # extensions. The platform gem setting is only needed when packaging.
      'TAGLIB_RUBY_NATIVE_PLATFORM' => nil,
      'TAGLIB_DIR' => taglib_dir,
      'TAGLIB_RUBY_LDFLAGS' => ldflags,
      'MACOSX_DEPLOYMENT_TARGET' => ENV.fetch('MACOSX_DEPLOYMENT_TARGET', '12.0'),
      'SKIP_SWIG' => ENV.fetch('SKIP_SWIG', 'true')
    }
    return if ENV['NATIVE_GEM_SKIP_COMPILE'] == 'true'

    abort 'Ruby native extension compilation failed' unless system(environment, 'bundle', 'exec', 'rake', 'compile')
  end

  def stage_repository(stage)
    tracked_files.each do |relative_path|
      source = File.join(ROOT, relative_path)
      destination = File.join(stage, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
    end
  end

  def stage_extensions(stage, platform)
    EXTENSIONS.each do |extension|
      candidates = [
        File.join(ROOT, 'lib', "#{extension}.bundle"),
        *Dir[File.join(ROOT, 'tmp', '**', 'stage', 'lib', "#{extension}.bundle")],
        File.join(ROOT, 'ext', extension, "#{extension}.bundle")
      ].select { |path| File.file?(path) }
      abort "Compiled extension is missing: #{extension}" if candidates.empty?

      destination = File.join(stage, 'lib', "#{extension}.bundle")
      FileUtils.cp(candidates.fetch(0), destination)
      rewrite_extension_dependencies(destination, platform)
    end
  end

  def stage_taglib(stage, taglib_dir, platform)
    destination = File.join(stage, 'lib', 'taglib_plus', 'native', platform)
    FileUtils.mkdir_p(destination)
    Dir[File.join(taglib_dir, 'lib', 'libtag.2*.dylib*')].each do |source|
      FileUtils.cp_r(source, File.join(destination, File.basename(source)), preserve: true)
    end
    versioned_library = Dir[File.join(destination, 'libtag.2.*.dylib')]
                       .reject { |path| File.symlink?(path) }
                       .fetch(0)
    system('install_name_tool', '-id', '@rpath/libtag.2.dylib', versioned_library) ||
      abort('Could not make the bundled TagLib install name relocatable')
    install_name = `otool -D #{Shellwords.escape(versioned_library)}`.lines.last.to_s.strip
    abort('Bundled TagLib install name is not relocatable') unless install_name == '@rpath/libtag.2.dylib'
  end

  def rewrite_extension_dependencies(bundle, platform)
    rpath = "@loader_path/taglib_plus/native/#{platform}"
    ruby_dependencies = `otool -L #{Shellwords.escape(bundle)}`.lines.filter_map do |line|
      dependency = line.strip.split.first
      dependency if dependency&.match?(%r{(?:^/|^@rpath/)libruby(?:\.\d+)?\.dylib})
    end
    abort("Ruby runtime dependency remains in #{bundle}: #{ruby_dependencies.join(', ')}") unless ruby_dependencies.empty?

    dependencies = `otool -L #{Shellwords.escape(bundle)}`.lines.filter_map do |line|
      dependency = line.strip.split.first
      dependency if dependency&.match?(%r{(?:/|@rpath/)libtag(?:\.\d+)?\.dylib})
    end
    return if dependencies.empty?

    dependencies.each do |dependency|
      next if dependency == '@rpath/libtag.2.dylib'

      system('install_name_tool', '-change', dependency, '@rpath/libtag.2.dylib', bundle) ||
        abort("Could not rewrite TagLib dependency in #{bundle}")
    end
    remaining = `otool -L #{Shellwords.escape(bundle)}`.lines.filter_map do |line|
      dependency = line.strip.split.first
      dependency if dependency&.match?(%r{^/.*libtag(?:\.\d+)?\.dylib})
    end
    abort("Absolute TagLib dependency remains in #{bundle}") unless remaining.empty?
    return if `otool -l #{Shellwords.escape(bundle)}`.include?(rpath)

    system('install_name_tool', '-add_rpath', rpath, bundle) ||
      abort("Could not add TagLib RPATH to #{bundle}")
  end

  def stage_taglib_license(stage, license_dir)
    destination = File.join(stage, 'licenses', 'taglib')
    FileUtils.mkdir_p(destination)
    %w[COPYING.LGPL COPYING.MPL].each do |name|
      FileUtils.cp(File.join(license_dir, name), File.join(destination, name))
    end
  end

  def build_gem(stage, platform, output_dir, gem_name)
    FileUtils.mkdir_p(output_dir)
    output = File.join(output_dir, "#{gem_name}-#{TagLib::Version::STRING}-#{platform}.gem")
    environment = {
      'TAGLIB_RUBY_NATIVE_PLATFORM' => platform,
      'TAGLIB_RUBY_GEM_NAME' => gem_name
    }
    Dir.chdir(stage) do
      abort 'Native gem build failed' unless system(environment, 'gem', 'build', 'taglib-ruby-plus.gemspec', '--output', output)
    end
    puts output
  end

  def tracked_files
    files = `git -C #{Shellwords.escape(ROOT)} ls-files -z`
    abort 'Native gem build must run from a Git checkout' unless $CHILD_STATUS.success?

    files.split("\0").reject(&:empty?)
  end
end

NativeGem.run if $PROGRAM_NAME == __FILE__
