#!/bin/bash
# Fetches the static ffmpeg and ffprobe builds Driftcast ships, one for Apple silicon and one for
# Intel, checks them against the checksums below, and merges each pair into a universal program
# in Vendor/ffmpeg/. Xcode's "Bundle ffmpeg" build phase copies that folder into
# Contents/Resources/ffmpeg and re-signs it with the app's identity.
#
# Static on purpose: the programs need nothing but the system, and both slices run on macOS 12
# and later. (Homebrew's bottles are built for the macOS they were bottled on, so a copy taken
# from a new Mac won't run on older ones.) To change version, update the folders and checksums
# from https://ffmpeg.martin-riedl.de and the table in NOTICE.md.
#
# Licensing: these builds are GPL v3 or later. The licence texts travel with the programs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/ffmpeg"
VERSION=9.0.2
BASE=https://ffmpeg.martin-riedl.de/download/macos
ARM64=arm64/1789931890_$VERSION
INTEL=amd64/1789931006_$VERSION
ARM64_FFMPEG=c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924
ARM64_FFPROBE=fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6
INTEL_FFMPEG=7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4
INTEL_FFPROBE=2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # <folder> <program> <sha256> <destination directory>
    local zip="$WORK/$(basename "$4")-$2.zip"
    curl -fsSL -o "$zip" "$BASE/$1/$2.zip"
    echo "$3  $zip" | shasum -a 256 -c - >/dev/null
    mkdir -p "$4"
    unzip -q -o "$zip" "$2" -d "$4"
}

fetch "$ARM64" ffmpeg  "$ARM64_FFMPEG"  "$WORK/arm64"
fetch "$ARM64" ffprobe "$ARM64_FFPROBE" "$WORK/arm64"
fetch "$INTEL" ffmpeg  "$INTEL_FFMPEG"  "$WORK/intel"
fetch "$INTEL" ffprobe "$INTEL_FFPROBE" "$WORK/intel"

rm -rf "$OUT"
mkdir -p "$OUT"
for tool in ffmpeg ffprobe; do
    lipo -create "$WORK/arm64/$tool" "$WORK/intel/$tool" -output "$OUT/$tool"
    chmod 755 "$OUT/$tool"
    xattr -c "$OUT/$tool"
    codesign --force --sign - "$OUT/$tool"
done

for licence in LICENSE.md COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3; do
    curl -fsSL -o "$OUT/$licence" "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n$VERSION/$licence"
done

"$OUT/ffmpeg" -hide_banner -version | head -1
lipo -archs "$OUT/ffmpeg"
du -sh "$OUT"
