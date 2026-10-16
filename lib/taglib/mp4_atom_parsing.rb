# frozen_string_literal: true

module TagLib::MP4
  # nativeを開かずに使える、境界・深さ・読込予算付きの共通atom parser。
  module AtomParsing
    CONTAINERS = %w[moov trak mdia minf stbl tref udta edts dinf].freeze
    private

    # Plusの同じ世代では境界indexだけを共有し、任意の部分解析は従来どおり検証する。
    def parse_mp4_atoms(io, start_offset, end_offset, depth = 0, budget = [50_000], read_budget = nil)
      if @io_generation && depth.zero? && start_offset.zero? && end_offset == io.stat.size && read_budget.nil?
        return @io_generation.atom_index { parse_mp4_atoms_uncached(io, start_offset, end_offset, depth, budget, read_budget) }
      end
      parse_mp4_atoms_uncached(io, start_offset, end_offset, depth, budget, read_budget)
    end

    # atom境界と再帰・件数を検証する共通parser。診断用の任意読込予算も共有する。
    def parse_mp4_atoms_uncached(io, start_offset, end_offset, depth = 0, budget = [50_000], read_budget = nil)
      raise MdtaSaveError.new('MP4 atom depth exceeds limit', phase: :verify) if depth > 16
      atoms = []
      offset = start_offset
      while offset < end_offset
        budget[0] -= 1
        raise MdtaSaveError.new('MP4 atom count exceeds limit', phase: :verify) if budget[0].negative?
        raise MdtaSaveError.new('truncated MP4 atom header', phase: :verify) if end_offset - offset < 8
        consume_mp4_read_budget!(read_budget, 8)
        header = read_mp4_bytes(io, offset, 8)
        size32 = header.unpack1('N')
        type = header.byteslice(4, 4)
        header_size = 8
        size = size32
        if size32 == 1
          raise MdtaSaveError.new('truncated extended MP4 atom header', phase: :verify) if end_offset - offset < 16
          consume_mp4_read_budget!(read_budget, 8)
          size = read_mp4_uint64(io, offset + 8)
          header_size = 16
        elsif size32.zero?
          size = end_offset - offset
        end
        if size < header_size || offset + size > end_offset
          raise MdtaSaveError.new('invalid MP4 atom while reading tracks', phase: :verify)
        end

        atom = {
          type: type,
          offset: offset,
          payload_offset: offset + header_size,
          end_offset: offset + size,
          children: []
        }
        if CONTAINERS.include?(type)
          atom[:children] = parse_mp4_atoms(io, atom[:payload_offset], atom[:end_offset], depth + 1, budget, read_budget)
        end
        atoms << atom
        offset += size
      end
      unless offset == end_offset
        raise MdtaSaveError.new('MP4 atom boundary mismatch while reading tracks', phase: :verify)
      end

      atoms
    end

    def consume_mp4_read_budget!(budget, length)
      return unless budget

      budget[0] -= length
      raise MdtaSaveError.new('MP4 atom read exceeds limit', phase: :verify) if budget[0].negative?
    end

    def read_mp4_bytes(io, offset, length)
      io.seek(offset)
      value = io.read(length)
      unless value && value.bytesize == length
        raise MdtaSaveError.new('truncated MP4 atom while reading tracks', phase: :verify)
      end

      value
    end

    def read_mp4_uint32(io, offset)
      read_mp4_bytes(io, offset, 4).unpack1('N')
    end

    def read_mp4_uint64(io, offset)
      read_mp4_bytes(io, offset, 8).unpack1('Q>')
    end

  end
end
