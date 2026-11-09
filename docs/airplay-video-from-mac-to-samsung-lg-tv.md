---
title: How to Send Any Video from a Mac to a Samsung or LG TV
description: Play MKV, AVI and other video files from your Mac on a Samsung, LG, Sony or other AirPlay 2 TV, without mirroring your screen, using the free app Driftcast.
permalink: /airplay-video-from-mac-to-samsung-lg-tv/
---

Many TVs from Samsung, LG, Sony, Roku, Vizio and Hisense support AirPlay 2, but AirPlay only accepts certain formats. An MKV or AVI won't go across directly, and mirroring your screen gives you a re-encoded copy of your desktop.

## The quick way

1. Install [Driftcast](https://github.com/leechsoftware/driftcast/releases/latest), a free Mac app.
2. Make sure your Mac and TV are on the same network, and that AirPlay is on in the TV's settings.
3. Drag your video onto the Driftcast window and start it playing.
4. Choose **Apple TV or AirPlay TV…** from the Output menu, then pick your TV.

Driftcast sends the TV a stream it can read, passing through whatever is already compatible and converting only the rest. This has been tested on a Samsung AirPlay 2 TV, including HEVC HDR10 video with converted audio and subtitles.

## If the TV connects but nothing plays

The TV fetches the video from your Mac, so it has to be able to reach it. Driftcast shows a warning when a TV connects but never asks for the stream. The usual causes are:

- the Mac and the TV are on different networks or Wi-Fi bands that are kept apart,
- a VPN is running on the Mac,
- a firewall is blocking incoming connections to Driftcast.

{% include get-driftcast.md %}
