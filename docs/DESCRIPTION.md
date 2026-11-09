# Driftcast: what it does, exactly

Driftcast is a free, open-source macOS app from Leech Software that plays the video files on
your Mac on a Chromecast, an Apple TV or an AirPlay 2 TV, and on the Mac itself. It converts
only what the device can't play, while the video is playing, so nearly any file plays on nearly
any device without waiting and without quality loss where none is needed.

This document describes version 1.0 as of 9 November 2026. It is written from
the source code, so every statement below corresponds to something the code does. Where a
feature has not been tried on real hardware, it says so.

---

## Features

### Devices
- Plays to **Chromecast** devices of every generation: Chromecast 1st to 3rd generation,
  Chromecast HD, Chromecast Ultra, Chromecast with Google TV, Google TV Streamer, Nest Hub
  and Nest Hub Max, and TVs, soundbars and receivers with Chromecast built in.
- Plays to **Google speakers and speaker groups** (Chromecast Audio, Google Home, Nest Audio,
  Nest Mini, JBL Link, Bose, Sony and other Cast speakers): the sound track only, listed
  separately as "Speakers (audio only)".
- Plays to **Apple TV** and **AirPlay 2 TVs** (Samsung, LG, Sony, Roku, Vizio, Hisense and
  others) through the system AirPlay picker.
- Plays on **this Mac** in its own resizable video window with the standard macOS player
  controls, picture-in-picture and full screen.
- Finds Chromecasts automatically by Bonjour, tells screens from speakers by the device's own
  capability flags, and reconnects after a Wi-Fi dropout (three attempts over about twelve
  seconds), resuming where it was.
- Shows the video's poster frame on the Chromecast while it loads and when paused.
- Warns when an AirPlay TV has connected but cannot fetch the video from the Mac (firewall,
  VPN or different networks), with a button to the Network settings.

### Files and formats
- Opens nearly anything FFmpeg reads: MKV, MP4, M4V, MOV, AVI, WMV, FLV, WebM, TS, M2TS,
  MTS, MPG, MPEG, VOB, OGV, OGM, 3GP, DivX, ASF, RM, RMVB, F4V, MXF, DV and more, plus audio
  files (MP3, M4A, FLAC, WAV, AAC, OGG, Opus).
- **Direct play:** a file the device can read as it is (MP4/M4V/MOV for Apple devices,
  MP4/M4V/WebM for Chromecast, with codecs the device decodes) is served untouched over HTTP
  with byte ranges, so the device's own seeking is instant.
- **Repackaging without re-encoding:** when only the container is the problem (an MKV with
  H.264 or HEVC video, for example) the streams are copied into fragmented MP4 HLS segments.
  No quality is lost and almost no processor time is used.
- **Converting only what is needed:** video the device can't decode becomes H.264 using the
  Mac's hardware encoder (VideoToolbox), or x264 in software; audio the device can't decode
  becomes AAC, Opus, Dolby Digital Plus or FLAC. Each stream is decided separately: a file with
  playable video and unplayable audio converts the audio alone.
- **Video passed through** when the device supports it: H.264, HEVC (H.265) including 10-bit,
  HDR10, HLG and Dolby Vision, VP8, VP9 and AV1, up to 4K.
- **Video converted** when it isn't: MPEG-1, MPEG-2, MPEG-4 Part 2 (DivX, Xvid), VC-1, WMV,
  ProRes, 10-bit H.264, unusual pixel formats, and anything taller or faster than the device
  manages.
- **GPU first:** with "Convert on the GPU" on (the default), decoding, scaling and H.264
  encoding all run in VideoToolbox wherever the source allows, so the frames never come back to
  the CPU (about a thirtieth of the CPU time on a 4K film). Deinterlacing, drawn-in subtitles
  and rotated video need the CPU for that one step. If ffmpeg won't start that way, the stream
  steps down by itself: hardware encoding only, then x264.
- **Keeps the Mac cool and the disk free:** ffmpeg runs about five minutes ahead of the player
  and is then frozen until the player catches up; the temporary converted pieces that have
  been played are cleared from the system temp folder, so even a long film never needs room
  for a full copy. The video file itself is never touched.
- **Deinterlacing** (bwdif) for interlaced DVD, broadcast and camcorder video; frame rates above
  60 are capped at 60; audio above 48 kHz is resampled for AAC; phone video keeps its rotation.
- **Transport streams** (.ts, .m2ts) and recordings whose clock doesn't start at zero play and
  seek correctly.
- **HDR to SDR tone mapping** on the GPU (VideoToolbox `scale_vt`, PQ or HLG to BT.709), or
  in software (zscale and tonemap) with hardware conversion off, for
  devices without HDR.
