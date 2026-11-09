---
title: How to Play MKV Files on Apple TV from a Mac
description: Apple TV can't play MKV files on its own. Here's how to stream them from your Mac with HEVC, HDR and Dolby audio intact, using the free app Driftcast.
permalink: /play-mkv-on-apple-tv-from-mac/
---

Apple TV has no built-in support for MKV, and AirPlay won't send one directly. The usual workarounds are mirroring your screen, which re-encodes your whole desktop, or converting the file first, which takes time and costs quality.

## The quick way

1. Install [Driftcast](https://github.com/leechsoftware/driftcast/releases/latest), a free Mac app.
2. Make sure your Mac and Apple TV are on the same network.
3. Drag the MKV onto the Driftcast window and start it playing.
4. Choose **Apple TV or AirPlay TV…** from the Output menu, then pick your Apple TV.

## What reaches the TV

- **H.264 and HEVC video goes through untouched**, including 10-bit HEVC, HDR10, HLG and Dolby Vision.
- **Dolby Digital and Dolby Digital Plus go through untouched**, including Atmos.
- **DTS and TrueHD**, which Apple TV can't play, become Dolby Digital Plus 5.1 or lossless FLAC. The picture isn't touched.
- **Older video**, such as MPEG-2, DivX, Xvid and VC-1, is converted to H.264 on your Mac's GPU as you watch.

Only the MKV wrapper changes when the streams are already compatible, so there's no quality loss and almost no load on the Mac.

## Subtitles

Text subtitles inside the MKV, and subtitle files beside it, are sent as real subtitles rather than drawn into the picture. Blu-ray PGS and DVD VobSub subtitles are read into text on your Mac the first time you use them.

{% include get-driftcast.md %}
