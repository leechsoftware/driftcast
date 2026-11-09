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

**The version number is changed by hand only.** `MARKETING_VERSION` in the project is the
version (1.0 at the time of writing). It stays as it is until the owner decides a new version
is due; nothing bumps it automatically. The app offers an update only when a release's tag is
a higher number than the version it is running, so a rebuilt 1.0 is never offered to a 1.0.

Per release:

1. Raise `MARKETING_VERSION` in the project if this is a new version (the tag is compared with
   it number by number).
2. Run `Scripts/make-release.sh`. It archives a universal build, has Xcode sign it with the
   Developer ID and notarise it, checks the result, and writes `Releases/<version>/`:
   `Driftcast-<version>.dmg` (for people), `Driftcast-<version>.zip` (for Check for Updates,
   which can only install a zip) and `SHA256SUMS.txt`. `Releases/` is git-ignored.
3. Create a GitHub release tagged `v<version>` and attach both files:
   `gh release create v1.0 Releases/1.0/Driftcast-1.0.dmg Releases/1.0/Driftcast-1.0.zip --title "Driftcast 1.0" --notes-file notes.md`
   (with Driftcast's own token in `GH_TOKEN`; see the note on accounts below). Drafts and
   pre-releases are not offered to the app.
4. If the bundled ffmpeg changed, update its versions and library table in `NOTICE.md`. The
   zip contains GPL programs, so their source must stay obtainable: the surest way is to
   attach the matching `ffmpeg-<version>.tar.xz` archives from ffmpeg.org to the release too.

Accounts: Driftcast lives under the `leechsoftware` GitHub account, separate from the owner's
other projects. The folder's own `.git/config` carries the identity and a credential helper
that reads a keychain item named `driftcast-github`, so `git push` from this folder goes to the
right account without changing `gh`'s active login. For `gh` commands use
`GH_TOKEN=$(security find-generic-password -s driftcast-github -a leechsoftware -w) gh …`.

To see the dialog without a release: `open Driftcast.app --args -ShowAvailableUpdate YES`.

## 3. Signing and notarisation

`Scripts/make-release.sh` does all of it through Xcode: `xcodebuild archive` with both
architectures, `-exportArchive` with a `developer-id` options plist whose destination is
`upload` (Xcode signs with the team's cloud-managed Developer ID and sends the app to Apple),
then `-exportNotarizedApp` until Apple answers, which staples the ticket. No certificate or
`notarytool` profile needs to be on the Mac. The hardened runtime is on in the project and the
bundled ffmpeg is signed by the build phase. The disk image itself is not signed; the stapled
app inside it is what Gatekeeper checks when it is opened.

## 4. Releases

Driftcast is free: there is no trial, time limit or licence key. Each version is a GitHub
release with the DMG and the zip attached (section 2).