- **Audio passed through:** AAC, MP3, FLAC, ALAC, Dolby Digital (AC-3) and Dolby Digital Plus
  (E-AC-3, including Atmos) to Apple devices; AAC, MP3, Opus and FLAC to Chromecast, plus Dolby
  Digital and Digital Plus when "Pass through Dolby surround" is on.
- **Audio converted:** DTS, DTS-HD, DTS:X, Dolby TrueHD, Vorbis, PCM, WMA and anything else
  becomes Dolby Digital Plus 5.1 (default for Apple devices), lossless FLAC up to 7.1, or
  stereo AAC or Opus, as chosen in Settings.
- Several audio tracks: choose any track in the file; the preferred language is picked
  automatically.
- **Volume booster** (dynamic range normaliser plus a limiter), **downmix to stereo**, and an
  **audio delay** adjustable from −2 s to +2 s in 0.05 s steps, each applied in the conversion.
- Honours each device's published limits: the original Chromecasts get at most 1080p at 30
  frames per second (720p above that) and H.264 level 4.1; Nest Hubs get 720p; Chromecast HD
  gets 1080p with HEVC and HDR; Ultra, Google TV and TVs with Cast built in get 4K, HEVC, VP9
  and HDR; only the Google TV Streamer gets AV1.
- Maximum resolution (4K, 1080p, 720p) and conversion quality (6, 12, 20 or 30 Mbps, doubled
  for 4K) are adjustable; "Always convert video" forces conversion for troubleshooting.

### Film and show details
- A **details panel** beside the playlist (toolbar button, ⌘I, or View > Show Details) shows
  the selected or playing video's poster, title, year, running time, age rating, network,
  genres, ratings, director, writers, cast and plot; for an episode, the show's details plus
  the season and episode number, the episode's name, air date, still and synopsis. The
  panel's own header has a button that folds it away (⌥⌘I brings it back). It is a
  fixed-width column inside the window, so opening it never makes the window bigger; the
  playlist gives up the room and the panel scrolls, with a floating arrow at its foot that
  scrolls smoothly to the end (and, from there, back to the top). The panel always has a real
  scrollbar to drag, for a mouse with no wheel.
- Under the title, a tinted **captions line**: "Closed Captions: English, Spanish", or — when
  the video has nothing in your subtitle language (a forced track in it counts) — a captions
  symbol behind a red circle-and-slash with just "No English captions". "Show" (or clicking the line) scrolls to
  the captions section, which lists what the video does have and the Find button.
