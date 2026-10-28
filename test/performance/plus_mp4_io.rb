# frozen_string_literal: true

# 実行例はDocsのI/O性能検証記録を参照。製品の公開入口だけで操作を計測する。
require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'fiddle/import'
$LOAD_PATH.unshift(ENV.fetch('PLUS_BINDING_LIB', File.expand_path('../../lib', __dir__)))
require 'taglib_plus'

# 計測用の内部フック。操作本体はPlus.open以下の公開APIだけを使う。
module NativeSourceCounter
  def open(path, *args, **options, &block)
    $native_source_opens += 1 if $measuring && File.expand_path(path) == $metric_source
    super
  end
end
TagLib::MP4::Internal::File.singleton_class.prepend(NativeSourceCounter)
module ExternalProcessCounter
  def spawn(*args, **options)
    $external_processes += 1 if $measuring
    super
  end
end
Process.singleton_class.prepend(ExternalProcessCounter)

module Meter
  extend Fiddle::Importer
  dlload ENV.fetch('PLUS_IO_METER')
  extern 'void plus_meter_start()'
  extern 'void plus_meter_stop()'
  extern 'unsigned long long plus_meter_read()'
  extern 'unsigned long long plus_meter_write()'
  extern 'unsigned long long plus_meter_peak()'
end

# SHA.fileと共有streamの全体hash、媒体を出力するコピー経路を補助計測する。
module HashCounter
  def file(path, *args)
    $whole_hashes += 1 if $measuring
    super
  end
end
Digest::SHA256.singleton_class.prepend(HashCounter)
module CopyCounter
  def cp(source, *args, **options)
    $whole_copies += 1 if $measuring && File.size(source) >= $media_size_floor
    super
  end
end
FileUtils.singleton_class.prepend(CopyCounter)
module AtomCopyCounter
  def write_copy(source, destination, &copy)
    $whole_copies += 1 if $measuring && !copy && File.size(source) >= $media_size_floor
    super
  end
end
TagLib::MP4::ChapterReferenceRepair.prepend(AtomCopyCounter)
if TagLib::Plus::MP4.const_defined?(:Stream, false)
  module StreamCounter
    def scan(path, **options)
      if $measuring
        $whole_hashes += 1
        $whole_copies += 1 if options[:destination]
      end
      super
    end
  end
  TagLib::Plus::MP4.const_get(:Stream, false).singleton_class.prepend(StreamCounter)
end

api = TagLib::Plus::MP4
source_fixture = ARGV.fetch(0)
operation = ARGV.fetch(1)
work = ENV.fetch('PLUS_IO_DIRECTORY')
FileUtils.mkdir_p(work)
source = File.join(work, 'source.mp4')
FileUtils.cp(source_fixture, source)
$metric_source = File.realpath(source)
$native_source_opens = $external_processes = 0
$artwork_objects = $artwork_retained_bytes = nil
$media_size_floor = File.size(source_fixture) * 0.8
$whole_hashes = $whole_copies = 0
failure = nil
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Meter.plus_meter_start unless ENV['PLUS_IO_UNMETERED']
$measuring = true
begin
  api.open(source) do |file|
    case operation
    when 'structural_reads'
      2.times do
        %i[chapters chapter_references chapter_timing color].each { |area| file.diagnose(area) }
        file.read_chapters(style: :nero)
        file.read_chapters(style: :quicktime)
        file.chapter_samples
      end
    when 'cached_snapshots'
      file.metadata
      file.chapters
      2.times { file.save!(snapshots: [:metadata, :chapters]) }
    when 'info_movie' then 2.times { file.info(sections: [:movie]) }
    when 'info_tracks' then 2.times { file.info }
    when 'info_all' then 2.times { file.info(sections: [:movie, :tracks, :chapters, :artwork]) }
    when 'chapters_shared' then file.chapters; file.diagnose(:chapters); 2.times { file.chapter_samples }
    when 'artwork_edit'
      original = file.metadata
      values = [original.item('covr')&.value&.first&.last].compact
      10.times do |index|
        original = original.with(properties: { title: "title #{index}" }).without(properties: [:comment])
        values << original.item('covr').value.first.last if original.item('covr')
      end
      unique = values.uniq(&:object_id)
      $artwork_objects, $artwork_retained_bytes = unique.size, unique.sum(&:bytesize)
    when 'stage_verified'
      file.metadata = api::MetadataSnapshot.new(items: [api::MetadataItem.new(key: '©nam', kind: :string_list,
        atom_data_type: 255, value: ['stage'])])
      output = File.join(work, 'output.mp4')
      result = file.save!(to: output)
      actual = result[:snapshots]&.fetch(:metadata) || api.open(output) { |copy| copy.metadata }
      2.times { actual.properties[:title] }
    when 'observation_metadata' then 2.times { file.observation(:metadata) }
    when 'observation_chapters' then 2.times { file.observation(:chapters) }
    when 'observation_metadata_chapters' then 2.times { file.observation(%i[metadata chapters]) }
    when 'read' then 2.times { file.metadata; file.chapters }
    when 'property' then 2.times { file.metadata.properties.key?(:title) }
    when 'diagnose' then 2.times { file.diagnose(:metadata); file.diagnose(:chapter_references) }
    when 'noop' then file.save!
    when 'copy' then file.save!(to: File.join(work, 'output.mp4'))
    when 'item', 'mdta', 'replace', 'combined'
      file.metadata = case operation
                      when 'mdta' then file.metadata.with(mdta: { 'custom' => [api::MdtaValue.new(data_type: 1, locale: 7, data: 'value')] })
                      when 'replace' then api::MetadataSnapshot.new(items: [api::MetadataItem.new(key: '©nam', kind: :string_list, atom_data_type: 255, value: ['replacement'])])
                      else file.metadata.with(properties: { title: 'updated' })
                      end
      if operation == 'combined'
        file.metadata = file.metadata.with(mdta: { 'custom' => [api::MdtaValue.new(data_type: 1, locale: 7, data: 'value')] })
        file.chapters = file.chapters.with(nero: [api::Chapter.new(start_ms: 0, title: 'chapter')])
      end
      file.save!
      file.metadata
    else raise ArgumentError, operation
    end
  end
rescue StandardError => error
  failure = "#{error.class}: #{error.message}"
ensure
  $measuring = false
  Meter.plus_meter_stop
end
puts JSON.generate(operation: operation, size: File.size(source_fixture),
  read_bytes: Meter.plus_meter_read, write_bytes: Meter.plus_meter_write,
  whole_hash_passes: $whole_hashes, whole_media_copies: $whole_copies,
  temporary_peak_bytes: Meter.plus_meter_peak,
  native_source_opens: $native_source_opens, external_process_calls: $external_processes,
  artwork_byte_objects: $artwork_objects, artwork_retained_string_bytes: $artwork_retained_bytes,
  elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, error: failure)
