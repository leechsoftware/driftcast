---
title: How to Cast MKV Files to Chromecast from a Mac
description: Chromecast doesn't officially play MKV files. Here's how to cast them from a Mac with no conversion wait, using the free app Driftcast.
permalink: /how-to-cast-mkv-to-chromecast-from-mac/
---

Chromecasts don't officially support the MKV container, so dropping an MKV into a browser tab usually gives you no picture, no sound or a blurry mirror of your screen. The video inside an MKV is often something the Chromecast can play perfectly well, though. It's the wrapper that's the problem.

## The quick way

1. Install [Driftcast](https://github.com/leechsoftware/driftcast/releases/latest), a free Mac app.
2. Make sure your Mac and Chromecast are on the same network.
3. Drag the MKV onto the Driftcast window.
4. Choose your Chromecast from the Output menu or the toolbar, and press play.

## What happens to the file

Driftcast reads every stream in the MKV and decides what your particular Chromecast can handle:

- **H.264 or HEVC video your model supports** is copied into a stream the Chromecast accepts, without re-encoding. No quality is lost and it uses almost no processor time.
- **Video it can't play**, such as MPEG-2, VC-1, or 10-bit H.264, is converted to H.264 on your Mac's GPU while you watch.
- **Sound it can't play**, such as DTS or TrueHD, is converted on its own, leaving the picture untouched.

The Chromecast gets the complete playlist before conversion starts, so it shows the real running time and you can skip around.

## Why not just convert the file first?

Tools like HandBrake work, but you wait for the whole conversion before you can watch, you end up with a second copy of the film, and you lose some quality. Driftcast does only the part that's needed, as you watch, and leaves your file exactly as it was.

{% include chromecast-note.md %}

{% include get-driftcast.md %}
