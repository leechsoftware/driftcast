#!/bin/bash
# Builds the test media (needs ffmpeg) and runs the logic harness over the app's non-UI sources.
# The harness exercises probing, planning, the HTTP server, VOD HLS sessions (AVPlayer plays them),
# HDR tone mapping, OCR of PGS subtitles, and the library model.
#
# Usage: Tests/run-harness.sh [arm64|x86_64]
# With x86_64 on Apple silicon the harness and ffmpeg's Intel slice run under Rosetta.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
OUT="${TMPDIR:-/tmp}/driftcast-harness-$ARCH"
mkdir -p "$OUT/media"
cd "$OUT/media"
# The ffmpeg the app ships, when it has been fetched; else whatever is installed.
if [ -x "$ROOT/Vendor/ffmpeg/ffmpeg" ]; then
    export DRIFTCAST_FFMPEG_DIR="$ROOT/Vendor/ffmpeg"
    ffmpeg() { arch "-$ARCH" "$ROOT/Vendor/ffmpeg/ffmpeg" "$@"; }
fi
cp "$ROOT/Tests/Media/movie.srt" .
cp movie.srt "Test.Movie.2024.1080p.en.srt"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1920x1080:rate=24 -f lavfi -i "sine=frequency=440:sample_rate=48000" -i movie.srt -t 40 \
  -filter_complex "[1:a]pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0,asplit=2[a6][b6]" -map 0:v -map "[a6]" -map "[b6]" -map 2:s \
  -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -x265-params log-level=error -c:a:0 ac3 -c:a:1 dca -strict -2 -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=ger -metadata:s:s:0 language=eng "Test.Movie.2024.1080p.mkv"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=1280x720:rate=30 -f lavfi -i "sine=frequency=660" -t 30 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart simple.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=24" -t 4 -pix_fmt yuv420p10le -c:v libx265 \
  -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" hdr.mkv
swiftc -O -target "$(uname -m)-apple-macos13" -o "$OUT/makesup" "$ROOT/Tests/makesup.swift"
"$OUT/makesup" test.sup
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=24" -f lavfi -i "sine=frequency=440" -i test.sup -t 20 -map 0:v -map 1:a -map 2:s -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -c:s copy -metadata:s:s:0 language=eng pgs.mkv
# A real, signed release to test the self-updater's checks against, when this Mac has one.
if [ -f "$HOME/Downloads/Driftcast.zip" ]; then export DRIFTCAST_RELEASE_ZIP="$HOME/Downloads/Driftcast.zip"; fi
# Sources the encoding checks need: a clock that doesn't start at zero, interlaced, rotated,
# 96 kHz, a raw stream with no duration, Motion JPEG, and a long file for the pacing check.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=440 -t 32 -c:v libx264 -preset ultrafast -g 100 -pix_fmt yuv420p -c:a aac -output_ts_offset 3000 -f mpegts offset.ts
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1920x1080:rate=25 -t 6 -vf tinterlace=interleave_top,fieldorder=tff -c:v libx264 -flags +ilme+ildct -x264-params tff=1 -preset ultrafast -pix_fmt yuv420p -f mpegts interlaced.ts
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 4 -c:v libx264 -preset ultrafast -pix_fmt yuv420p base.mp4
ffmpeg -hide_banner -loglevel error -y -display_rotation 90 -i base.mp4 -c copy rotated.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i "sine=frequency=440:sample_rate=96000" -t 4 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a pcm_s24le hires.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=25 -t 8 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -f h264 raw.h264
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x480:rate=24 -t 3 -c:v mjpeg -q:v 4 -pix_fmt yuvj420p camera.avi
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=10 -t 1500 -c:v libx264 -preset ultrafast -g 40 -keyint_min 40 -sc_threshold 0 -pix_fmt yuv420p long.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=24 -t 12 -c:v libx264 -preset ultrafast -pix_fmt yuv444p sdr444.mkv
cd "$ROOT/Driftcast"
cp "$ROOT/Tests/harness.swift" "$OUT/main.swift"   # top-level code must live in main.swift
swiftc -swift-version 5 -O -target "$ARCH-apple-macos13" -framework SwiftUI -o "$OUT/run" "$OUT/main.swift" Model/*.swift Media/*.swift Network/*.swift Cast/*.swift Playback/*.swift Subtitles/*.swift Subtitles/OCR/*.swift
# A private home folder keeps the harness away from the real library and settings.
mkdir -p "$OUT/home"
CFFIXED_USER_HOME="$OUT/home" arch "-$ARCH" "$OUT/run" "$OUT/media"
