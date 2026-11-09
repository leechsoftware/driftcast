---
title: How to Play DTS Audio on Chromecast from a Mac
description: Chromecast can't play DTS or TrueHD, which often means a film with no sound. Here's how to fix it from a Mac, without re-encoding the video, using the free app Driftcast.
permalink: /dts-audio-chromecast-mac/
---

A film that plays on a Chromecast with a picture but no sound usually has DTS or Dolby TrueHD audio, which Chromecasts can't decode. The video is fine, so re-encoding the whole film is a waste of time and quality.

## The fix

Driftcast decides each stream separately. If the picture is playable and the sound isn't, it converts the sound alone and leaves the picture untouched.

1. Install [Driftcast](https://github.com/leechsoftware/driftcast/releases/latest), a free Mac app.
2. Drag the film onto the Driftcast window.
3. Choose your Chromecast and press play.

## What the sound becomes

- **By default:** stereo AAC, or Opus if you choose it in Settings.
- **With a soundbar or receiver that decodes Dolby:** turn on **Pass through Dolby surround** in Settings > Audio, and DTS and TrueHD become Dolby Digital Plus 5.1 instead. Dolby Digital and Dolby Digital Plus tracks, including Atmos, then go through untouched.

The same applies to Vorbis, PCM, WMA and other formats a Chromecast can't play. If the file has several audio tracks, you can pick any of them, and your preferred language is chosen automatically.

{% include chromecast-note.md %}

{% include get-driftcast.md %}