- The foot of the panel is the **closed captions section**, in the same tint so it stands out:
  the languages the video has, the crossed-out note when yours is missing, a menu of every
  track and subtitle file with a button that turns the chosen one on while the video plays
  (or starts a video that isn't playing with it). When the video has no captions at all, the
  section instead offers **Find Subtitles Online…** (prominent; one step — pick a result and
  it downloads and comes on) beside Add Subtitle File…; without a key, Find opens the steps
  to get one and the search follows once it is entered. Both are also in the track menu.
- **Films** come from Wikipedia (poster and lead paragraph) and Wikidata (director, writers,
  cast in billing order, genres, age rating, running time, release year, the IMDb link, and
  the IMDb, Rotten Tomatoes and Metacritic scores where Wikidata records them);
  **shows and episodes** from TVmaze (poster, rating, network, genres, synopses, episode names
  and stills). None of them needs an account.
- A free **OMDb key** (Settings > General) adds IMDb, Rotten Tomatoes and Metacritic ratings
  for films Wikidata hasn't scored and for episodes, plus writers and cast, and is used first
  when present. The app can also ship with a built-in key.
- Titles are read from file names: "Heat.1995.1080p.BluRay.x264" is Heat (1995);
  "Sopranos.S1.E11", "Show.S02E05", "Series 3x07" and "Episode 4" are episodes. A result must
  match the title (and the year, when both are known) or it is not shown. "Not this title?
  Search again…" lets you correct the title and year for a file, and the correction is
  remembered; a typed title that finds nothing with the file's year is tried again without it.
- Rows look up their details as soon as they appear. A video played the moment it is added
  waits up to six seconds for that lookup, so the title card and the Chromecast's screen get
  the real poster rather than a frame; the lookup carries on in the background either way.
- Playlist rows show the year and the first rating ("1995 · IMDb 8.3") or the episode number
  and name; the Chromecast shows the poster, with the film's year and director or the
  episode's show, number and name, on its loading and pause screens.
- **A title card when a video starts** (switchable): five seconds of the
  poster beside the title, year, running time, age rating, genres, director, cast and
  ratings, fading in and out. On this Mac and AirPlay it is a short clip stitched in front
  of the film inside the stream; a Chromecast instead stays on its own poster-and-title
  screen for the same five seconds before playing. HDR films that are passed through get
  no card, so the TV does not switch picture modes twice.
- Only the title and year are sent, never the file; results and artwork are cached, the
  services are asked no faster than they allow, and "Look up posters and details online" in
  Settings turns the whole feature off.

### Subtitles
- Subtitle tracks inside the file in every text format FFmpeg knows (SRT, ASS/SSA, WebVTT,
  MOV text, MicroDVD, SubViewer, SAMI, and more) are sent to the device as text, not drawn
  into the picture.
- Subtitle files next to the video are found automatically when their name starts with the
  video's name (`Movie.srt`, `Movie.en.srt`, `Movie.en.forced.srt`), with the language and
  "forced" read from the name. Legacy Windows-1252 files are read correctly.
- **Any text encoding:** subtitle files are read as UTF-8, UTF-16 or UTF-32 (with or without a
  byte-order mark), or in the legacy code page their language used (Cyrillic, Central European,
  Greek, Turkish, Hebrew, Arabic, Vietnamese, Thai, Japanese, Chinese, Korean, Western).
- Any subtitle file can be added by hand (SRT, ASS, VTT, SUP, IDX/SUB); it is remembered for
  that video.
- **Picture subtitles become text:** Blu-ray PGS and DVD VobSub subtitles inside an MKV, or as
  `.sup` and `.idx` files, are read with the Vision text recogniser (the vendored macSubtitleOCR
  code) the first time they are used and cached as SRT, so an HEVC film with PGS subtitles plays
  without converting the video. This can be turned off, in which case they are drawn into the
  picture during conversion.
- Other picture subtitles (DVB, XSUB) are drawn into the picture.
- **Nothing comes on by itself** unless asked: Settings > Subtitles has "Always turn on closed
  captions" and "Turn them on when the audio is in another language", in the caption language
  you choose. When one is ticked, a full track in that language is used, else a forced one
  (signs and foreign lines) in it. With "Search OpenSubtitles when the video has
  none in this language" on (needs the API key), a video that lacks them is looked up as it
  starts — fingerprint first, then title (season and episode for a show) — and the best match
  is downloaded, kept with the video and turned on; this takes a few seconds and is tried once
  per video per run.
- **While casting** the video window dims the film's poster and lays a big grey streaming mark
  under "Connected to <device>, streaming video…", shrinks to half its size, and keeps only
  play/pause and the timeline, which moves the position on the device. It goes back to its
  size when playback returns to this Mac.
- **Video window footer:** a thin bar under the picture reads "Closed Captions: English,
  Spanish" (or "No closed captions in this video") with the same menu as the playback bar.
- **"I don't care about subtitles"** (Settings > Subtitles) hides that footer and the Closed
  Captions section of the details panel; the menus still work.
- **Subtitle size** is one setting from 60% to 200%, remembered between launches: a slider in
  the menu bar's Subtitles menu (with Larger ⌥⌘= and Smaller ⌥⌘− above it), a Subtitle Size
  submenu with the same steps and presets in the playback bar's and the video window's
  subtitle menus, and the slider in Settings. A change applies at once: this Mac redraws its
  subtitles at that size, and a Chromecast is told the new text style without reloading the
  video (white text with a black outline). An AirPlay TV draws subtitles with its own settings.
- **OpenSubtitles.com search** built in: searches by the file's hash (exact-release matches are
  marked) and by title, shows language, download count and hearing-impaired marks, downloads
  as SRT and turns the subtitle on. Needs a free API key from OpenSubtitles unless the app ships
  with one. "How to get one…" in the details panel (and the same item in its captions menu)
  opens the steps: create an account and confirm it by email, open the API Consumers page,
  save a new consumer, paste the key into the box there (it is the same box as in Settings).
  The search window opens without a key and asks for it in the middle of the window. OpenSubtitles has no API for creating accounts, so that part is done on their site; a key
  alone allows 5 downloads a day, "Under development" on the consumer raises it to 100.

### Playlists and library
- Any number of named playlists in a sidebar; rename, delete, add videos or folders to each.
- Drag files or folders into the window, the sidebar, or onto the Dock icon; use the + button,
  File > Add Videos… or "Open With" from the Finder. Folders are searched recursively and
  sorted the way the Finder sorts.
- **Show playlists:** dropping two or more episodes of one show (`Sopranos.S1.E11.mp4`,
  `Show.S02E05.mkv`, `Series 3x07`, `Episode 4`, names that differ only by a number) creates a
  playlist named after the show, in episode order, or adds to an existing one without
  duplicates. An unrelated film in the same drop stays where it was dropped.
- Each row shows a poster frame, the title, a progress bar of how much has been watched, the
  stream summary (codec, resolution, HDR, audio, track and subtitle counts), the time left, and
  the duration. Finished videos are greyed out with a checkmark.
