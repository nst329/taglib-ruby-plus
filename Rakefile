# frozen-string-literal: true

require 'bundler/gem_tasks'
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  warn e.message
  warn 'Run `bundle install` to install missing gems'
  exit e.status_code
end

require 'rake/testtask'
TEST_OUTPUT_OPTIONS = '--verbose=important-only --no-use-color --progress-style=fault-only --no-show-detail-immediately'

# test-unitとminitestを同じプロセスへ読み込むとautorunの選択で片方が
# 実行されないため、実行ファイルを分けてから統合タスクで順に実行する。
ALL_RUBY_TEST_FILES = FileList['test/**/*_test.rb']
MINITEST_FILES = ALL_RUBY_TEST_FILES.select do |path|
  File.read(path).match?(/require\s+["']minitest\/autorun["']/)
end
TEST_UNIT_FILES = ALL_RUBY_TEST_FILES - MINITEST_FILES

# runner固有のCLIだけを渡し、test-unitとminitestの引数を混在させない。
def define_ruby_test_task(name, files, options: TEST_OUTPUT_OPTIONS)
  Rake::TestTask.new(name) do |test|
    test.libs << 'test'
    test.test_files = files
    test.options = options
  end
end

define_ruby_test_task('test:unit', TEST_UNIT_FILES)
minitest_options = Gem.loaded_specs.fetch('minitest').version >= Gem::Version.new('6.0') ? '--quiet' : ''
define_ruby_test_task('test:minitest', MINITEST_FILES, options: minitest_options)

# 現行のTagLib::Plus::MP4公開APIだけを短時間で確認する入口。
define_ruby_test_task('test:plus_mp4', FileList['test/plus_mp4*_test.rb'])

task test: %i[test:unit test:minitest]

task default: %i[compile test]

require 'yard'
YARD::Rake::YardocTask.new do |t|
  version = TagLib::Version::STRING
  t.options = ['--title', "taglib-ruby-plus #{version}"]
end

$gemspec = Bundler::GemHelper.gemspec

import 'tasks/docs_coverage.rake'
import 'tasks/ext.rake'
import 'tasks/gemspec_check.rake'

# When importing swig.rake, the *_wrap.cxx files depend on being generated
# by Swig. Since the ExtensionTasks depend on the *_wrap.cxx files,
# compiling the extensions will trigger Swig, which is not desired as
# those files have already been generated and there's no reason to make
# Swig a variable of the CI. The environment variable can be set to
# prevent running swig.
import 'tasks/swig.rake' unless ENV['SKIP_SWIG'] == 'true'
