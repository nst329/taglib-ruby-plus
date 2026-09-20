# frozen-string-literal: true

class Build
  class << self
    def plat
      ENV['PLATFORM'] || 'i386-mingw32'
    end

    def version
      ENV['TAGLIB_VERSION'] || '2.3.2'
    end

    def dir
      "taglib-#{version}"
    end

    def tmp
      "#{__dir__}/../tmp"
    end

    def source
      "#{tmp}/#{dir}"
    end

    def tmp_arch
      "#{tmp}/#{plat}"
    end

    def install_dir
      "#{tmp_arch}/#{dir}"
    end

    def build_dir
      "#{install_dir}-build"
    end

    def library
      extension = RbConfig::CONFIG['host_os'].include?('darwin') ? 'dylib' : RbConfig::CONFIG['SOEXT']
      "#{install_dir}/lib/libtag.#{extension}"
    end
  end
end
