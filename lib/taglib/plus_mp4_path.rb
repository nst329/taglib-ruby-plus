# frozen_string_literal: true

module TagLib
  module Plus
    module MP4
      # RubyのmacOS向けcwd/realpath返却変換を通さず、POSIXの名前bytesを使う。
      module Path
        module_function

        def expand_path(path)
          value = ::File.path(path)
          return ::File.expand_path(value) unless RUBY_PLATFORM.include?('darwin')
          return ::File.expand_path(value) if value.start_with?('/', '~')

          require 'fiddle'
          cwd = allocated_path('getcwd', [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], [0, 0])
          ::File.expand_path(value, cwd)
        end

        def realpath(path)
          return ::File.realpath(path) unless RUBY_PLATFORM.include?('darwin')

          require 'fiddle'
          value = path.b
          raise ArgumentError, 'path contains NUL' if value.include?("\0")

          allocated_path('realpath', [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], [value, 0])
        end

        def allocated_path(name, types, arguments)
          resolve = Fiddle::Function.new(Fiddle::Handle::DEFAULT[name], types, Fiddle::TYPE_VOIDP)
          release = Fiddle::Function.new(Fiddle::Handle::DEFAULT['free'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
          pointer = resolve.call(*arguments)
          errno = Fiddle.last_error
          raise SystemCallError.new(name, errno) if pointer.null?

          begin
            pointer.to_s.force_encoding(Encoding.find('filesystem'))
          ensure
            release.call(pointer)
          end
        end
        private_class_method :allocated_path
      end
      private_constant :Path
    end
  end
end
