# frozen-string-literal: true

require 'digest'
require 'fileutils'
require 'taglib_mp4'

module TagLib::MP4
  class UnsupportedArtworkError < ArgumentError; end

  # Ruby-owned copy of an MP4 cover-art item.
  class Artwork
    FORMATS = {
      jpeg: [CoverArt::JPEG, 'image/jpeg'],
      png: [CoverArt::PNG, 'image/png'],
      bmp: [CoverArt::BMP, 'image/bmp']
    }.freeze

    FORMAT_BY_NATIVE_VALUE = FORMATS.each_with_object({}) do |(name, values), result|
      result[values.first] = name
    end.freeze

    attr_reader :format, :data

    def initialize(format:, data:)
      @format = normalize_format(format)
      raise ArgumentError, 'artwork data must be a String' unless data.is_a?(String)
      raise ArgumentError, 'artwork data must not be empty' if data.empty?

      @data = data.dup.force_encoding(Encoding::BINARY)
      validate_signature!
      @data.freeze
      freeze
    end

    def mime_type
      FORMATS.fetch(format).last
    end

    def ==(other)
      other.is_a?(Artwork) && format == other.format && data == other.data
    end
    alias eql? ==

    def hash
      [format, data].hash
    end

    def inspect
      Kernel.format('#<%s format=%s data_size=%d>', self.class, format.inspect, data.bytesize)
    end

    def self.from_cover_art(cover_art)
      native_format = cover_art.format
      format = FORMAT_BY_NATIVE_VALUE.fetch(native_format) do
        raise UnsupportedArtworkError, "unsupported MP4 artwork format: #{native_format.inspect}"
      end
      new(format: format, data: cover_art.data)
    end

    def native_format
      FORMATS.fetch(format).first
    end

    private

    def normalize_format(value)
      format = value.to_sym if value.respond_to?(:to_sym)
      return format if FORMATS.key?(format)

      raise UnsupportedArtworkError, "unsupported MP4 artwork format: #{value.inspect}"
    end

    def validate_signature!
      signatures = {
        jpeg: -> { data.start_with?("\xFF\xD8\xFF".b) },
        png: -> { data.start_with?("\x89PNG\r\n\x1A\n".b) },
        bmp: -> { data.start_with?('BM'.b) }
      }
      return if signatures.fetch(format).call

      raise ArgumentError, "artwork data does not match #{format} format"
    end
  end

  # Structured representation of the iTunes reverse-DNS content rating item.
  class ContentRating
    attr_reader :system, :rating, :id

    def initialize(system:, rating:, id:)
      @system = validate_text(system, 'system')
      @rating = validate_text(rating, 'rating')
      unless id.is_a?(Integer) && id >= 0
        raise ArgumentError, 'content rating id must be a non-negative Integer'
      end
      @id = id
      freeze
    end

    def to_s
      "#{system}|#{rating}|#{id}|"
    end

    def ==(other)
      other.is_a?(ContentRating) && system == other.system && rating == other.rating && id == other.id
    end
    alias eql? ==

    def hash
      [system, rating, id].hash
    end

    def self.parse(value)
      fields = value.split('|', -1)
      unless fields.length == 4 && fields.last.empty? && !fields[0].empty? && !fields[1].empty?
        return value
      end

      id = Integer(fields[2], 10)
      return value unless id.to_s == fields[2]
      new(system: fields[0], rating: fields[1], id: id)
    rescue ArgumentError
      value
    end

    private

    def validate_text(value, name)
      value = value.to_s.encode(Encoding::UTF_8) if value.is_a?(Symbol)
      unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?
        raise ArgumentError, "content rating #{name} must be a UTF-8 String"
      end
      raise ArgumentError, "content rating #{name} must not contain NUL bytes" if value.include?("\0")
      raise ArgumentError, "content rating #{name} must not contain pipe characters" if value.include?('|')

      value.dup.freeze
    end
  end

  # Immutable Ruby value copied to and from TagLib's MP4::Chapter.
  class Chapter
    attr_reader :start_time, :title

    def initialize(start_time = nil, title = nil, **keywords)
      if keywords.any?
        raise ArgumentError, 'use either positional or keyword arguments' unless start_time.nil? && title.nil?

        start_time = keywords.delete(:start_time)
        title = keywords.delete(:title)
        raise ArgumentError, "unknown keywords: #{keywords.keys.join(', ')}" unless keywords.empty?
      end
      raise ArgumentError, 'start_time is required' if start_time.nil?
      raise ArgumentError, 'title is required' if title.nil?
      raise ArgumentError, 'start_time must be an Integer' unless start_time.is_a?(Integer)
      raise ArgumentError, 'start_time must not be negative' if start_time.negative?
      raise ArgumentError, 'title must be a UTF-8 String' unless title.is_a?(String) && title.encoding == Encoding::UTF_8 && title.valid_encoding?
      raise ArgumentError, 'title must not contain NUL bytes' if title.include?("\0")

      @start_time = start_time
      @title = title
      freeze
    end

    def ==(other)
      other.is_a?(Chapter) && start_time == other.start_time && title == other.title
    end
    alias eql? ==

    def hash
      [start_time, title].hash
    end

    def inspect
      format('#<%s start_time=%d title=%p>', self.class, start_time, title)
    end
  end

  class ChapterConflictError < StandardError; end
  class ChapterSaveError < StandardError; end
  class MdtaItemError < ArgumentError; end
  class MdtaSaveError < StandardError
    attr_reader :committed, :phase

    def initialize(message, committed: false, phase: nil)
      @committed = committed
      @phase = phase
      super(message)
    end
  end

  class MdtaItem
    attr_reader :key, :key_index, :data_type, :locale, :data

    def initialize(key:, key_index:, data_type:, locale:, data:)
      @key = key.dup.freeze
      @key_index = Integer(key_index)
      @data_type = Integer(data_type)
      @locale = Integer(locale)
      @data = data.dup.force_encoding(Encoding::BINARY).freeze
      freeze
    end

    def text
      return unless data_type == 1

      candidate = data.dup.force_encoding(Encoding::UTF_8)
      candidate.valid_encoding? ? candidate : nil
    end

    def ==(other)
      other.is_a?(MdtaItem) && [key, key_index, data_type, locale, data] ==
        [other.key, other.key_index, other.data_type, other.locale, other.data]
    end
    alias eql? ==

    def hash
      [key, key_index, data_type, locale, data].hash
    end

    def inspect
      format('#<%s key=%p index=%d type=%d locale=%d bytes=%d>', self.class, key,
             key_index, data_type, locale, data.bytesize)
    end
  end

  class File
    extend ::TagLib::FileOpenable

    MP4_TRACK_MEDIA_HANDLERS = %w[vide soun text].freeze
    MP4_ATOM_CONTAINERS = %w[moov trak mdia minf stbl tref].freeze

    CHAPTER_STYLE_CODES = {
      nero: 1,
      quicktime: 2,
      both: 3,
      any: 4
    }.freeze

    alias initialize_without_snapshot initialize
    private :initialize_without_snapshot

    def initialize(*args)
      initialize_without_snapshot(*args)
      @mp4_metadata_snapshot = metadata_snapshot
      @chapter_changes = {}
    end

    def chapters(style: nil)
      read_chapter_style_code(style) unless style.nil?
      return chapter_values(style) if @chapter_changes.any?

      _chapters(style.nil? ? CHAPTER_STYLE_CODES[:any] : CHAPTER_STYLE_CODES.fetch(style))
    end

    def chapter_style
      return chapter_style_from_values if @chapter_changes.any?

      _chapter_style
    end

    def set_chapters(chapters, style: :preserve)
      if style == :preserve
        style = chapter_style
        style = :both if style == :none
      end
      _validate_chapters(chapters)
      update_chapter_change(chapters, style)
      self
    end

    def remove_chapters(style: :both)
      if style == :preserve
        style = chapter_style
        style = :both if style == :none
      end
      chapter_style_code(style)
      update_chapter_change([], style)
      self
    end

    def nero_chapters
      chapters(style: :nero)
    end

    def set_nero_chapters(chapters)
      set_chapters(chapters, style: :nero)
    end

    def remove_nero_chapters
      remove_chapters(style: :nero)
    end

    def quicktime_chapters
      chapters(style: :quicktime)
    end

    def set_quicktime_chapters(chapters)
      set_chapters(chapters, style: :quicktime)
    end

    def remove_quicktime_chapters
      remove_chapters(style: :quicktime)
    end

    def save_chapters
      if metadata_dirty?
        raise ChapterSaveError, 'save metadata changes before save_chapters'
      end

      atomic_save(write_metadata: false)
    end

    alias save_without_chapter_state save
    private :save_without_chapter_state

    def save(*args)
      raise ArgumentError, 'save does not accept arguments' unless args.empty?

      atomic_save(write_metadata: true)
    end

    private

    def atomic_save(write_metadata:)
      source_path = name
      raise MdtaSaveError.new('MP4 file has no path', phase: :prepare) if source_path.nil? || source_path.empty?

      expected_metadata = metadata_snapshot
      expected_chapters = chapter_snapshot
      # Chapter edits can append media regardless of which public save API is used.
      chapter_edits = @chapter_changes.any?
      source_media = if chapter_edits
                       chapter_media_signature(source_path)
                     else
                       mdat_payload_signature(source_path)
                     end
      temp_path = "#{source_path}.taglib-mdta-#{Process.pid}-#{object_id}"
      committed = false

      begin
        ::FileUtils.cp(source_path, temp_path)
        save_temporary_copy(temp_path, write_metadata: write_metadata)

        verify_saved_copy(temp_path, expected_metadata, expected_chapters, source_media,
                          chapter_edits: chapter_edits)
        ::FileUtils.mv(temp_path, source_path)
        committed = true

        close
        begin
          initialize(source_path, false)
        rescue StandardError => error
          raise MdtaSaveError.new("MP4 reopened failed after rename: #{error.message}",
                                  committed: true, phase: :reopen)
        end

        @chapter_changes.clear
        true
      rescue MdtaSaveError
        raise
      rescue StandardError => error
        raise MdtaSaveError.new(error.message, committed: committed, phase: :replace)
      ensure
        ::FileUtils.rm_f(temp_path) unless committed
      end
    end

    def save_temporary_copy(path, write_metadata:)
      self.class.open(path, false) do |temporary|
        copy_tag_state_to(temporary) if write_metadata
        apply_chapter_state_to(temporary)
        unless temporary.send(:save_without_chapter_state)
          raise MdtaSaveError.new('TagLib failed to save temporary MP4', phase: :taglib_save)
        end
      end
    end

    def copy_tag_state_to(destination)
      tag.send(:ensure_mdta_support!)
      tag._copy_state_to(destination.tag)
    end

    def apply_chapter_state_to(destination)
      return if @chapter_changes.empty?

      @chapter_changes.each do |style, chapters|
        destination.send(:apply_chapter_change_to_native, chapters, style)
      end
    end

    def verify_saved_copy(path, expected_metadata, expected_chapters, source_media, chapter_edits:)
      self.class.open(path, false) do |verification|
        actual_metadata = verification.send(:metadata_snapshot)
        unless actual_metadata == expected_metadata
          raise MdtaSaveError.new('temporary MP4 metadata verification failed', phase: :verify)
        end
        actual_chapters = verification.send(:chapter_snapshot)
        unless actual_chapters == expected_chapters
          raise MdtaSaveError.new('temporary MP4 chapter verification failed', phase: :verify)
        end
        actual_media = if chapter_edits
                         verification.send(:chapter_media_signature, path)
                       else
                         verification.send(:mdat_payload_signature, path)
                       end
        media_preserved = if chapter_edits
                            media_tracks_preserved?(source_media, actual_media)
                          else
                            actual_media == source_media
                          end
        unless media_preserved
          raise MdtaSaveError.new('temporary MP4 media payload changed', phase: :verify)
        end
      end
    end

    def metadata_dirty?
      metadata_snapshot != @mp4_metadata_snapshot
    end

    def chapter_media_signature(path)
      tracks = track_media_signatures(path)
      chapter_track_ids = tracks.flat_map { |track| track[:chapter_track_ids] }.uniq
      tracks.each_with_object({}) do |track, result|
        next if chapter_track_ids.include?(track[:track_id])

        result[track[:track_id]] = [track[:handler], track[:samples]]
      end
    end

    def media_tracks_preserved?(expected, actual)
      expected.all? do |track_id, signature|
        actual.key?(track_id) && actual.fetch(track_id) == signature
      end
    end

    def track_media_signatures(path)
      ::File.open(path, 'rb') do |io|
        file_size = io.stat.size
        atoms = parse_mp4_atoms(io, 0, file_size)
        moov = atoms.find { |atom| atom[:type] == 'moov' }
        raise MdtaSaveError.new('moov atom is missing', phase: :verify) unless moov

        mdat_ranges = atoms.filter_map do |atom|
          next unless atom[:type] == 'mdat'

          [atom[:payload_offset], atom[:end_offset]]
        end
        moov[:children].filter_map do |atom|
          next unless atom[:type] == 'trak'

          handler = track_handler(io, atom)
          next unless MP4_TRACK_MEDIA_HANDLERS.include?(handler)

          track_id = track_id(io, atom)
          raise MdtaSaveError.new('track ID is missing', phase: :verify) unless track_id

          samples = track_sample_signature(io, atom, mdat_ranges)
          raise MdtaSaveError.new("unsupported #{handler} sample table", phase: :verify) unless samples

          {
            track_id: track_id,
            handler: handler,
            chapter_track_ids: chapter_track_ids(io, atom),
            samples: samples
          }
        end
      end
    end

    def parse_mp4_atoms(io, start_offset, end_offset)
      atoms = []
      offset = start_offset
      while offset < end_offset
        header = read_mp4_bytes(io, offset, 8)
        size32 = header.unpack1('N')
        type = header.byteslice(4, 4)
        header_size = 8
        size = size32
        if size32 == 1
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
        if MP4_ATOM_CONTAINERS.include?(type)
          atom[:children] = parse_mp4_atoms(io, atom[:payload_offset], atom[:end_offset])
        end
        atoms << atom
        offset += size
      end
      unless offset == end_offset
        raise MdtaSaveError.new('MP4 atom boundary mismatch while reading tracks', phase: :verify)
      end

      atoms
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

    def track_handler(io, trak)
      mdia = trak[:children].find { |atom| atom[:type] == 'mdia' }
      hdlr = mdia && mdia[:children].find { |atom| atom[:type] == 'hdlr' }
      return unless hdlr

      read_mp4_bytes(io, hdlr[:payload_offset] + 8, 4)
    end

    def track_id(io, trak)
      tkhd = trak[:children].find { |atom| atom[:type] == 'tkhd' }
      return unless tkhd

      version = read_mp4_bytes(io, tkhd[:payload_offset], 1).getbyte(0)
      read_mp4_uint32(io, tkhd[:payload_offset] + (version == 1 ? 20 : 12))
    end

    def chapter_track_ids(io, trak)
      tref = trak[:children].find { |atom| atom[:type] == 'tref' }
      chap = tref && tref[:children].find { |atom| atom[:type] == 'chap' }
      return [] unless chap

      payload_size = chap[:end_offset] - chap[:payload_offset]
      unless (payload_size % 4).zero?
        raise MdtaSaveError.new('invalid chapter track reference', phase: :verify)
      end

      Array.new(payload_size / 4) do |index|
        read_mp4_uint32(io, chap[:payload_offset] + index * 4)
      end
    end

    def track_sample_signature(io, trak, mdat_ranges)
      mdia = trak[:children].find { |atom| atom[:type] == 'mdia' }
      minf = mdia && mdia[:children].find { |atom| atom[:type] == 'minf' }
      stbl = minf && minf[:children].find { |atom| atom[:type] == 'stbl' }
      return nil unless stbl

      chunk_offsets = parse_chunk_offsets(io, stbl)
      sample_to_chunk = parse_sample_to_chunk(io, stbl)
      sample_sizes = parse_sample_sizes(io, stbl)
      return nil unless chunk_offsets && sample_to_chunk && sample_sizes

      digest = Digest::SHA256.new
      sample_index = 0
      sample_to_chunk_index = 0
      chunk_offsets.each_with_index do |chunk_offset, chunk_index|
        while sample_to_chunk_index + 1 < sample_to_chunk.length &&
              sample_to_chunk[sample_to_chunk_index + 1][:first_chunk] <= chunk_index + 1
          sample_to_chunk_index += 1
        end
        entry = sample_to_chunk[sample_to_chunk_index]
        raise MdtaSaveError.new('invalid sample-to-chunk table', phase: :verify) unless entry

        entry[:samples_per_chunk].times do
          break if sample_index >= sample_sizes.length

          size = sample_sizes.fetch(sample_index)
          unless media_range?(chunk_offset, size, mdat_ranges)
            raise MdtaSaveError.new('track sample is outside mdat', phase: :verify)
          end
          digest.update([size].pack('Q>'))
          append_sample_digest(io, digest, chunk_offset, size)
          chunk_offset += size
          sample_index += 1
        end
      end
      unless sample_index == sample_sizes.length
        raise MdtaSaveError.new('sample table count mismatch', phase: :verify)
      end

      [sample_index, digest.hexdigest]
    end

    def parse_chunk_offsets(io, stbl)
      atom = stbl[:children].find { |child| %w[stco co64].include?(child[:type]) }
      return unless atom

      count = read_mp4_uint32(io, atom[:payload_offset] + 4)
      width = atom[:type] == 'co64' ? 8 : 4
      Array.new(count) do |index|
        offset = atom[:payload_offset] + 8 + index * width
        width == 8 ? read_mp4_uint64(io, offset) : read_mp4_uint32(io, offset)
      end
    end

    def parse_sample_to_chunk(io, stbl)
      atom = stbl[:children].find { |child| child[:type] == 'stsc' }
      return unless atom

      count = read_mp4_uint32(io, atom[:payload_offset] + 4)
      Array.new(count) do |index|
        offset = atom[:payload_offset] + 8 + index * 12
        {
          first_chunk: read_mp4_uint32(io, offset),
          samples_per_chunk: read_mp4_uint32(io, offset + 4)
        }
      end
    end

    def parse_sample_sizes(io, stbl)
      atom = stbl[:children].find { |child| child[:type] == 'stsz' }
      if atom
        sample_size = read_mp4_uint32(io, atom[:payload_offset] + 4)
        count = read_mp4_uint32(io, atom[:payload_offset] + 8)
        return Array.new(count, sample_size) if sample_size.positive?

        return Array.new(count) do |index|
          read_mp4_uint32(io, atom[:payload_offset] + 12 + index * 4)
        end
      end

      atom = stbl[:children].find { |child| child[:type] == 'stz2' }
      return unless atom

      field_size = read_mp4_bytes(io, atom[:payload_offset] + 7, 1).getbyte(0)
      count = read_mp4_uint32(io, atom[:payload_offset] + 8)
      case field_size
      when 4
        bytes = read_mp4_bytes(io, atom[:payload_offset] + 12, (count + 1) / 2)
        Array.new(count) do |index|
          byte = bytes.getbyte(index / 2)
          index.even? ? byte >> 4 : byte & 0x0f
        end
      when 8
        read_mp4_bytes(io, atom[:payload_offset] + 12, count).bytes
      when 16
        Array.new(count) do |index|
          read_mp4_bytes(io, atom[:payload_offset] + 12 + index * 2, 2).unpack1('n')
        end
      else
        raise MdtaSaveError.new("unsupported stz2 field size: #{field_size}", phase: :verify)
      end
    end

    def media_range?(offset, size, mdat_ranges)
      mdat_ranges.any? { |start_offset, end_offset| offset >= start_offset && offset + size <= end_offset }
    end

    def append_sample_digest(io, digest, offset, size)
      io.seek(offset)
      remaining = size
      while remaining.positive?
        chunk = io.read([remaining, 1024 * 1024].min)
        if chunk.nil? || chunk.empty?
          raise MdtaSaveError.new('truncated sample while verifying media', phase: :verify)
        end

        digest.update(chunk)
        remaining -= chunk.bytesize
      end
    end

    def chapter_snapshot
      {
        nero: chapter_values_for(:nero),
        quicktime: chapter_values_for(:quicktime)
      }
    end

    def apply_chapter_change_to_native(chapters, style)
      if chapters.empty?
        _remove_chapters(chapter_style_code(style))
      else
        _set_chapters(chapters, chapter_style_code(style))
      end
    end

    def metadata_snapshot
      {
        items: tag.item_map.to_a.sort_by(&:first).map { |key, item| [key, item_snapshot(item)] },
        mdta: tag.mdta_items.map { |item| [item.key, item.key_index, item.data_type, item.locale, item.data] }
      }
    end

    def item_snapshot(item)
      case item.type
      when 1 then [:bool, item.to_bool]
      when 2 then [:int, item.to_int]
      when 3 then [:int_pair, item.to_int_pair]
      when 4 then [:byte, item.to_byte]
      when 5 then [:uint, item.to_uint]
      when 6 then [:long_long, item.to_long_long]
      when 7 then [:string_list, item.to_string_list]
      when 8 then [:byte_vector_list, item.to_byte_vector_list]
      when 9 then [:cover_art_list, item.to_cover_art_list.map { |art| [art.format, art.data] }]
      else [:unknown, item.type]
      end
    end

    def mdat_payload_signature(path)
      signatures = []
      ::File.open(path, 'rb') do |io|
        file_length = io.stat.size
        offset = 0
        while offset + 8 <= file_length
          io.seek(offset)
          header = io.read(8)
          size = header.unpack1('N')
          header_length = 8
          if size == 1
            extended = io.read(8)
            size = extended.unpack1('Q>')
            header_length = 16
          elsif size.zero?
            size = file_length - offset
          end
          raise MdtaSaveError.new('invalid MP4 atom while hashing media', phase: :verify) if size < header_length || offset + size > file_length

          if header.byteslice(4, 4) == 'mdat'
            digest = Digest::SHA256.new
            remaining = size - header_length
            while remaining.positive?
              chunk = io.read([remaining, 1024 * 1024].min)
              raise MdtaSaveError.new('truncated mdat while hashing media', phase: :verify) if chunk.nil? || chunk.empty?

              digest.update(chunk)
              remaining -= chunk.bytesize
            end
            signatures << [size - header_length, digest.hexdigest]
          end
          offset += size
        end
      end
      signatures
    end

    def chapter_style_code(style)
      CHAPTER_STYLE_CODES.fetch(style) do
        raise ArgumentError, "invalid chapter style: #{style.inspect}"
      end
    end

    def read_chapter_style_code(style)
      case style
      when :nero, :quicktime
        chapter_style_code(style)
      else
        raise ArgumentError, "invalid chapter read style: #{style.inspect}"
      end
    end

    def update_chapter_change(chapters, style)
      values = Array(chapters).dup.freeze
      @chapter_changes[:nero] = values if style == :nero || style == :both
      @chapter_changes[:quicktime] = values if style == :quicktime || style == :both
    end

    def chapter_values(style)
      return chapter_values_for(style) if style

      nero = chapter_values_for(:nero)
      quicktime = chapter_values_for(:quicktime)
      if !nero.empty? && !quicktime.empty? && nero != quicktime
        raise ChapterConflictError, 'Nero and QuickTime chapters differ'
      end
      (nero.empty? ? quicktime : nero).dup
    end

    def chapter_values_for(style)
      return @chapter_changes.fetch(style) if @chapter_changes.key?(style)

      _chapters(CHAPTER_STYLE_CODES.fetch(style))
    end

    def chapter_style_from_values
      nero = !chapter_values_for(:nero).empty?
      quicktime = !chapter_values_for(:quicktime).empty?
      return :both if nero && quicktime
      return :nero if nero
      return :quicktime if quicktime

      :none
    end
  end

  class Tag
    remove_method :save

    def ensure_mdta_support!
      return if respond_to?(:_mdta_items) && respond_to?(:_set_mdta_item) &&
                respond_to?(:_remove_mdta_item) && respond_to?(:_copy_state_to) &&
                respond_to?(:_apply_changes)

      raise MdtaItemError, 'patched TagLib with mdta support is required'
    end
    private :ensure_mdta_support!

    PROPERTY_ATOMS = {
      'title' => "©nam",
      'artist' => "©ART",
      'album' => "©alb",
      'genre' => "©gen",
      'comment' => "©cmt",
      'description' => 'desc',
      'longdesc' => 'ldes',
      'grouping' => "©grp",
      'TVShowName' => 'tvsh',
      'TVEpisode' => 'tven',
      'keyword' => 'keyw',
      'podcastURL' => 'purl',
      'year' => "©day",
      'purchaseDate' => 'purd',
      'contentRating' => '----:com.apple.iTunes:iTunEXTC'
    }.freeze

    CONTENT_RATING_PROPERTY = 'contentRating'
    MDTA_PROPERTY_KEYS = {
      'title' => 'title',
      'artist' => 'artist',
      'description' => 'description',
      'TVShowName' => 'show'
    }.freeze

    def property(name)
      values = property_values(name)
      values.first
    end

    def property_values(name)
      name = canonical_property_name(name)
      key = property_atom(name)
      item = item_map[key]
      if item
        values = item.to_string_list
        return values unless key == PROPERTY_ATOMS.fetch(CONTENT_RATING_PROPERTY)

        return values.map { |value| ContentRating.parse(value) }
      end

      mdta_key = MDTA_PROPERTY_KEYS[name]
      return [] unless mdta_key

      mdta_items.filter_map { |entry| entry.text if entry.key == mdta_key }
    end

    def properties
      PROPERTY_ATOMS.each_key.each_with_object({}) do |name, result|
        values = property_values(name)
        result[name] = values unless values.empty?
      end
    end

    def set_property(name, value)
      set_properties(name => value)
    end

    def set_properties(values)
      unless values.is_a?(Hash)
        raise ArgumentError, 'properties must be a Hash'
      end

      entries = {}
      values.each do |name, value|
        canonical_name = canonical_property_name(name)
        if entries.key?(canonical_name)
          raise ArgumentError, "duplicate MP4 property: #{canonical_name.inspect}"
        end
        entries[canonical_name] = [property_atom(canonical_name),
                                   validate_property_value(canonical_name, value)]
      end

      return self if entries.empty?

      set_items = ItemMap.new
      entries.each_value do |key, value|
        set_items.insert(key, Item.from_string_list([value]))
      end
      apply_property_changes(set_items, [], entries.keys)
    end

    def remove_property(name)
      canonical_name = canonical_property_name(name)
      atom = property_atom(canonical_name)
      apply_property_changes(ItemMap.new, [atom], [canonical_name])
    end

    def artwork
      item = item_map['covr']
      return [] unless item

      item.to_cover_art_list.map { |cover_art| Artwork.from_cover_art(cover_art) }
    end

    def set_artwork(images)
      images = Array(images)
      native_images = images.map do |image|
        unless image.is_a?(Artwork)
          raise ArgumentError, 'artwork must contain TagLib::MP4::Artwork values'
        end
        CoverArt.new(image.native_format, image.data)
      end

      if native_images.empty?
        remove_item('covr')
      else
        item_map.insert('covr', Item.from_cover_art_list(native_images))
      end
      self
    end

    def remove_artwork
      remove_item('covr')
      self
    end

    def mdta_items
      ensure_mdta_support!

      _mdta_items.map do |entry|
        MdtaItem.new(**entry.transform_keys(&:to_sym))
      end
    end

    def mdta_item(key)
      mdta_items.find { |entry| entry.key == normalize_mdta_key(key) }
    end

    def set_mdta_item(key, data, data_type: 1, locale: 0)
      ensure_mdta_support!

      key = normalize_mdta_key(key)
      validate_mdta_data!(data)
      data = data.dup.force_encoding(Encoding::BINARY)
      data_type = validate_mdta_integer!(data_type, 'data_type')
      locale = validate_mdta_integer!(locale, 'locale')
      unless _set_mdta_item(key, data_type, locale, data)
        raise MdtaItemError, "unknown mdta key: #{key.inspect}"
      end
      self
    end

    def remove_mdta_item(key)
      ensure_mdta_support!

      key = normalize_mdta_key(key)
      _remove_mdta_item(key)
      self
    end

    private

    def canonical_property_name(name)
      name = name.to_s
      name == 'show' ? 'TVShowName' : name
    end

    def apply_property_changes(set_items, remove_items, names)
      ensure_mdta_support!
      remove_mdta_keys = names.filter_map { |name| MDTA_PROPERTY_KEYS[name] }
      unless _apply_changes(set_items, remove_items, remove_mdta_keys)
        raise MdtaItemError, 'cannot normalize MP4 metadata safely'
      end
      self
    end

    def property_atom(name)
      name = canonical_property_name(name)

      PROPERTY_ATOMS.fetch(name) do
        raise ArgumentError, "unsupported MP4 property: #{name.inspect}"
      end
    end

    def normalize_mdta_key(key)
      raise MdtaItemError, 'mdta key must be a String' unless key.is_a?(String)
      raise MdtaItemError, 'mdta key must be valid UTF-8' unless key.encoding == Encoding::UTF_8 && key.valid_encoding?
      raise MdtaItemError, 'mdta key must not contain NUL bytes' if key.include?("\0")

      key
    end

    def validate_mdta_data!(data)
      raise MdtaItemError, 'mdta data must be a String' unless data.is_a?(String)
    end

    def validate_mdta_integer!(value, name)
      unless value.is_a?(Integer) && value >= 0 && value <= 0xffff_ffff
        raise MdtaItemError, "mdta #{name} must be an unsigned 32-bit Integer"
      end
      value
    end

    def validate_property_value(name, value)
      if canonical_property_name(name) == CONTENT_RATING_PROPERTY
        unless value.is_a?(ContentRating)
          raise ArgumentError, 'contentRating must be a TagLib::MP4::ContentRating'
        end
        return value.to_s
      end

      raise ArgumentError, "#{name} must be a String" unless value.is_a?(String)

      value = value.encode(Encoding::UTF_8)
      unless value.valid_encoding?
        raise ArgumentError, "#{name} must be a UTF-8 String"
      end
      raise ArgumentError, "#{name} must not contain NUL bytes" if value.include?("\0")

      value
    end
  end

  class Item
    def self.from_int_pair(ary)
      raise ArgumentError, 'argument should be an array' unless ary.is_a? Array
      raise ArgumentError, 'argument should have exactly two elements' if ary.length != 2

      new(*ary)
    end
  end

  class ItemMap
    alias clear _clear
    alias insert _insert
    alias [] fetch
    alias []= insert
    remove_method :_clear
    remove_method :_insert
  end
end
