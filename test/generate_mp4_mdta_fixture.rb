#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate the same kind of fixture as h265-conv.sh without making FFmpeg a
# taglib-ruby runtime dependency. Set FFMPEG to the executable to use.

require "open3"

output = ARGV.fetch(0) do
  abort "usage: #{File.basename($PROGRAM_NAME)} OUTPUT.mp4"
end
ffmpeg = ENV.fetch("FFMPEG", "/Users/nasu/Bin/ffmpeg")

command = [
  ffmpeg,
  "-v", "error",
  "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=1",
  "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
  "-t", "1",
  "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error",
  "-c:a", "aac",
  "-metadata", "title=MDTA Title",
  "-metadata", "show=MDTA Show",
  "-metadata", "artist=MDTA Artist",
  "-metadata", "description=MDTA Description",
  "-metadata", "audio_normalization=loudnorm",
  "-metadata", "audio_normalization_target=-16-LUFS",
  "-movflags", "+faststart+use_metadata_tags",
  output
]

_stdout, stderr, status = Open3.capture3(*command)
abort stderr unless status.success?
puts output
