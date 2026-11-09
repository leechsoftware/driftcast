# Driftcast: copyright, licence and acknowledgements

Driftcast
Copyright (C) 2026 Leech Software, Inc.
https://leechsoftware.com

Driftcast is freeware: free to use, with no trial, no ads, no account and no time limit.

## Licence

Driftcast is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of
the License, or (at your option) any later version.

Driftcast is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

The full text of the licence is in the file `LICENSE` (inside the app:
`Driftcast.app/Contents/Resources/Licenses/LICENSE.txt`, or About Driftcast > Licence). It is
also at <https://www.gnu.org/licenses/gpl-3.0.html>.

In short, and without replacing the licence itself: you may use Driftcast for any purpose,
study and change it, and share it or your changed version, provided that anything you
distribute stays under the same licence and comes with its source code.

## Source code

The complete source code of Driftcast, with the scripts that build and bundle it, is published
at <https://github.com/leechsoftware/driftcast>, where each released version is tagged.

## Contributions

Changes are welcome and encouraged: fixes, new features, support for more devices. Open an
issue or a pull request in the GitHub repository; `CONTRIBUTING.md` says how to build and
test. By submitting a change you agree that it is licensed under the GNU General Public
License, version 3 or later, like the rest of Driftcast.

## Software included in the app

### FFmpeg

The app contains the command-line programs `ffmpeg` and `ffprobe` in
`Driftcast.app/Contents/Resources/ffmpeg/`. Driftcast runs them as separate programs to read
and convert video; they are not linked into Driftcast.

FFmpeg is Copyright (c) 2000-2026 the FFmpeg developers, <https://ffmpeg.org>. The builds
below are configured with `--enable-gpl --enable-version3`, so they are licensed under the
**GNU General Public License, version 3 or later**. FFmpeg's own licence files (`LICENSE.md`,
`COPYING.GPLv2`, `COPYING.GPLv3`, `COPYING.LGPLv2.1`, `COPYING.LGPLv3`) are in the same folder
as the programs.

The app is universal and carries one statically linked build for each kind of Mac, merged into
single universal programs:

| Mac | FFmpeg | Built by | How it is built |
|---|---|---|---|
| Apple silicon (arm64) | 9.0.2 | Martin Riedl, <https://ffmpeg.martin-riedl.de> | one static program |
| Intel (x86_64) | 9.0.2 | Martin Riedl, <https://ffmpeg.martin-riedl.de> | one static program |

Corresponding source code:

- FFmpeg itself: <https://ffmpeg.org/releases/> (`ffmpeg-9.0.2.tar.xz`) and
  <https://git.ffmpeg.org/ffmpeg.git> (tag `n9.0.2`).
- The builds' scripts and library versions: <https://ffmpeg.martin-riedl.de> and
  <https://git.martin-riedl.de/ffmpeg/build-script>.
- How the two are combined into the app: `Scripts/bundle-ffmpeg.sh` in Driftcast's source.

If you cannot get any of this source from the places above, write to Leech Software through
<https://leechsoftware.com> and it will be provided for any version of Driftcast released in
the previous three years.

Libraries compiled into both builds, from their configuration: x264 and x265 (GPL v2 or
later); libzvbi (GPL v2 or later); libbluray, libklvanc and LAME (LGPL); libsrt (MPL 2.0);
OpenSSL (Apache 2.0); FreeType (FreeType License); libxml2, Fontconfig and HarfBuzz (MIT);
libass (ISC); zimg (WTFPL); libaom, dav1d, OpenH264, OpenJPEG, rav1e and libvmaf (BSD
2-Clause, libvmaf with a patent grant); SVT-AV1 and VVenC (BSD 3-Clause Clear); libvpx,
libwebp, Snappy, Opus, libvorbis and libtheora (BSD 3-Clause). See the build's page at
<https://ffmpeg.martin-riedl.de> for the versions.

### macSubtitleOCR

