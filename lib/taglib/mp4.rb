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
    end

    def chapters(style: nil)
      read_chapter_style_code(style) unless style.nil?
      if @chapter_state
        return chapter_state_chapters(style)
      end
      code = style.nil? ? CHAPTER_STYLE_CODES[:any] : CHAPTER_STYLE_CODES.fetch(style)
      _chapters(code)
    end

    def chapter_style
      return chapter_state_style if @chapter_state

      _chapter_style
    end

    def set_chapters(chapters, style: :preserve)
      ensure_chapter_state
      if style == :preserve
        style = chapter_style
        style = :both if style == :none
      end
      _set_chapters(chapters, chapter_style_code(style))
      update_chapter_state(chapters, style)
      self
    end

    def remove_chapters(style: :both)
      ensure_chapter_state
      if style == :preserve
        style = chapter_style
        style = :both if style == :none
      end
      _remove_chapters(chapter_style_code(style))
      update_chapter_state([], style)
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

      atomic_save(chapters_only: true)
    end

    alias save_without_chapter_state save
    private :save_without_chapter_state

    def save(*args)
      raise ArgumentError, 'save does not accept arguments' unless args.empty?

      atomic_save(chapters_only: false)
    end

    private

    def atomic_save(chapters_only:)
      source_path = name
      raise MdtaSaveError.new('MP4 file has no path', phase: :prepare) if source_path.nil? || source_path.empty?

      expected_metadata = metadata_snapshot
      source_mdat = mdat_payload_signature(source_path)
      temp_path = "#{source_path}.taglib-mdta-#{Process.pid}-#{object_id}"
      committed = false

      begin
        ::FileUtils.cp(source_path, temp_path)
        temporary = self.class.new(temp_path, false)
        begin
          if chapters_only
            apply_chapter_state_to(temporary)
            result = temporary.send(:save_without_chapter_state)
          else
            copy_tag_state_to(temporary)
            apply_chapter_state_to(temporary)
            result = temporary.send(:save_without_chapter_state)
          end
          raise MdtaSaveError.new('TagLib failed to save temporary MP4', phase: :taglib_save) unless result
        ensure
          temporary.close
        end

        verify_saved_copy(temp_path, expected_metadata, source_mdat, chapters_only)
        ::FileUtils.mv(temp_path, source_path)
        committed = true

        close
        begin
          initialize(source_path, false)
        rescue StandardError => error
          @mp4_invalid_after_commit = true
          raise MdtaSaveError.new("MP4 reopened failed after rename: #{error.message}",
                                  committed: true, phase: :reopen)
        end

        @chapter_state = nil
        @mp4_metadata_snapshot = metadata_snapshot
        true
      rescue MdtaSaveError
        raise
      rescue StandardError => error
        raise MdtaSaveError.new(error.message, committed: committed, phase: :replace)
      ensure
        ::FileUtils.rm_f(temp_path) unless committed
      end
    end

    def copy_tag_state_to(destination)
      if tag.respond_to?(:_copy_state_to)
        tag._copy_state_to(destination.tag)
        return
      end

      destination_map = destination.tag.item_map
      destination_map.clear
      tag.item_map.to_a.each do |key, item|
        destination_map.insert(key, item)
      end
    end

    def apply_chapter_state_to(destination)
      return unless @chapter_state

      @chapter_state.each do |style, chapters|
        destination.set_chapters(chapters, style: style)
      end
    end

    def verify_saved_copy(path, expected_metadata, source_mdat, chapters_only)
      verification = self.class.new(path, false)
      begin
        actual_metadata = verification.send(:metadata_snapshot)
        unless actual_metadata == expected_metadata
          raise MdtaSaveError.new('temporary MP4 metadata verification failed', phase: :verify)
        end
        actual_mdat = verification.send(:mdat_payload_signature, path)
        media_preserved = chapters_only ? mdat_payloads_preserved?(source_mdat, actual_mdat) : actual_mdat == source_mdat
        unless media_preserved
          raise MdtaSaveError.new('temporary MP4 media payload changed', phase: :verify)
        end
      ensure
        verification.close
      end
    end

    def metadata_dirty?
      metadata_snapshot != @mp4_metadata_snapshot
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

    def mdat_payloads_preserved?(original, saved)
      index = 0
      original.all? do |signature|
        index += 1 while index < saved.length && saved[index] != signature
        next false if index >= saved.length

        index += 1
        true
      end
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

    def ensure_chapter_state
      return if @chapter_state

      @chapter_state = {
        nero: _chapters(CHAPTER_STYLE_CODES[:nero]),
        quicktime: _chapters(CHAPTER_STYLE_CODES[:quicktime])
      }
    end

    def update_chapter_state(chapters, style)
      values = Array(chapters).dup.freeze
      @chapter_state[:nero] = values if style == :nero || style == :both
      @chapter_state[:quicktime] = values if style == :quicktime || style == :both
    end

    def chapter_state_style
      nero = !@chapter_state[:nero].empty?
      quicktime = !@chapter_state[:quicktime].empty?
      return :both if nero && quicktime
      return :nero if nero
      return :quicktime if quicktime

      :none
    end

    def chapter_state_chapters(style)
      return @chapter_state[:nero].dup if style == :nero
      return @chapter_state[:quicktime].dup if style == :quicktime

      nero = @chapter_state[:nero]
      quicktime = @chapter_state[:quicktime]
      if !nero.empty? && !quicktime.empty? && nero != quicktime
        raise ChapterConflictError, 'Nero and QuickTime chapters differ'
      end
      (nero.empty? ? quicktime : nero).dup
    end
  end

  class Tag
    remove_method :save

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
      'TVShowName' => 'show',
      'show' => 'show'
    }.freeze

    def property(name)
      values = property_values(name)
      values.first
    end

    def property_values(name)
      key = property_atom(name)
      item = item_map[key]
      if item
        values = item.to_string_list
        return values unless key == PROPERTY_ATOMS.fetch(CONTENT_RATING_PROPERTY)

        return values.map { |value| ContentRating.parse(value) }
      end

      mdta_key = MDTA_PROPERTY_KEYS[name.to_s]
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
      self
    end

    def set_properties(values)
      unless values.is_a?(Hash)
        raise ArgumentError, 'properties must be a Hash'
      end

      entries = values.map do |name, value|
        [property_atom(name), validate_property_value(name, value)]
      end
      entries.each do |key, value|
        item_map.insert(key, Item.from_string_list([value]))
      end
      self
    end

    def remove_property(name)
      item_map.erase(property_atom(name))
      self
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
      return [] unless respond_to?(:_mdta_items)

      _mdta_items.map do |entry|
        MdtaItem.new(**entry.transform_keys(&:to_sym))
      end
    end

    def mdta_item(key)
      mdta_items.find { |entry| entry.key == normalize_mdta_key(key) }
    end

    def set_mdta_item(key, data, data_type: 1, locale: 0)
      raise MdtaItemError, 'patched TagLib with mdta support is required' unless respond_to?(:_set_mdta_item)

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
      raise MdtaItemError, 'patched TagLib with mdta support is required' unless respond_to?(:_remove_mdta_item)

      key = normalize_mdta_key(key)
      _remove_mdta_item(key)
      self
    end

    private

    def property_atom(name)
      name = name.to_s
      return PROPERTY_ATOMS.fetch('TVShowName') if name == 'show'

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
      if name.to_s == CONTENT_RATING_PROPERTY
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
