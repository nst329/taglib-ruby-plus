# frozen_string_literal: true

module TagLib
  module Plus
    module MP4
      # 別出力の候補を既存先へ上書きせず確定するための最小状態とOS binding。
      module Publication
        class State
          STATUSES = %i[not_committed committed unknown].freeze
          attr_reader :status, :publication_method

          def initialize
            @status = :not_committed
          end

          def not_committed!
            @status = :not_committed
          end

          def mark_method!(name)
            @publication_method = name.to_sym
          end

          def committed!
            @status = :committed
          end

          def unknown!
            @status = :unknown
          end

          def committed
            return true if @status == :committed
            return nil if @status == :unknown

            false
          end
        end

        module ExclusiveRename
          RENAME_EXCL = 0x4
          UNSUPPORTED_ERRNOS = %i[EOPNOTSUPP ENOTSUP].filter_map do |name|
            Errno.const_get(name) if Errno.const_defined?(name)
          end.uniq.freeze
          DEFINITIVE_ERRNOS = %i[EEXIST EACCES EPERM ENOSPC EDQUOT EROFS EXDEV EINVAL ENOTSUP EOPNOTSUPP
                                  ENOSYS ENOTDIR ENAMETOOLONG ELOOP].filter_map do |name|
            Errno.const_get(name) if Errno.const_defined?(name)
          end.uniq.freeze
          @function_mutex = Mutex.new

          class Unsupported < StandardError; end

          module_function

          def unsupported_link_error?(error)
            UNSUPPORTED_ERRNOS.any? { |errno| error.is_a?(errno) }
          end

          # 既存link失敗後の候補を追加コピーせず、macOSの排他的renameで一度だけ確定する。
          def call(source, output, state:)
            function = rename_function
            state.unknown!
            result = function.call(native_path(source), native_path(output), RENAME_EXCL)
            errno = Fiddle.last_error
            unless result.zero?
              error = SystemCallError.new('renamex_np(RENAME_EXCL)', errno)
              state.not_committed! if definitive_error?(error)
              raise error
            end
            state.committed!
            nil
          rescue SystemCallError
            raise
          rescue Unsupported
            raise
          rescue StandardError
            state.unknown!
            raise
          end

          # Fiddle bindingはfallback時だけ解決し、同一プロセス内で再利用する。
          def rename_function
            raise Unsupported, 'exclusive rename requires macOS' unless RUBY_PLATFORM.include?('darwin')

            @function_mutex.synchronize do
              @rename_function ||= begin
                require 'fiddle'
                address = Fiddle::Handle::DEFAULT['renamex_np']
                Fiddle::Function.new(address, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, -Fiddle::TYPE_INT],
                                     Fiddle::TYPE_INT)
              rescue LoadError => error
                raise Unsupported, "renamex_np is unavailable: #{error.message}", cause: error
              rescue Fiddle::DLError => error
                raise Unsupported, "renamex_np is unavailable: #{error.message}", cause: error
              end
            end
          end

          def native_path(path)
            value = path.to_s.dup
            raise ArgumentError, 'path contains NUL' if value.include?("\0")

            value.force_encoding(Encoding::BINARY)
          end

          def definitive_error?(error)
            DEFINITIVE_ERRNOS.any? { |errno| error.is_a?(errno) }
          end
          private_class_method :native_path
        end
      end
    end
  end
end