- Resume where you left off (positions saved every five seconds and on quit); "Play from
  Beginning" clears the position; mark videos watched or unwatched by hand.
- Autoplay of the next video in the playlist; Next and Previous buttons and shortcuts.
- Reorder by drag, move videos between playlists, take videos out of a playlist with the Delete
  key or the right-click menu (the file stays where it is), or delete a video's file from the
  right-click menu after confirming; remove with the Delete key or the right-click
  menu. Missing files are flagged.
- The library is a JSON file in Application Support, written after every change and again on
  quit.

### Playback controls
- Transport bar with Previous, back 10 s, Play/Pause, forward 10 s, Next, Stop, audio-track
  menu, subtitle menu, audio adjustments popover, and a volume slider that controls the device.
- A timeline with hover and drag **preview frames** (taken from the file with FFmpeg, so they
  work for MKV and AVI) and a lighter band showing how far the converter has got; seeking
  inside the band is instant, outside it restarts conversion at that point.
- The device does its own seeking: it receives the complete playlist before conversion starts,
  so the TV remote's skip and scrub work, and the device shows the real duration.
- Media keys and the Now Playing panel on the Mac: play, pause, next, previous, skip, scrub.
- Keeps the Mac awake while serving a device.
- Closing the main window quits the app; closing the video window keeps playing (on a device).

### Menus and shortcuts
- **Driftcast:** About Driftcast (the full description, requirements, licence and website),
  Check for Updates… (also a button in the About window), Settings…
- **File:** Add Videos… (⌘O), New Playlist (⇧⌘N), Details (⌘I), Show in Finder (⇧⌘R).
- **View:** Show Details (⌥⌘I), plus the standard sidebar and toolbar items.
- **Playback:** Play/Pause (⌘P), Stop (⌘.), Skip Forward/Back 10 Seconds (⌥→ / ⌥←), Skip
  Forward/Back 1 Minute (⌥⇧→ / ⌥⇧←), Next/Previous Video (⇧⌘→ / ⇧⌘←), Volume Up/Down (↑ / ↓),
  Audio Track submenu, Volume Booster, Downmix to Stereo, Audio Delay (⌥⌘] later, ⌥⌘[
  earlier, Reset).
- **Output:** This Mac, Apple TV or AirPlay TV…, every Chromecast found (speakers in a
  submenu), Disconnect from Chromecast, Search for Devices Again.
- **Subtitles:** Off, every subtitle track and file, Add Subtitle File…, Find Subtitles
  Online…, Larger Subtitles (⌥⌘=), Smaller Subtitles (⌥⌘−), the Subtitle Size slider, Get a
  Free OpenSubtitles API Key…, Enter API Key…, Subtitle Settings…
- **Help:** Driftcast Help, Report a Problem…, Driftcast on GitHub,
  Driftcast Website.
- **Right-click on a video:** Play / Resume from 12:34 / Pause / Stop, Play from Beginning, Add
  Subtitle File…, Find Subtitles Online…, Details, Show in Finder, Mark as Watched /
  Unwatched, Move to Playlist (any playlist or a new one), Add Videos…, Remove from Playlist,
  Delete File… (asks "Do you really want to delete this file?", then moves the file to the
  Trash, stops it if it is playing, and takes it out of every playlist; the only command in
  the app that touches a file on disk).
- **Right-click on a playlist:** Rename, Add Videos…, Delete Playlist.
- In the list: Space plays or pauses, Return plays the selected video, Delete removes it from
  the playlist (the file stays).

### Settings
- **General:** resume where you left off; play the next video automatically; look up posters
  and details online, OMDb API key, show the poster and details for five seconds when a video starts;
  which ffmpeg to use (the built-in copy, or a folder of your
  own); check for updates automatically, last check, Check Now.
- **Video:** convert on the GPU (VideoToolbox); conversion quality; maximum resolution; always convert; HEVC
  on Chromecast (automatic by model, always, never).
- **Audio:** preferred audio language; surround conversion for Apple devices (Dolby Digital
  Plus 5.1, lossless FLAC, stereo AAC); Chromecast stereo codec (AAC or Opus); pass through
  Dolby surround to Chromecast.
- **Subtitles:** always turn on closed captions; turn them on when the audio is in another
  language; caption language; search OpenSubtitles when the video has none in that language;
  convert picture subtitles to text; subtitle size; OpenSubtitles API key; "I don't care
  about subtitles".
- Changing a conversion setting while a video plays re-plans and restarts the stream at the
  same position a second later.

