---
title: How to Cast 4K HDR Video from a Mac
description: Send 4K HEVC, HDR10, HLG and Dolby Vision video from a Mac to Apple TV, AirPlay 2 TVs and Chromecast without losing quality, using the free app Driftcast.
permalink: /cast-4k-hdr-video-from-mac/
---

Mirroring your screen throws away most of what makes a 4K HDR film worth watching. The picture is captured from your desktop and encoded again. To keep the quality, the original video stream has to reach the TV.

## How Driftcast does it

[Driftcast](https://github.com/leechsoftware/driftcast/releases/latest) is a free Mac app that sends the original stream wherever the device supports it, even from an MKV.

| Device | Largest picture | HDR |
|---|---|---|
| Apple TV, AirPlay 2 TVs | 4K | Yes |
| Google TV Streamer | 4K | Yes |
| Chromecast Ultra, Chromecast with Google TV, TVs with Cast built in | 4K | Yes |
| Chromecast HD | 1080p | Yes |
| Chromecast 1st to 3rd generation | 1080p at 30 fps | No |

## If the device can't take it

- **HDR on a device without HDR** is tone-mapped to normal range, so the picture doesn't look washed out.
- **A picture too big for the device** is scaled down to what it can show.
- Both happen on your Mac's GPU. In one test, converting a 4K HEVC clip to 1080p took 6.45 seconds of CPU time with software decoding and scaling, and 0.19 seconds with the whole job on the GPU.

Passing Dolby Vision through depends on the TV: some show the Dolby Vision layer and others only the HDR10 base.

{% include chromecast-note.md %}

{% include get-driftcast.md %}
