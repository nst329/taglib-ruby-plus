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

Rake::TestTask.new(:test) do |test|
  test.libs << 'test'
  test.pattern = 'test/**/*_test.rb'
  test.options = TEST_OUTPUT_OPTIONS
end

# 現行のTagLib::Plus::MP4公開APIだけを短時間で確認する入口。
Rake::TestTask.new('test:plus_mp4') do |test|
  test.libs << 'test'
  test.pattern = 'test/plus_mp4_api_test.rb'
  test.options = TEST_OUTPUT_OPTIONS
end

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
