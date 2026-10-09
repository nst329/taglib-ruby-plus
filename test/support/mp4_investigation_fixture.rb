# frozen_string_literal: true

# 不正metadata・時間atomを合成fixtureへ注入する独立parser。製品parserは期待値生成に使わない。
module MP4InvestigationFixture
  CONTAINERS = %w[moov trak mdia minf stbl tref udta edts dinf meta ilst].freeze

  def atom_box(type, data)
    [data.bytesize + 8].pack('N') + type.b + data
  end

  # 例: {type: 'meta', prefix: fullboxの4 bytes, children: [...], extended: false}。
  # leafはdata、containerはchildrenを所有し、元のheader幅とfullbox prefixを保持する。
  def parse_boxes(bytes)
    offset, result = 0, []
    while offset < bytes.bytesize
      raise 'truncated fixture header' if bytes.bytesize - offset < 8
      size, type = bytes.byteslice(offset, 8).unpack('Na4')
      header = 8
      if size == 1
        raise 'truncated fixture extended header' if bytes.bytesize - offset < 16
        size = bytes.byteslice(offset + 8, 8).unpack1('Q>')
        header = 16
      elsif size.zero?
        size = bytes.bytesize - offset
      end
      raise 'invalid fixture boundary' if size < header || offset + size > bytes.bytesize
      data = bytes.byteslice(offset + header, size - header)
      node = { type: type, extended: header == 16, data: data }
      if CONTAINERS.include?(type)
        prefix_size = type == 'meta' ? 4 : 0
        raise 'truncated fixture fullbox' if data.bytesize < prefix_size
        node[:prefix] = data.byteslice(0, prefix_size)
        node[:children] = parse_boxes(data.byteslice(prefix_size..))
      end
      result << node
      offset += size
    end
    result
  end

  def render_boxes(nodes)
    nodes.map do |node|
      data = node[:children] ? node.fetch(:prefix, ''.b) + render_boxes(node[:children]) : node.fetch(:data)
      if node[:extended]
        [1].pack('N') + node[:type] + [data.bytesize + 16].pack('Q>') + data
      else
        atom_box(node[:type], data)
      end
    end.join.b
  end

  def fixture_child(node, type)
    node.fetch(:children).find { |child| child[:type] == type }
  end

  def each_fixture_atom(nodes, &block)
    nodes.each { |node| block.call(node); each_fixture_atom(node[:children], &block) if node[:children] }
  end

  # 大きい実mdatを読込まず、moovと原本境界だけを独立して取得する。
  def read_fixture_moov(path)
    ::File.open(path, 'rb') do |input|
      total = input.stat.size
      while input.pos < total
        start = input.pos
        header = input.read(8)
        raise 'truncated fixture root header' unless header && header.bytesize == 8
        size, type = header.unpack('Na4')
        if size == 1
          extension = input.read(8)
          raise 'truncated fixture root extension' unless extension && extension.bytesize == 8
          size = extension.unpack1('Q>')
          header += extension
        elsif size.zero?
          size = total - start
        end
        raise 'invalid fixture root boundary' if size < header.bytesize || start + size > total
        if type == 'moov'
          raise 'fixture moov exceeds limit' if size > 64 * 1024 * 1024
          return [parse_boxes(header + input.read(size - header.bytesize)).first, start, start + size]
        end
        input.seek(start + size)
      end
    end
    raise 'missing fixture moov'
  end

  # moovだけを編集し、位置補正後にmediaを逐次コピーする。実ファイルのコピーにも使える。
  def edit_fixture(path)
    unless @dir && ::File.realpath(path).start_with?(::File.realpath(@dir) + ::File::SEPARATOR)
      raise ArgumentError, 'fixture edits require a copy inside the test workdir'
    end
    moov, start, boundary = read_fixture_moov(path)
    yield moov
    delta = render_boxes([moov]).bytesize - (boundary - start)
    each_fixture_atom([moov]) do |node|
      next unless %w[stco co64].include?(node[:type])
      format = node[:type] == 'stco' ? 'N*' : 'Q>*'
      data = node.fetch(:data)
      offsets = data.byteslice(8..).unpack(format).map { |value| value >= boundary ? value + delta : value }
      node[:data] = data.byteslice(0, 8) + offsets.pack(format)
    end
    temporary = "#{path}.fixture-edit"
    raise 'fixture temporary path exists' if ::File.exist?(temporary)
    begin
      ::File.open(path, 'rb') do |input|
        ::File.open(temporary, 'wb', input.stat.mode & 0o777) do |output|
          IO.copy_stream(input, output, start)
          output.write(render_boxes([moov]))
          input.seek(boundary)
          IO.copy_stream(input, output)
        end
      end
      ::File.rename(temporary, path)
    ensure
      ::File.unlink(temporary) if ::File.exist?(temporary)
    end
  end

  def fixture_tracks(moov)
    moov.fetch(:children).select { |node| node[:type] == 'trak' }
  end

  def fixture_track_id(track)
    data = fixture_child(track, 'tkhd').fetch(:data)
    data.byteslice(data.getbyte(0) == 1 ? 20 : 12, 4).unpack1('N')
  end

  # keysとitemの対応を検証するため、index=0等も文字列キーへ推測変換せず注入する。
  def inject_metadata(path, keys:, indices:)
    data = indices.each_with_index.map do |index, position|
      atom_box([index].pack('N'), atom_box('data', [1, 0].pack('N2') + "opaque-#{position}".b))
    end.join.b
    regular = atom_box("\xa9nam".b, atom_box('data', [1, 0].pack('N2') + 'ordinary-title'.b))
    handler = [0, 0].pack('N2') + 'mdta' + "\0".b * 13
    key_table = [0, keys.size].pack('N2') + keys.map { |key| atom_box('mdta', key.b) }.join.b
    metadata = atom_box('meta', [0].pack('N') + atom_box('hdlr', handler) + atom_box('keys', key_table) + atom_box('ilst', data + regular))
    edit_fixture(path) do |moov|
      udta = fixture_child(moov, 'udta')
      unless udta
        udta = { type: 'udta', children: [] }
        moov[:children] << udta
      end
      udta[:children].reject! { |node| node[:type] == 'meta' }
      udta[:children].concat(parse_boxes(metadata))
    end
  end

  # 時間不整合だけを再現する。chapter samplesと表の件数は常に一致させる。
  def inject_chapter_timing(path, movie_scale:, movie_duration:, track_duration:, edit_rows:)
    edit_fixture(path) do |moov|
      movie = fixture_child(moov, 'mvhd')
      data = movie.fetch(:data)
      old_prefix = data.getbyte(0) == 1 ? 32 : 20
      movie[:data] = [0x01000000].pack('N') + [0, 0].pack('Q>2') + [movie_scale].pack('N') + [movie_duration].pack('Q>') + data.byteslice(old_prefix..)
      track = fixture_tracks(moov).find do |node|
        handler = fixture_child(fixture_child(node, 'mdia'), 'hdlr').fetch(:data)
        handler.byteslice(8, 4) == 'text'
      end
      header = fixture_child(track, 'tkhd')
      original = header.fetch(:data)
      flags = original.unpack1('N') & 0xffffff
      suffix = original.getbyte(0) == 1 ? 36 : 24
      fields = original.byteslice(original.getbyte(0) == 1 ? 20 : 12, 8)
      if track_duration > 0xffffffff
        header[:data] = [0x01000000 | flags].pack('N') + [0, 0].pack('Q>2') + fields + [track_duration].pack('Q>') + original.byteslice(suffix..)
      else
        header[:data] = [flags, 0, 0].pack('N3') + fields + [track_duration].pack('N') + original.byteslice(suffix..)
      end
      mdia = fixture_child(track, 'mdia')
      fixture_child(mdia, 'mdhd')[:data][12, 8] = [1000, 3_640_937].pack('N2')
      stbl = fixture_child(fixture_child(mdia, 'minf'), 'stbl')
      fixture_child(stbl, 'stts')[:data] = [0, 2, 15, 227_000, 1, 235_937].pack('N6')
      track[:children].reject! { |node| node[:type] == 'edts' }
      if edit_rows
        version = edit_rows.any? { |duration, _time, _rate| duration > 0xffffffff } ? 1 : 0
        format = version == 1 ? 'Q>q>l>' : 'Nl>l>'
        payload = [version << 24, edit_rows.size].pack('N2') + edit_rows.map { |row| row.pack(format) }.join.b
        track[:children] << { type: 'edts', children: [{ type: 'elst', data: payload }] }
      end
    end
  end
end
