---
title: How to Get Subtitles on Chromecast from a Mac
description: How to show SRT, ASS and picture subtitles when casting from a Mac to Chromecast, including finding subtitles online, using the free app Driftcast.
permalink: /chromecast-subtitles-from-mac/
---

Subtitles are where casting from a Mac most often falls down. A Chromecast needs subtitles as a separate text track in a format it understands, and the file you have may hold them in another format, in a legacy text encoding, or as pictures. VLC users, for example, have long reported that subtitles don't reach the TV.

## How Driftcast handles them

- **Subtitles inside the file** in SRT, ASS/SSA, WebVTT, MOV text and other text formats are converted to the format the Chromecast reads.
- **Subtitle files beside the video** are found automatically when their name starts with the video's name, such as `Movie.en.srt`.
- **Any text encoding** works, including UTF-16 and older Cyrillic, Greek, Arabic, Japanese, Chinese and Korean files.
- **Blu-ray PGS and DVD VobSub**, which are pictures, are read into text on your Mac the first time you use them, so the video doesn't need converting.
- **DVB and XSUB** picture subtitles are drawn into the video.

## No subtitles in the file?

Choose **Find Subtitles Online…** from the Subtitles menu. Driftcast searches OpenSubtitles by exact file match and by title, and the one you pick downloads and comes on. This needs a free OpenSubtitles API key, and the app shows you how to get one.

## Too small to read?

The Subtitles menu has a size slider from 60% to 200%. It changes the size as you drag and is remembered next time.

> **An honest note:** Driftcast hasn't been tried on a real Chromecast yet, and whether a Chromecast accepts separate text tracks alongside this kind of stream is still unconfirmed. Google's documentation covers them for MP4 files. If you own one, [please say how it went](https://github.com/leechsoftware/driftcast/issues), working or not.

{% include get-driftcast.md %}
