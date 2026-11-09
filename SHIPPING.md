# Shipping Driftcast

What's wired in, and the few things only you can do before a release.

## 1. ffmpeg is bundled

`Scripts/bundle-ffmpeg.sh` downloads the static `ffmpeg` and `ffprobe` builds for Apple silicon
and Intel from <https://ffmpeg.martin-riedl.de>, checks them against the SHA-256 sums pinned in
the script, merges each pair with `lipo` and puts the result in `Vendor/ffmpeg/` (about 310 MB,
git-ignored) with FFmpeg's licence texts. The "Bundle ffmpeg" build phase copies that folder into
`Contents/Resources/ffmpeg/` and re-signs it with the app's identity and the hardened runtime.
The app looks there first, then Homebrew.

Both slices need macOS 12 or later and nothing outside the system. Don't bundle Homebrew's
ffmpeg instead: its bottles are built for the macOS they were bottled on (26 at the time of
writing), so a copy taken from a new Mac won't run on older ones.

To change version, update the folder names and checksums at the top of the script, re-run it,
and update the table in `NOTICE.md`. If `Vendor/ffmpeg` is missing the build still succeeds with
a warning and the app shows a "media engine missing" banner.

Build Release with `ARCHS="arm64 x86_64"` (Xcode's default for Release) so the app itself is
universal. The app skips any ffmpeg that lacks a slice for the running CPU rather than failing.
The app needs macOS 13 or later regardless of CPU.

Licensing: the bundled FFmpeg includes x264 and x265, so it's GPL. The licence texts are copied next
to the binaries. `LICENSE` (GPL v3) and `NOTICE.md` are copied into the app as `Resources/Licenses/` by the same
build phase and open from the About window. The app runs ffmpeg as a separate executable (it is not linked in). A GPL ffmpeg is not
allowed on the Mac App Store; an App Store build needs an LGPL-only build such as
`superuser404notfound/FFmpegBuild`.

## 2. Updates (GitHub releases)

The app looks at the newest release of its GitHub repository at launch and every eight hours
while running (`Updater`, `GitHubReleases` in `Model/AppUpdate.swift`). When the release's tag
is a higher version than the app's own, a dialog offers Update Now, Remind Me Later and
Skip This Version. Update Now downloads the release's `.zip`, checks that the app inside is
signed with the Leech Software Developer ID (`UpdateInstaller.requirement`), is newer, and runs
on this macOS, then quits, swaps the two copies and reopens the new one. A release with only a
`.dmg`, or a copy that can't be replaced where it sits (run from a disk image, or from Downloads
without having been moved), falls back to the browser. "Check for Updates…" is in the About
window and always in the app menu under About, and Settings > General has the automatic-check switch.

To try the whole install without a release, in a Debug build:
`open Driftcast.app --args -UpdateTestZip /path/to/Driftcast.zip` (the zip must hold a copy signed
with the Developer ID), then press Update Now.

The repository is `UpdateConfig.repository` (`leechsoftware/driftcast`). No account or API key is
involved; GitHub's public API allows 60 requests an hour per network address.

Per release:

1. Raise `MARKETING_VERSION` in the project (the tag is compared with it number by number).
2. Archive, export and notarise (section 3), and zip the app: `ditto -c -k --keepParent Driftcast.app Driftcast.zip`.
3. Create a GitHub release tagged with the version (`v1.1` or `1.1`) and attach `Driftcast.zip`.
   Drafts and pre-releases are not offered.
4. If the bundled ffmpeg changed, update its versions and library table in `NOTICE.md`. The
   zip contains GPL programs, so their source must stay obtainable: the surest way is to
   attach the matching `ffmpeg-<version>.tar.xz` archives from ffmpeg.org to the release too.

To see the dialog without a release: `open Driftcast.app --args -ShowAvailableUpdate YES`.

## 3. Signing and notarisation

Archive with the Developer ID identity, enable hardened runtime (already set), notarise with
`notarytool`, staple. The bundled ffmpeg is signed by the build phase.

## 4. Releases

Driftcast is free: there is no trial, time limit or licence key. Each version is a GitHub
release with the notarised zip attached (section 2).
