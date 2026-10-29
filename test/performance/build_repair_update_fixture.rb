# frozen_string_literal: true

require 'fileutils'
require_relative '../support/mp4_investigation_fixture'

# 実mediaを持つfixtureへ、mdirと不正index付きmdta、および大きなmdatを合成する。
class RepairUpdateFixture
  include MP4InvestigationFixture

  def build(source, output, broken:)
    @dir = File.dirname(File.expand_path(output))
    FileUtils.cp(source, output)
    inject_metadata(output, keys: ['custom'], indices: broken ? [0, 1, 2] : [1])
    edit_fixture(output) do |moov|
      udta = fixture_child(moov, 'udta')
      mdta = fixture_child(udta, 'meta')
      title = fixture_child(mdta, 'ilst')[:children].pop
      handler = [0, 0].pack('N2') + 'mdir' + "\0".b * 13
      mdir = atom_box('meta', [0].pack('N') + atom_box('hdlr', handler) + atom_box('ilst', render_boxes([title])))
      udta[:children].unshift(parse_boxes(mdir).first)
    end
    File.open(output, 'ab') do |io|
      io.write([8 + 8 * 1024 * 1024].pack('N') + 'mdat')
      8.times { io.write("\0".b * (1024 * 1024)) }
    end
  end
end

RepairUpdateFixture.new.build(ARGV.fetch(0), ARGV.fetch(1), broken: ARGV[2] != 'healthy')
