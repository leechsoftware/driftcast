#!/bin/bash
# Builds a release of Driftcast and puts everything a release needs in Releases/<version>/:
#
#   Driftcast-<version>.dmg   what people download: the notarized app with an Applications shortcut
#   Driftcast-<version>.zip   what the app's own Check for Updates installs (it can only swap in a zip)
#   SHA256SUMS.txt            checksums of both
#
# The version is MARKETING_VERSION in the project and is changed by hand only. Check for Updates
# compares that number with the newest release's tag, so a release must be tagged with it
# (v1.0 for 1.0) and the number must go up for the app to offer the update.
#
# Signing and notarization use the team's cloud-managed Developer ID through Xcode
# (-allowProvisioningUpdates), so no certificate or notarytool profile is needed on this Mac.
# Usage: Scripts/make-release.sh            (from anywhere; takes several minutes)
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT=Driftcast.xcodeproj
VERSION=$(grep -m1 -E 'MARKETING_VERSION = ' "$PROJECT/project.pbxproj" | sed -E 's/.*= *([0-9.]+);.*/\1/')
[ -n "$VERSION" ] || { echo "no MARKETING_VERSION in the project" >&2; exit 1; }
OUT="Releases/$VERSION"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/driftcast-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/Driftcast.xcarchive"
EXPORT="$WORK/export"

[ -x Vendor/ffmpeg/ffmpeg ] || { echo "Vendor/ffmpeg is missing: run Scripts/bundle-ffmpeg.sh first" >&2; exit 1; }
mkdir -p "$OUT"
echo "== Driftcast $VERSION"

cat > "$WORK/export.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>CBAE6JXBHC</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict></plist>
PLIST

echo "== archiving (universal: Apple silicon and Intel)"
xcodebuild archive -project "$PROJECT" -scheme Driftcast -configuration Release \
    -archivePath "$ARCHIVE" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -allowProvisioningUpdates \
    2>&1 | grep -E 'error:|warning: .*(ffmpeg|Vendor)|ARCHIVE (SUCCEEDED|FAILED)' || true
[ -d "$ARCHIVE" ] || { echo "archive failed" >&2; exit 1; }

echo "== signing with the Developer ID and sending to Apple for notarization"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$WORK/export.plist" \
    -exportPath "$EXPORT" -allowProvisioningUpdates 2>&1 | grep -E 'error:|EXPORT (SUCCEEDED|FAILED)' || true

echo "== waiting for Apple's answer"
APP=""
for attempt in $(seq 1 40); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$EXPORT" >"$WORK/notarized.log" 2>&1; then
        APP="$EXPORT/Driftcast.app"; break
    fi
    if grep -q -i -E 'invalid|rejected' "$WORK/notarized.log"; then cat "$WORK/notarized.log" >&2; exit 1; fi
    sleep 30
done
[ -d "$APP" ] || { echo "notarization did not finish in time; last output:" >&2; cat "$WORK/notarized.log" >&2; exit 1; }

echo "== checking the notarized app"
xcrun stapler validate "$APP" | tail -1
codesign --verify --deep --strict "$APP" && echo "signature: valid"
spctl --assess --type execute "$APP" && echo "Gatekeeper: accepted"
BUILT=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
[ "$BUILT" = "$VERSION" ] || { echo "the app says $BUILT but the project says $VERSION" >&2; exit 1; }
lipo -archs "$APP/Contents/MacOS/Driftcast" | sed 's/^/architectures: /'
lipo -archs "$APP/Contents/Resources/ffmpeg/ffmpeg" | sed 's/^/ffmpeg architectures: /'

echo "== zip for Check for Updates"
rm -f "$OUT/Driftcast-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$OUT/Driftcast-$VERSION.zip"

echo "== disk image"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Driftcast.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/Driftcast-$VERSION.dmg"
hdiutil create -volname "Driftcast $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
    -ov "$OUT/Driftcast-$VERSION.dmg" | tail -1

(cd "$OUT" && shasum -a 256 "Driftcast-$VERSION.dmg" "Driftcast-$VERSION.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)
du -h "$OUT"/* | sed 's/^/  /'
echo "== done: $OUT"
echo "Next: tag v$VERSION and attach both files to the GitHub release (SHIPPING.md, section 2)."
