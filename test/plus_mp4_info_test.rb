# frozen_string_literal: true

require_relative 'helper'
require_relative 'support/mp4_investigation_fixture'
require 'tmpdir'

# nativeやsample読取に依存しないheader契約を、独立生成したatomで検証する。
class PlusMP4InfoTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  setup do
    @dir = Dir.mktmpdir('plus-info-')
    @source = File.join(@dir, 'headers.mp4')
    movie = timing_header(0, 1000, 5000, 0, 10, 100)
    audio = track(7, 'soun', 'mp4a', 48000, 240000)
    chapter = track(42, 'text', 'text', 1000, 5000)
    File.binwrite(@source, atom_box('ftyp', 'isom' + [0].pack('N')) +
      atom_box('moov', atom_box('mvhd', movie) + audio + chapter))
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  def timing_header(version, scale, duration, created, modified, length)
    data = "\0".b * length
    data.setbyte(0, version)
    if version == 1
      data[4, 28] = [created, modified, scale, duration].pack('Q>Q>NQ>')
    else
      data[4, 16] = [created, modified, scale, duration].pack('N4')
    end
    data
  end

  # track IDは連番にせず、stream indexとの混同を検出する。
  def track(id, handler, fourcc, scale, duration, references: [], matrix: nil)
    tkhd = "\0".b * 84
    tkhd[0, 4] = [1].pack('N')
    tkhd[12, 4] = [id].pack('N')
    tkhd[20, 4] = [5000].pack('N')
    tkhd[40, 36] = (matrix || [65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30]).pack('l>9')
    tkhd[76, 8] = [1920 << 16, 1080 << 16].pack('N2')
    mdhd = timing_header(0, scale, duration, 0, 11, 24)
    mdhd[20, 2] = [((5 << 10) | (14 << 5) | 7)].pack('n')
    hdlr = [0, 0].pack('N2') + handler + "\0".b * 12 + "track #{id}\0"
    sample = "\0".b * (handler == 'soun' ? 28 : 78)
    sample[6, 2] = [1].pack('n')
    if handler == 'soun'
      sample[16, 2] = [2].pack('n')
      sample[24, 4] = [48000 << 16].pack('N')
    end
    stsd = atom_box('stsd', [0, 1].pack('N2') + atom_box(fourcc, sample))
    stsz = atom_box('stsz', [0, 0, 3].pack('N3')) # 宣言数のみ。sample表・payloadは意図的に不完全。
    tref = references.empty? ? ''.b : atom_box('tref', atom_box('chap', references.pack('N*')))
    mdia = atom_box('mdia', atom_box('mdhd', mdhd) + atom_box('hdlr', hdlr) + atom_box('minf', atom_box('stbl', stsd + stsz)))
    atom_box('trak', atom_box('tkhd', tkhd) + tref + mdia)
  end

  should 'read selective immutable headers without native sample hashing or external probes' do
    API.open(@source) do |file|
      file.define_singleton_method(:read_native) { |*_| raise 'native must not be opened' }
      info = file.info
      assert_equal %i[movie tracks], info.keys.sort
      assert_equal 1000, info[:movie][:timescale]
      assert_equal 5000, info[:movie][:duration_ticks]
      assert_equal [7, 42], info[:tracks].map { |t| t[:id] }
      audio = info[:tracks].first
      assert_equal 'soun', audio[:handler]
      assert_equal 'mp4a', audio[:sample_entries].first[:fourcc]
      assert_equal :audio, audio[:role][:value]
      assert_equal 48000, audio[:media_duration][:timescale]
      assert_equal 240000, audio[:media_duration][:ticks]
      assert_equal 5000, audio[:header_duration][:ticks]
      assert_equal 'eng', audio[:language][:code]
      assert_equal 'track 7', audio[:handler_name]
      assert_nil audio[:name]
      assert_equal true, audio[:enabled]
      assert_equal 48000, audio[:sample_entries].first[:sample_rate]
      assert_equal 2, audio[:sample_entries].first[:channels]
      assert_nil audio[:width]
      assert_nil audio[:height]
      assert_nil audio[:rotation_degrees]
      assert_equal :unknown, info[:tracks].last[:role][:status]
      assert info[:tracks].last[:role][:evidence].include?(:unreferenced_text)
      assert info.frozen?
      assert info[:tracks].first[:sample_entries].first.frozen?
      assert_same info, file.info
      assert_same info[:movie], file.info(sections: [:movie])[:movie]
      assert_equal [:movie], file.info(sections: [:movie]).keys
    end
  end

  should 'distinguish edit timeline media duration header duration and unset dates' do
    edit_fixture(@source) do |moov|
      audio = fixture_tracks(moov).first
      elst = atom_box('elst', [0, 2].pack('N2') + [1000, -1, 1, 0, 3000, 48000, 1, 0].pack('Nl>nnNl>nn'))
      audio[:children] << parse_boxes(atom_box('edts', elst)).first
    end
    API.open(@source) do |file|
      info = file.info
      audio = info[:tracks].first
      assert_equal({ ticks: 4000, timescale: 1000, source: :edit_list, status: :declared }, audio[:presentation_duration])
      assert_equal 5000, audio[:header_duration][:ticks]
      assert_equal 240000, audio[:media_duration][:ticks]
      assert_equal(-1, audio[:edits].first[:media_time])
      assert_equal 0, info[:movie][:creation_time][:raw]
      assert_equal :unset, info[:movie][:creation_time][:status]
      assert_equal '1904-01-01T00:00:00Z', info[:movie][:creation_time][:epoch]
      assert_equal 10, info[:movie][:modification_time][:raw]
    end
  end

  should 'report header chapter declarations without claiming sample verification' do
    edit_fixture(@source) do |moov|
      audio = fixture_tracks(moov).first
      audio[:children] << parse_boxes(atom_box('tref', atom_box('chap', [42].pack('N')))).first
      moov[:children] << parse_boxes(atom_box('udta', atom_box('chpl', [0x01000000, 0].pack('N2') + [2].pack('C')))).first
    end
    API.open(@source) do |file|
      file.define_singleton_method(:chapters) { raise 'heavy chapter getter' }
      file.define_singleton_method(:chapter_samples) { raise 'sample getter' }
      info = file.info(sections: [:tracks, :chapters])
      assert_equal [42], info[:tracks].first[:chapter_target_ids]
      assert_equal [7], info[:tracks].last[:chapter_source_ids]
      assert_equal :chapter, info[:tracks].last[:role][:value]
      assert_equal 2, info[:chapters][:nero][:count]
      assert_equal 3, info[:chapters][:quicktime][:count]
      assert_equal :declared, info[:chapters][:quicktime][:status]
    end
  end

  should 'preserve unknown codec fourcc and identify conflicting chapter roles as ambiguous' do
    edit_fixture(@source) do |moov|
      moov[:children] << parse_boxes(track(99, 'vide', 'zzzz', 1000, 5000, references: [7])).first
    end
    API.open(@source) do |file|
      tracks = file.info(sections: [:tracks])[:tracks]
      assert_equal :ambiguous, tracks.first[:role][:status]
      assert_nil tracks.first[:role][:value]
      assert_equal 'zzzz', tracks.last[:sample_entries].first[:fourcc]
      assert_not_include tracks.last[:sample_entries].first, :codec_name
    end
  end

  should 'read artwork descriptors without copying image payload' do
    image = atom_box('data', [13, 0].pack('N2') + "\xFF\xD8\xFF".b + 'x' * 10000)
    edit_fixture(@source) do |moov|
      meta = [0].pack('N') + atom_box('hdlr', [0, 0].pack('N2') + 'mdir' + "\0" * 12) + atom_box('ilst', atom_box('covr', image))
      moov[:children] << parse_boxes(atom_box('udta', atom_box('meta', meta))).first
    end
    API.open(@source) do |file|
      file.define_singleton_method(:metadata) { raise 'full metadata getter' }
      artwork = file.info(sections: [:artwork])[:artwork]
      assert_equal 10003, artwork.first[:bytesize]
      assert_equal 13, artwork.first[:data_type]
      assert_equal :jpeg, artwork.first[:format]
      assert_not_include artwork.first, :data
    end
  end

  should 'retain 64 bit timing dates and unknown duration sentinels without truncation' do
    edit_fixture(@source) do |moov|
      fixture_child(moov, 'mvhd')[:data] = timing_header(1, 1000, 0xffff_ffff_ffff_ffff, 0x1_0000_0010, 0, 112)
      mdhd = fixture_child(fixture_child(fixture_tracks(moov).first, 'mdia'), 'mdhd')
      mdhd[:data] = timing_header(1, 48000, 0x1_0000_0007, 0, 0x1_0000_0020, 36)
      mdhd[:data][32, 2] = [0x7fff].pack('n')
    end
    API.open(@source) do |file|
      info = file.info
      assert_nil info[:movie][:duration_ticks]
      assert_equal 0xffff_ffff_ffff_ffff, info[:movie][:raw_duration]
      assert_equal 0x1_0000_0010, info[:movie][:creation_time][:raw]
      assert_equal :unset, info[:movie][:modification_time][:status]
      assert_equal 0x1_0000_0007, info[:tracks].first[:media_duration][:ticks]
      assert_nil info[:tracks].first[:language][:code]
      assert_equal 0x7fff, info[:tracks].first[:language][:raw]
    end
  end

  should 'distinguish track names from handler names and retain canonical rotation matrices' do
    edit_fixture(@source) do |moov|
      visual = parse_boxes(track(99, 'vide', 'zzzz', 1000, 5000,
        matrix: [0, 65536, 0, -65536, 0, 0, 0, 0, 1 << 30])).first
      visual[:children] << parse_boxes(atom_box('udta', atom_box('name', '映像の名前'))).first
      moov[:children] << visual
    end
    API.open(@source) do |file|
      visual = file.info[:tracks].last
      assert_equal '映像の名前', visual[:name]
      assert_equal 'track 99', visual[:handler_name]
      assert_equal :udta_name, visual[:track_name][:source]
      assert_equal 1920, visual[:width]
      assert_equal 1080, visual[:height]
      assert_equal 90, visual[:rotation_degrees]
      assert_equal :canonical, visual[:rotation_status]
    end
  end

  should 'reject malformed header boundaries and unsupported versions explicitly' do
    API.open(@source) do |file|
      assert_raise(ArgumentError) { file.info(sections: [:samples]) }
      assert_raise(ArgumentError) { file.info(sections: [:movie, :movie]) }
    end
    edit_fixture(@source) { |moov| fixture_child(moov, 'mvhd')[:data].setbyte(0, 2) }
    API.open(@source) do |file|
      error = assert_raise(API::Error) { file.info(sections: [:movie]) }
      assert_equal :unsupported, error.code
      assert_equal :info, error.area
    end
  end

  should 'reject cached header information after source replacement and after close' do
    file = API.open(@source)
    file.info
    replacement = File.join(@dir, 'replacement.mp4')
    FileUtils.cp(@source, replacement)
    File.rename(replacement, @source)
    assert_equal :source_changed, assert_raise(API::Error) { file.info }.code
    file.close
    assert_equal :closed, assert_raise(API::Error) { file.info }.code
  end
end
