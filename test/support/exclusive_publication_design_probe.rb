# frozen_string_literal: true

# 製品からrequireしない設計検証用の確定処理。link故障だけを注入し、rename自体はOSを使う。
class ExclusivePublicationDesignProbe
  UNSUPPORTED = %i[EOPNOTSUPP ENOTSUP].filter_map do |name|
    Errno.const_get(name) if Errno.const_defined?(name)
  end.uniq.freeze

  attr_reader :calls, :candidate_path, :candidate_identity
  attr_reader :link_error, :rename_error

  # errno指定は試験用。例えばlink_error: Errno::ENOTSUPでfallbackだけを実行する。
  def initialize(link_error: nil, rename_error: nil, before_rename: nil, after_rename: nil)
    @link_error, @rename_error = link_error, rename_error
    @before_rename, @after_rename = before_rename, after_rename
    @calls = []
  end

  def link(candidate, output)
    remember(candidate)
    @calls << :link
    raise @link_error, 'injected link failure' if @link_error

    File.link(candidate, output)
  end

  def before_rename(candidate, output)
    @calls << :exclusive_rename
    @before_rename&.call(candidate, output)
  end

  def after_rename(candidate, output)
    @after_rename&.call(candidate, output)
  end

  def remember(candidate)
    @candidate_path = candidate
    @candidate_identity = File.stat(candidate).then { |stat| [stat.dev, stat.ino, stat.size] }
  end

  # 同じ検証済み候補を名前操作だけで確定し、本文の読書きや再試行を行わない。
  def publish(candidate, output)
    remember(candidate)
    @calls << :link
    begin
      raise @link_error, 'injected link failure' if @link_error
      File.link(candidate, output)
    rescue *UNSUPPORTED
      @calls << :exclusive_rename
      @before_rename&.call(candidate, output)
      raise @rename_error, 'injected rename failure' if @rename_error
      exclusive_rename(candidate, output)
      @after_rename&.call(candidate, output)
    end
  end

  private

  # ABI/errnoの検証には実renamex_npを使用し、通常renameで代用しない。
  def exclusive_rename(candidate, output)
    raise NotImplementedError, 'design probe requires macOS' unless RUBY_PLATFORM.include?('darwin')
    require 'fiddle'
    function = Fiddle::Function.new(
      Fiddle::Handle::DEFAULT['renamex_np'],
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, -Fiddle::TYPE_INT], Fiddle::TYPE_INT
    )
    result = function.call(candidate, output, 0x4)
    errno = Fiddle.last_error
    raise SystemCallError.new('renamex_np(RENAME_EXCL)', errno) unless result.zero?
  end
end
