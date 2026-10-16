# frozen_string_literal: true

require_relative 'helper'
require 'tmpdir'
require 'fileutils'
require_relative 'support/mp4_investigation_fixture'

class PlusMP4StructureTest < Test::Unit::TestCase
  include MP4InvestigationFixture
  API = TagLib::Plus::MP4

  setup do
    @dir = Dir.mktmpdir('plus-structure-')
    @source = File.join(@dir, 'source.m4a')
    FileUtils.cp('test/data/mp4.m4a', @source)
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  should 'report a normal MP4 with no structure issues' do
    report = API.open(@source) { |file| file.diagnose(:structure) }

    assert_equal :complete, report[:status]
    assert_empty report[:issues]
    assert_equal 1, report[:data][:tracks].size
    assert_equal 'soun', report[:data][:tracks].first[:handler]
    assert_equal :complete, report[:data][:coverage].find { |row| row[:check] == :chunk_offsets }[:status]
  end

  should 'summarize invalid stco entries without reading or rewriting media bytes' do
    edit_fixture(@source) do |moov|
      stco = fixture_child(fixture_child(fixture_child(fixture_child(moov, 'trak'), 'mdia'), 'minf'), 'stbl')
      stco = fixture_child(stco, 'stco')
      stco[:data][8, 4] = [File.size(@source) + 100].pack('N')
    end

    diagnosed_bytes = File.binread(@source)
    diagnosed_stat = File.stat(@source)
    report = API.open(@source) { |file| file.diagnose(:structure) }
    issue = report[:issues].find { |row| row[:code] == :chunk_offset_outside_mdat }
    table = issue[:details][:tracks].first[:tables].first

    assert_equal :malformed, report[:status]
    assert_equal 'soun', issue[:details][:tracks].first[:handler]
    assert_equal 'stco', table[:type]
    assert_equal 1, table[:declared_count]
    assert_equal 1, table[:invalid_count]
    assert_equal 0, table[:first_invalid][:index]
    assert_equal table[:first_invalid], table[:last_invalid]
    assert_operator table[:first_invalid][:offset], :>, issue[:details][:file_size]
    assert_equal diagnosed_bytes, File.binread(@source)
    assert_equal diagnosed_stat.size, File.size(@source)
    assert_equal diagnosed_stat.mtime, File.stat(@source).mtime
  end

  should 'diagnose co64 using the same details schema' do
    edit_fixture(@source) do |moov|
      stco = fixture_child(fixture_child(fixture_child(fixture_child(moov, 'trak'), 'mdia'), 'minf'), 'stbl')
      table = fixture_child(stco, 'stco')
      value = table[:data].byteslice(8, 4).unpack1('N')
      table[:type] = 'co64'
      table[:data] = table[:data].byteslice(0, 8) + [value].pack('Q>')
    end

    report = API.open(@source) { |file| file.diagnose(:structure) }
    table = report[:data][:tracks].first[:tables].first
    assert_equal :complete, report[:status]
    assert_equal 'co64', table[:type]
    assert_equal 1, table[:declared_count]
    assert_empty report[:issues]
  end

  should 'report an out of range co64 offset' do
    edit_fixture(@source) do |moov|
      stbl = fixture_child(fixture_child(fixture_child(fixture_child(moov, 'trak'), 'mdia'), 'minf'), 'stbl')
      table = fixture_child(stbl, 'stco')
      table[:type] = 'co64'
      table[:data] = table[:data].byteslice(0, 8) + [File.size(@source) + 100].pack('Q>')
    end

    report = API.open(@source) { |file| file.diagnose(:structure) }
    issue = report[:issues].find { |row| row[:code] == :chunk_offset_outside_mdat }

    assert_equal :malformed, report[:status]
    assert_equal 'co64', issue[:details][:tracks].first[:tables].first[:type]
    assert_equal 1, issue[:details][:tracks].first[:tables].first[:invalid_count]
  end

  should 'report invalid entries separately for multiple tracks' do
    edit_fixture(@source) do |moov|
      original = moov[:children].find { |node| node[:type] == 'trak' }
      duplicate = Marshal.load(Marshal.dump(original))
      tkhd = fixture_child(duplicate, 'tkhd')
      tkhd[:data][12, 4] = [2].pack('N')
      moov[:children] << duplicate
      moov[:children].select { |node| node[:type] == 'trak' }.each do |track|
        stbl = fixture_child(fixture_child(fixture_child(track, 'mdia'), 'minf'), 'stbl')
        fixture_child(stbl, 'stco')[:data][8, 4] = [File.size(@source) + 100].pack('N')
      end
    end

    report = API.open(@source) { |file| file.diagnose(:structure) }
    issues = report[:issues].select { |row| row[:code] == :chunk_offset_outside_mdat }
    assert_equal [1, 2], report[:data][:tracks].map { |track| track[:track_id] }
    assert_equal [1, 2], issues.map { |row| row[:details][:tracks].first[:track_id] }
  end

  should 'keep the source bytes, size, and mtime unchanged' do
    digest = Digest::SHA256.file(@source)
    stat = File.stat(@source)
    API.open(@source) { |file| file.diagnose(:structure) }
    after = File.stat(@source)

    assert_equal digest, Digest::SHA256.file(@source)
    assert_equal stat.size, after.size
    assert_equal stat.mtime, after.mtime
  end

  should 'advance a valid stsc mapping once as chunk numbers increase' do
    diagnostics = TagLib::Plus::MP4::StructureDiagnostics.allocate
    mapping = [[1, 2, 1], [4, 3, 1], [7, 1, 1]]
    cursor = diagnostics.send(:chunk_mapping_cursor, mapping)

    assert_equal [2, 2, 2, 3, 3, 3, 1, 1], (1..8).map do |chunk_number|
      diagnostics.send(:samples_per_chunk, mapping, chunk_number, cursor)
    end
    assert_equal mapping.length - 1, cursor[:index]
  end

  should 'keep the old result for one-row, delayed, and malformed stsc mappings' do
    diagnostics = TagLib::Plus::MP4::StructureDiagnostics.allocate
    one_row = [[1, 4, 1]]
    delayed = [[3, 2, 1]]
    malformed = [[3, 2, 1], [1, 5, 1]]

    assert_equal [4, 4, 4], (1..3).map do |chunk_number|
      diagnostics.send(:samples_per_chunk, one_row, chunk_number, diagnostics.send(:chunk_mapping_cursor, one_row))
    end
    delayed_cursor = diagnostics.send(:chunk_mapping_cursor, delayed)
    assert_equal [nil, nil, 2, 2], (1..4).map do |chunk_number|
      diagnostics.send(:samples_per_chunk, delayed, chunk_number, delayed_cursor)
    end
    malformed_cursor = diagnostics.send(:chunk_mapping_cursor, malformed)
    assert_equal [5, 5, 5], (1..3).map do |chunk_number|
      diagnostics.send(:samples_per_chunk, malformed, chunk_number, malformed_cursor)
    end
    assert_nil diagnostics.send(:samples_per_chunk, nil, 1)
    assert_nil diagnostics.send(:samples_per_chunk, [], 1)
  end

  should 'handle a large stsc mapping without repeated reverse scans' do
    diagnostics = TagLib::Plus::MP4::StructureDiagnostics.allocate
    mapping = (1..90_000).map { |first_chunk| [first_chunk, 1, 1] }
    cursor = diagnostics.send(:chunk_mapping_cursor, mapping)

    (1..108_741).each do |chunk_number|
      assert_equal 1, diagnostics.send(:samples_per_chunk, mapping, chunk_number, cursor)
    end

    assert_equal mapping.length - 1, cursor[:index]
  end

  should 'return a boundary issue instead of raising for a truncated root atom' do
    File.open(@source, 'r+b') { |io| io.write([File.size(@source) + 1].pack('N')) }

    report = API.open(@source) { |file| file.diagnose(:structure) }

    assert_equal :malformed, report[:status]
    assert_include report[:issues].map { |issue| issue[:code] }, :atom_outside_parent
    assert_include report[:issues].map { |issue| issue[:code] }, :required_atom_missing
  end
end
