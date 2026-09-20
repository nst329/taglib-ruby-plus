# frozen-string-literal: true

desc 'Checks file list in .gemspec against files tracked in Git'
task :gemspec_check do |_t|
  exclude = ['.gitignore', '.github/workflows/ci.yml', '.github/workflows/native-gems.yml']
  # 日本語ファイル名を含む一覧を、gemspecの文字列と同じ形式で比較する。
  git_files = `git -c core.quotePath=false ls-files`.split("\n") - exclude
  gemspec_files = $gemspec.files

  only_in_gemspec = gemspec_files - git_files
  only_in_git = git_files - gemspec_files

  if only_in_gemspec.empty? && only_in_git.empty?
    puts 'gemspec file list is up to date.'
    next
  end

  unless only_in_gemspec.empty?
    puts 'In gemspec but not in git:'
    puts only_in_gemspec
  end

  unless only_in_git.empty?
    puts 'In git but not in gemspec:'
    puts only_in_git
  end

  abort 'gemspec file list does not match tracked files.'
end
