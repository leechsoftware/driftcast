# Contributing to Driftcast

Driftcast is freeware and open source, and changes from the people who use it are encouraged:
bug fixes, support for more devices and formats, new features, better wording.

## Reporting a problem

Open an issue and say:

- the Mac (Apple silicon or Intel) and its macOS version,
- the device you were playing to (model of Chromecast, Apple TV or TV),
- what the file is: Media Info… in the right-click menu shows its container, video and sound formats,
- what happened and what you expected.

A log helps a lot. Run this in Terminal, reproduce the problem, and attach what it prints:

```sh
/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.leechsoftware.driftcast"'
```

It lists each request the device makes to Driftcast's media server and the player's events.
It contains file names and addresses on your home network, nothing else.

## Building

1. Xcode 16 or later on macOS 14 or later. Open `Driftcast.xcodeproj` and run.
2. The media engine: run `Scripts/bundle-ffmpeg.sh` once. It downloads the static, universal
   FFmpeg the app ships, with no Homebrew needed. Without it the app still builds and uses
   Homebrew's ffmpeg, or a folder chosen in Settings. `SHIPPING.md` describes the universal
   (Apple silicon + Intel) build.
3. Signing: pick your own team under Signing & Capabilities, or sign to run locally.

New Swift files under `Driftcast/` are picked up by the project automatically.

## Testing

```sh
Tests/run-harness.sh
```

builds small test videos with ffmpeg and runs the logic checks (stream planning, HLS
segments, subtitles, playlists, the update check). It uses its own home folder and never
touches your library. Please add a check there for logic you change, and say in the pull
request what you tried on a real device: Chromecast in particular has had little testing.

## Sending a change

- Fork, make a branch, open a pull request. Small, focused pull requests are merged fastest.
- Keep the app's wording plain, and use SF Symbols rather than emoji in the interface.
- Every feature should be reachable from a menu, not only from an icon.
- By submitting a change you agree that it is licensed under the GNU General Public License,
  version 3 or later, like the rest of Driftcast (`LICENSE`, `NOTICE.md`).

## Where things are

`README.md` has a map of the source folders and explains how streaming works.
`docs/DESCRIPTION.md` describes everything the app does, in detail. The Chromecast code (`Driftcast/Cast/`) follows Google's Cast documentation and the
pychromecast and node-castv2 projects; it has not yet been run against a real device, so a
report from anyone who owns one, working or not, is especially welcome.