### Updates, about, licence
- Checks the project's GitHub releases at launch and every eight hours (switchable) and offers
  a new version in a dialog ("Update version X available"): Update Now (downloads it, checks it is signed by Leech Software, closes and reopens as the new version), Remind Me Later, Skip This Version.
- About window with the version, "by Leech Software" linking to leechsoftware.com, how it
  works, what it plays, what you need, tips, the freeware statement, copyright, trademarks, and
  buttons for the licence and acknowledgements.
- Freeware: no trial, no time limit, no licence key, no account, no ads, no analytics.
- Open source under the GNU General Public License v3; FFmpeg (GPL) and macSubtitleOCR (MIT)
  are credited in `NOTICE.md`, which is also inside the app.
- Universal app (Apple silicon and Intel), Developer ID signed and notarized, macOS 13 Ventura
  or later. Nothing to install besides the app: FFmpeg is inside it.

### Diagnostics
- Every request a device makes to the built-in server and every player event is logged to the
  unified log (subsystem `com.leechsoftware.driftcast`), readable in Console or with
  `/usr/bin/log stream`.
- The details panel's File section shows a file's streams and, for the current output
  device, exactly what would be passed through, converted or drawn in, and why.
- The audio adjustments popover shows the same "Stream" notes for the playing video.

---

## How a video reaches the TV

1. **You pick a video** (double-click, Return, the right-click menu, or autoplay). Driftcast
   saves the previous video's position, then probes the file with `ffprobe` (JSON output,
   cached per file): duration, container, bit rate, the video stream (codec, profile, level,
   pixel format, size, frame rate, colour transfer, Dolby Vision side data), every audio stream
   (codec, profile, channels, language, title, default flag) and every supported subtitle
   stream (codec, language, title, default and forced flags).

2. **Tracks are chosen.** The audio track is the first one in your preferred language (default
   track first), else the file's default track. The subtitle is none, unless "Always turn on
   closed captions" is set (or "when the audio is in another language" and the audio isn't in
   your language): then a full subtitle in your language (text before
   picture). Subtitle files next to the video and ones you attached are included.

