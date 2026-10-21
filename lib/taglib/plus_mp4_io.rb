# frozen_string_literal: true

module TagLib
  module Plus
    module MP4
      # pathと開いたhandleを照合し、置換と同一inodeへの変更を検出する。
      class Generation
        attr_reader :digest

        def initialize(path, verification)
          @path, @verification = path, verification
          @io = ::File.open(path, 'rb')
          @identity = identity(@io.stat)
          check_stat!
          @digest = hash_content if verification == :sha256
          check_stat!
        rescue StandardError
          close
          raise
        end

        # 内容照合の前後にもstatを確認し、走査中の変更を検出する。
        def check!
          changed! if @stale
          check_stat!
          if @verification == :sha256
            changed! unless hash_content == @digest
            check_stat!
          end
        rescue SystemCallError, IOError
          changed!
        end

        def close
          @io&.close unless @io&.closed?
        end

        # 計画を開いた原本世代へ結び付けるためのstat tokenを返す。
        def token
          @identity.dup.freeze
        end

        # 媒体bytesを持たず、同一世代のatom境界だけをheader・chapter解析で共有する。
        def atom_index
          return @atom_index if @atom_index
          check!
          value = yield
          check!
          @atom_index = DeepCopy.call(value)
        end

        # 章の完全読取と診断を同じ不変値へまとめ、sample解析は明示要求時だけ行う。
        def chapter_reader(samples)
          @chapter_readers ||= {}
          @chapter_readers[samples] ||= yield
        end

        def cached_chapter_reader(samples)
          @chapter_readers&.[](samples)
        end

        # rename後も検証済み候補のhandleを所有し続け、別inodeの採用を防ぐ。
        # SMBのctime反映遅延だけは、既取得の候補SHA256でfd/pathを再確認して許容する。
        def publish_to(path)
          current = identity(@io.stat)
          published = identity(::File.stat(path))
          unless current[0, 4] == @identity[0, 4] && published == current
            changed! unless ctime_only_difference?(@identity, current, published) &&
                           published_content_matches?(path)
            current = identity(@io.stat)
            changed! unless current[0, 4] == @identity[0, 4] && identity(::File.stat(path)) == current
          end
          @path, @identity = path, current
          @publication_digest = nil
        end

        private

        # pathを再openせず、世代確認で所有する同じhandleの内容を照合する。
        def hash_content
          @io.rewind
          hash = Digest::SHA256.new
          while (chunk = @io.read(1024 * 1024))
            hash.update(chunk)
          end
          hash.hexdigest
        end

        # 公開前に独立検証したSHAを、新しい原本世代の厳密照合に引き継ぐ。
        def adopt_digest(digest)
          @verification, @digest = :sha256, digest
        end

        # 公開直前に得た候補SHAを、stat検証世代のctime再確認へだけ渡す。
        def expect_publication_digest(digest)
          @publication_digest = digest
        end

        def identity(stat)
          [stat.dev, stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r]
        end

        def ctime_only_difference?(expected, current, published)
          expected[0, 4] == current[0, 4] && current[0, 4] == published[0, 4] &&
            [expected[4], current[4], published[4]].uniq.length > 1
        end

        # ctime差分の許容条件を、公開前に検証した候補内容へ限定する。
        def published_content_matches?(path)
          return false unless @publication_digest

          handle_digest = hash_content
          path_digest = Digest::SHA256.file(path).hexdigest
          handle_digest == @publication_digest && path_digest == @publication_digest
        end

        def check_stat!
          changed! unless identity(@io.stat) == @identity && identity(::File.stat(@path)) == @identity
        end

        def changed!
          @stale = true
          raise Error.new('source changed', code: :source_changed, phase: :prepare)
        end
      end

      # 一回の逐次読取でコピー・原本SHA・mdat署名を共有する。媒体を蓄積しない。
      module Stream
        CHUNK = 1024 * 1024
        module_function

        # replacementは[moov開始位置, 終了位置, 置換bytes]。出力検証は別走査で行う。
        def scan(path, destination: nil, replacement: nil)
          whole = Digest::SHA256.new
          media = []
          output = ::File.open(destination, 'wb') if destination
          ::File.open(path, 'rb') do |input|
            total = input.stat.size
            while input.pos < total
              start = input.pos
              header = read_exact(input, 8)
              size, type = header.unpack('Na4')
              if size == 1
                extension = read_exact(input, 8)
                size = extension.unpack1('Q>')
                header += extension
              elsif size.zero?
                size = total - start
              end
              raise IOError, 'invalid MP4 root boundary' if size < header.bytesize || start + size > total

              replaced = replacement && start == replacement[0]
              if replaced
                raise IOError, 'replacement boundary mismatch' unless start + size == replacement[1] && type == 'moov'
                output&.write(replacement[2])
              end
              whole.update(header)
              output&.write(header) unless replaced
              remaining = size - header.bytesize
              payload_size = remaining
              payload_hash = Digest::SHA256.new if type == 'mdat'
              while remaining.positive?
                chunk = read_exact(input, [remaining, CHUNK].min)
                whole.update(chunk)
                payload_hash.update(chunk) if type == 'mdat'
                output&.write(chunk) unless replaced
                remaining -= chunk.bytesize
              end
              media << [payload_size, payload_hash.hexdigest] if type == 'mdat'
            end
          end
          { digest: whole.hexdigest.freeze, media: media.freeze }
        ensure
          output&.close
        end

        def read_exact(input, length)
          bytes = input.read(length)
          raise IOError, 'truncated MP4 stream' unless bytes && bytes.bytesize == length
          bytes
        end
        private_class_method :read_exact
      end
      private_constant :Generation, :Stream
    end
  end
end