The code in `Driftcast/Subtitles/OCR/`, which reads picture subtitles (PGS, VobSub) into
text, comes from macSubtitleOCR, <https://github.com/ecdye/macSubtitleOCR>, adapted for
Driftcast.

    The MIT License (MIT)

    Copyright © 2024-2026 Ethan Dye

    Permission is hereby granted, free of charge, to any person obtaining a copy of this
    software and associated documentation files (the “Software”), to deal in the Software
    without restriction, including without limitation the rights to use, copy, modify, merge,
    publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
    to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or
    substantial portions of the Software.

    THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
    INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
    PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
    FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
    OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.

## Films shown in the screenshots and demo video

These appear only in the project's website and README images, not in the app:

- *Sintel*, © copyright Blender Foundation, <https://durian.blender.org>, licensed under the Creative Commons Attribution 3.0 licence.
- *Tears of Steel*, © copyright Blender Foundation, <https://mango.blender.org>, licensed under the Creative Commons Attribution 3.0 licence.
- *Elephants Dream*, © copyright 2006 Blender Foundation and Netherlands Media Art Institute, <https://orange.blender.org>, licensed under the Creative Commons Attribution 2.5 licence.

The plot text visible in the screenshots is from Wikipedia, licensed under CC BY-SA. Frames were scaled and captured inside the app. None of these parties endorses Driftcast.

## Thanks

No code was taken from these projects, but Driftcast's design learned from them:

- pychromecast and node-castv2, for how the Google Cast protocol works.
- GMPlayer by Gaston Morixe, for handing the player a complete playlist and converting on demand.

## Patents and formats

Some of the formats Driftcast can read or produce (H.264, HEVC, AAC, Dolby Digital and
others) are covered by patents in some countries. The GNU General Public License does not
grant rights under other people's patents. If you redistribute Driftcast or use it
commercially, checking whether you need a patent licence is your responsibility.

## Trademarks

Chromecast, Google Cast and Google TV are trademarks of Google LLC. AirPlay, Apple TV, Mac
and macOS are trademarks of Apple Inc. Dolby, Dolby Digital, Dolby Atmos and Dolby Vision are
trademarks of Dolby Laboratories. DTS is a trademark of DTS, Inc. Roku is a trademark of
Roku, Inc. OpenSubtitles is a service of its own operators. All other names belong to their
owners. Driftcast and Leech Software are not affiliated with, sponsored by or endorsed by any
of them.

## Privacy

Driftcast has no account, no analytics and no advertising. Your videos are sent only from
your Mac to the device you choose, over your own network. The app contacts the internet for
three things, each of which can be avoided:

- Posters, plot, people and ratings: the title and year read from a video's file name (never
  the file itself, its path or anything about you) are sent to Wikipedia and Wikidata (films)
  and TVmaze (shows), and to OMDb when a key is set. Turn off "Look up posters and details
  online" in Settings > General to stop this.
- Subtitle search, when you ask for it or when Settings > Subtitles lets Driftcast look for
  missing subtitles as a video starts (off unless you turn it on): OpenSubtitles.com receives
  the film's name and a fingerprint of the file.
- The update check: GitHub is asked for the newest release at launch and every eight hours, and
  the new version is downloaded from it when you choose Update Now. Turn off "Check for updates
  automatically" in Settings > General to stop this.

The full policy is in `PRIVACY.md`, at <https://github.com/leechsoftware/driftcast/blob/main/PRIVACY.md>.

## Data sources

Film details come from Wikipedia (<https://en.wikipedia.org>; article text is available under
the Creative Commons Attribution-ShareAlike licence, and the details panel links to the
article) and Wikidata (<https://www.wikidata.org>, CC0). Film posters shown from Wikipedia
remain the property of their studios and are displayed, as Wikipedia displays them, to
identify the film. Show details come from TVmaze (<https://www.tvmaze.com>, whose API asks
for a link back, shown in the details panel). Ratings come optionally from OMDb
(<https://www.omdbapi.com>), whose data derives from IMDb and the other sources named with
each rating. Driftcast is not affiliated with any of them, and their data remains theirs.