3. **A plan is made** (`StreamPlanner`) for the output device's profile:
   - Video is **copied** unless: conversion is forced; the codec isn't in the device's list;
     the picture is taller than the limit (device limit, your setting, and the device's
     over-30 fps limit); H.264 is 10-bit or above the device's level; the pixel format is
     unusual; the file is HDR and the device isn't; or a picture subtitle must be drawn in.
     Otherwise it is **converted** to H.264 at the lowest of the file's height and the limit,
     at the chosen bit rate (doubled for 4K), with the hardware or software encoder.
   - Audio is **copied** unless: the codec isn't supported; it has more channels than the
     device takes (two for Chromecast without passthrough, eight otherwise); the booster or
     downmix is on. Otherwise it is **converted**: stereo sources and downmixes become AAC
     (192 kbps) or Opus (160 kbps); surround for Apple devices becomes Dolby Digital Plus 5.1
     (640 kbps), FLAC, or stereo per Settings; surround for Chromecast becomes Dolby Digital
     Plus 5.1 with passthrough on, else stereo.
   - **Direct play** (the device reads the original file) happens only when the file's
     extension is one the device opens natively, nothing is converted, no picture subtitle is
     drawn in, there is no audio delay, the chosen audio track is the first one (devices
     always play the first), the device isn't a speaker, and, for Apple devices, there is no
     text subtitle (AVPlayer can't side-load one) and HEVC is tagged `hvc1`. Everything else
     goes through HLS.
   - The plan carries human-readable notes ("Video: HEVC 4K HDR10, sent untouched", "Audio:
     DTS 5.1 converted to Dolby Digital Plus 5.1 (DTS isn't supported)"), shown in Media Info
     and the adjustments popover.

4. **The device is connected.** For a Chromecast, a TLS connection is opened to port 8009 and
   the Default Media Receiver is launched (see below); the Mac's address on the interface that
   reaches the Chromecast becomes the host of every URL. For this Mac and AirPlay, the address
   of the Mac's primary network interface is used (the system's primary interface when it is a
   real link, else the first live Wi-Fi or Ethernet port, never a VPN tunnel unless nothing
   else is up).

5. **Subtitles are prepared.** Text subtitles are extracted to WebVTT cues with ffmpeg (external
   `.vtt` files are read directly; other files are retried as Windows-1252 if they aren't
   UTF-8). Picture subtitles go through OCR if allowed, with a cached SRT per file and track.

6. **A session is created** (`StreamSession`) with a random 16-character id. For HLS, a
   **segment grid** is decided before any conversion: a fixed 4-second grid when video is
   converted (ffmpeg is forced to put a keyframe at every multiple of 4 s), or one segment per
   source keyframe when video is copied (keyframe times come from `ffprobe` packet flags and
   are cached). The complete VOD playlist is therefore known up front.

7. **The title card** (when on, for this Mac and AirPlay) is drawn by the app at the stream's
   picture size and encoded by a second ffmpeg into a short H.264 + silent AAC clip while the
   first segments are produced. The playlist places it before the segment where playback
   starts, between `EXT-X-DISCONTINUITY` tags with its own `EXT-X-MAP`, so the film's own
   codecs follow unchanged. Every position the device reports is mapped back to film time, and
   subtitle cues are moved past the card. Starting from the beginning is exact; resuming
   starts the film at the segment boundary just before the saved position. A file that could
   have been played directly is repackaged (not converted) so the card can be included.

8. **Conversion starts** where playback starts. One ffmpeg job writes fragmented MP4 segments
   from that time with `-copyts`, so timestamps stay absolute. If playback starts mid-file, a
   short job at the start produces the one init segment the device will use for the whole
   stream. Playback begins as soon as the first segment at the start time exists.

9. **The device fetches** the playlist, init segment and segments from Driftcast's HTTP server.
   A segment that isn't produced yet makes the server wait for the job; a request far from any
   running job starts a new job there (at most two jobs; the least recently used is stopped).
   Segments from different jobs are joined onto one timeline by rewriting each fragment's
   decode time (`tfdt`) and blanking `sidx` boxes (`MP4Boxes.rebase`).

10. **Status flows back** every second (Chromecast media status polling, AVPlayer time
   observer): position, state, volume, finished or error. Progress is saved; at the end the
   video is marked watched and the next one starts.

---

## The media server

- An HTTP/1.1 server on Network.framework listening on every interface at port **48100** (or a
  system-chosen port if that is taken), handling GET, HEAD and OPTIONS with keep-alive.
- Paths, all under a random per-session id so nothing else on disk is reachable:
  - `/s/<id>/media.<ext>`: the original file with byte ranges (direct play).
  - `/s/<id>/master.m3u8`: HLS master for AVPlayer and AirPlay, with a WebVTT subtitle
    rendition when subtitles are on.
  - `/s/<id>/cast.m3u8`: HLS master for Chromecast with `BANDWIDTH`, `CODECS`, `RESOLUTION`,
    `FRAME-RATE` and `VIDEO-RANGE`, the codec strings read from the stream's own init segment
    (for example `hvc1.2.4.L120.90,ec-3` or `avc1.64001F,mp4a.40.2`).
  - `/s/<id>/stream.m3u8`: the complete VOD media playlist (`EXT-X-VERSION:7`, independent
    segments, `EXT-X-MAP`, every segment listed, `EXT-X-ENDLIST`).
  - `/s/<id>/init.mp4`, `/s/<id>/segNNNNN.m4s`: produced on demand.
  - `/s/<id>/intro-init.mp4`, `/s/<id>/intro-0.m4s`: the title card clip.
  - `/s/<id>/subs.vtt`: the whole subtitle file (Chromecast text track).
  - `/s/<id>/subs.m3u8`, `/s/<id>/subs-N.vtt`: 10-second subtitle segments (AVPlayer).
  - `/s/<id>/poster.jpg`: artwork for the Chromecast.
- CORS headers on every response (`Access-Control-Allow-Origin: *`, allowed and exposed
  headers for ranges), which Chromecast requires for adaptive streams and subtitles.
- Byte ranges on files and on in-memory bodies (206, 416), `Cache-Control: no-cache` on
  playlists and subtitles.
- Each request is logged with method, path, status, time taken, range, caller address and
  user agent. Requests from the Mac's own addresses are told apart from a device's, which is
  how the AirPlay warning knows the TV never asked for the stream.

---

## Chromecast, in detail

- **Discovery:** Bonjour `_googlecast._tcp` with TXT records: `fn` friendly name, `md` model,
  `id` stable id, `ca` capability flags (1 video out, 4 audio out, 32 speaker group). Devices
  without video output are listed as speakers; the model name is the fallback.
- **Connection:** TLS to the device (its certificate is accepted as is; Cast devices use
  Google's own authority), IPv4, 15-second connect timeout, 20 seconds overall for the first
  message; a connection that is "waiting" (for example while macOS asks you to allow local
  network access) is not treated as a failure.
- **Protocol:** Cast v2 messages are hand-encoded protobuf (`CastMessage`: protocol version,
  source, destination, namespace, payload type, UTF-8 payload) framed by a 4-byte big-endian
  length. Namespaces: `tp.connection` (CONNECT/CLOSE), `tp.heartbeat` (PING every 5 s, PONG
  on request, a 25-second silence drops the link), `receiver` (GET_STATUS, LAUNCH, STOP,
  SET_VOLUME), `media` (LOAD, PLAY, PAUSE, SEEK, STOP, GET_STATUS).
- **Session:** CONNECT to `receiver-0`; GET_STATUS to join the Default Media Receiver
  (`CC1AD845`) if it is already running, else LAUNCH it and poll until its transport id
  appears; CONNECT to that transport; LOAD.
- **LOAD request:** `contentId`/`contentUrl` (the stream URL), `contentType`
  (`application/x-mpegURL` or the file's type), `streamType` BUFFERED, `duration`, metadata
  with title and poster image, `hlsSegmentFormat` and `hlsVideoSegmentFormat` set to `fmp4`
  for HLS, `autoplay`, `currentTime` (the resume point), and, when subtitles are on, one TEXT
  track (`text/vtt`, named and tagged with its language) activated through `activeTrackIds`,
  with a text style (white, black outline, your text size).
- **Status:** media status is polled every second and applied: playing, paused, buffering,
  idle with reason (FINISHED ends the video, ERROR reports the detailed error code), current
  time, device volume.
- **Volume** is the device's receiver volume; **Disconnect** stops the receiver app on the TV
  and closes the connection.
- **Reconnection:** a dropped connection is retried three times (2, 4 and 6 seconds apart),
  the session rejoined and the video reloaded at its position.
- **Not yet verified on hardware.** No Chromecast was available during development. The
  implementation follows Google's documentation and the pychromecast and node-castv2
  projects, and the playlist attributes Google's player documents as required are present.

---

## This Mac and AirPlay, in detail

- Playback on the Mac uses `AVPlayer` with the standard `AVPlayerView` controls, floating
  controls, full screen and picture in picture. AirPlay is `AVPlayer`'s external playback: the
  TV fetches Driftcast's URLs itself, so HEVC, HDR and Dolby audio reach it untouched.
- The AirPlay picker is the system `AVRoutePickerView` in the toolbar; the Output menu's
  "Apple TV or AirPlay TV…" item opens the same picker.
- HLS streams for Apple devices use `master.m3u8`, where subtitles are a WebVTT rendition
  (10-second segments with `X-TIMESTAMP-MAP`) that AVPlayer lists as a legible option and
  Driftcast selects. Direct-play MP4 files are served whole.
- Stalls, item errors and failed-to-play events are logged with the player's error log entries.
- If an AirPlay TV is connected and has not fetched anything for 15 seconds after playback
  should have started, a banner explains the likely causes (different network, VPN, firewall)
  with a button to Network settings.

---

## Audio, in detail

- Passthrough and conversion rules are in "Features" above. Conversions resample with
  `aresample=async=1` so the sound stays in step.
- **Volume booster:** `dynaudnorm` (frame 150 ms, gauss 15, peak 0.9, max gain 10) followed by
  `alimiter` at 0.95, applied whenever on (forces audio conversion).
- **Downmix:** forces a two-channel conversion.
- **Audio delay:** the audio stream is read from a second input with `-itsoffset`, so the
  picture and sound shift relative to each other; positive delays the sound. Changing it
  restarts the stream after a 0.9-second pause so several clicks become one restart.
- Audio-only devices (speakers, groups) receive HLS with the video dropped.

---

## Subtitles, in detail

- Text subtitles inside the file are extracted with `ffmpeg -f webvtt` and parsed into cues;
  external files likewise, `.vtt` read directly. Cues are served either as one WebVTT document
  (Chromecast side-loaded track) or as HLS subtitle segments (Apple).
- Picture subtitles: PGS and VobSub inside MKV are read by the vendored MKV parser; `.sup`
  and `.idx`/`.sub` files directly. Each image is recognised with the Vision framework in the
  track's language, your preferred language and English; results are written through an SRT
  fixer and cached in Application Support/Driftcast/OCR keyed by file, modification date and
  track. Without OCR (or for DVB/XSUB), the subtitle is overlaid onto the video during
  conversion.
- Languages: three-letter container codes are mapped to two-letter codes and localised names;
  a file suffix is treated as a language only when the system knows a name for it, so
  `Up.srt` isn't "language up".
- OpenSubtitles: REST API v1 with the app's or your key; search parameters sorted and
  lower-cased as the API requires; the 64-bit movie hash (file size plus word sums of the first
  and last 64 KiB) finds exact releases; downloads land in Application
  Support/Driftcast/Subtitles as `Title.lang.id.srt` and are attached to the video.

---

## Library and playlists, in detail

- `library.json` in `~/Library/Application Support/Driftcast/` holds playlists (id, name,
  items with id, URL and attached subtitle files), progress per file path (position, duration,
  updated), the set of watched paths and the selected playlist. Writes are coalesced (0.5 s)
  and forced on quit.
- Progress rules: within the last 4% of the file (at least 30 s, at most 10%) counts as
  finished; positions under 10 s are not saved (so a rewind to the start keeps the old resume
  point); "Play from Beginning" clears it.
- Show detection (`SeriesName`): episode markers `S01E02`, `S1.E11`, `1x02`, `Season 3`,
  `Episode 4`/`Ep 4`/`E4`/`Part 2`/`Chapter 5`/`Volume 1`/`Disc 2`/`CD1`, ` - 03`, or a common
  prefix of at least four characters and half the shortest name that doesn't cut a word.
  Dots and underscores become spaces, release tags are trimmed, and a show needs at least two
  files.
- An untouched playlist still called "Playlist" or "Playlist 2" is renamed to the show when a
  whole drop is one show; otherwise a new playlist is appended, and existing playlists with the
  same name (case-insensitive) are reused without duplicate files.

---

## Files and folders Driftcast uses

| Where | What |
|---|---|
| `~/Library/Application Support/Driftcast/library.json` | playlists, positions, watched marks |
| `~/Library/Application Support/Driftcast/Subtitles/` | subtitles downloaded from OpenSubtitles |
| `~/Library/Application Support/Driftcast/OCR/` | text read from picture subtitles (SRT) |
| `~/Library/Caches/Driftcast/Posters/` | poster frames (JPEG, keyed by path and modification date) |
| `~/Library/Caches/Driftcast/Keyframes/` | keyframe indexes for copied video |
| `~/Library/Caches/Driftcast/Metadata/`, `Artwork/` | film and show details and their posters |
| `~/Library/Application Support/Driftcast/title-overrides.json` | titles corrected by hand |
| `$TMPDIR/DriftcastStreams/<pid>/<session>/` | HLS segments while a video plays; removed when it stops and at quit; folders of copies that are no longer running are cleaned at launch |
| `~/Library/Preferences/com.leechsoftware.driftcast.plist` | settings |
| `Driftcast.app/Contents/Resources/ffmpeg/` | the bundled ffmpeg and ffprobe with their licences |
| `Driftcast.app/Contents/Resources/Licenses/` | `LICENSE.txt` and `NOTICE.txt`, opened from About |

Network: TCP 48100 inbound from the device (any port if 48100 is busy), TCP 8009 outbound to a
Chromecast, Bonjour (mDNS) for discovery, outbound HTTPS to en.wikipedia.org, www.wikidata.org and api.tvmaze.com (film and show
details, switchable),
www.omdbapi.com (only with a key), api.github.com and github.com (update check and download) and
api.opensubtitles.com (only when you search). macOS 15 and later ask once for
local-network permission.

---

## What is untested, and known limitations

- **Chromecast on real hardware:** never tried. The protocol, playlist attributes and
  per-device limits follow Google's documentation; the logic harness verifies the playlists,
  codec strings and conversions that a Chromecast would receive, with AVPlayer standing in as
  the player.
- **Side-loaded subtitles with HLS on Chromecast:** Google documents side-loaded WebVTT tracks
  for MP4 and requires CORS, which is in place; whether its player accepts them with an HLS
  stream has not been confirmed.
- **Older macOS:** the app and FFmpeg were compiled for macOS 13 and 12 respectively and FFmpeg
  checked against those limits, but the app has only been run on macOS 26.
- **Intel Macs:** the whole test suite passes as Intel code under Rosetta on an Apple silicon
  Mac, using FFmpeg's Intel build; no real Intel Mac has been used. If an Intel GPU refuses part
  of the GPU route, the conversion steps down by itself.
- **Dolby Vision profile 5 converted to H.264** can't be accurate (no tool here reshapes it),
  and the note in the stream details says so. Passed through, it is labelled correctly.
- No spatial audio virtualisation, no phone remote, no network speed test.
- Dolby Vision is passed through as HEVC to devices that report HDR support; whether a given
  TV shows the Dolby Vision layer or only the HDR10 base layer depends on the TV, and
  dual-layer (profile 7) files have not been tested.
- AirPlay to a device the Mac cannot reach on its chosen address (two networks, VPN, firewall)
  shows the warning banner but cannot be fixed from inside the app.

---

## Requirements, building, licence

- macOS 13 Ventura or later, Apple silicon or Intel; the Mac and the device on the same network.
- Build with Xcode 16 or later from `Driftcast.xcodeproj`; run `Scripts/bundle-ffmpeg.sh` once
  to fetch the media engine (see `SHIPPING.md` for the universal build and notarisation). `Tests/run-harness.sh` runs the logic checks.
- Copyright 2026 Leech Software, Inc. GNU General Public License v3 or later (`LICENSE`);
  third-party components and trademarks in `NOTICE.md`; how to contribute in `CONTRIBUTING.md`.
