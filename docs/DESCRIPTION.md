# Driftcast: what it does, exactly

[![Download the latest version of Driftcast](https://img.shields.io/github/v/release/leechsoftware/driftcast?style=for-the-badge&label=Download&color=F0468F&logo=apple&logoColor=white)](https://github.com/leechsoftware/driftcast/releases/latest)

Free disk image for macOS 13 or later, Apple silicon and Intel. [All releases](https://github.com/leechsoftware/driftcast/releases)

Driftcast is a free, open-source macOS app from Leech Software that plays the video files on
your Mac on a Chromecast, an Apple TV or an AirPlay 2 TV, and on the Mac itself. It converts
only what the device can't play, while the video is playing, so nearly any file plays on nearly
any device without waiting and without quality loss where none is needed.

This document describes version 1.1.3 as of 20 November 2026 (not yet released). It is
written from the source code, so every statement below corresponds to something the code
does. Where a feature has not been tried on real hardware, it says so. What changed in
version 1.1.1 is marked "(new in 1.1.1)", what changed in 1.1.2 "(new in 1.1.2)" or "since
1.1.2", and what changed in 1.1.3 "(new in 1.1.3)" or "since 1.1.3".

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
- Plays on **this Mac** in its own resizable video window. Since 1.1.3 the window has
  Driftcast's own controls in place of the standard macOS ones: a bar that shows while the
  pointer moves over the picture, with the timeline, Mute, Previous, back and forward 10
  seconds, Play/Pause, Next and full screen; a double-click on the picture is full screen
  too. The macOS controls grayed out Rewind and Fast Forward for a video Driftcast is
  converting as it plays (there is no way to make them skip), had no Next or Previous, and
  their timeline moved the player without Driftcast knowing, so the next skip could start
  the video over. What went with them: the speed menu, picture-in-picture, chapters and
  the share button in that window. The AirPlay button went with them too, leaving the
  window with no way to send the video to a TV (the user's report, 2026-11-22): a **cast
  button** (`CastButton`) is now at the right end of the bar under the picture (the
  captions bar, or the casting bar while a TV plays) and beside full screen in the controls
  over the picture, for a video with no bar. It opens the toolbar picker's choices (This
  Mac, each Chromecast, AirPlay, Disconnect; `OutputMenuItems`) and is tinted while the
  video is on a TV.
- **The video window stays in front of the main window** (new in 1.1.3). macOS brings forward
  only the window that was clicked, so a click on the main window used to cover the video,
  and a click on the main window with Driftcast behind another app brought the list back and
  left the video behind. Whenever the main window comes forward the video window is now put
  just above it, after every click there too; the keyboard stays with the list. When the
  main window is dragged the video window moves the same distance, so the two stay
  together (a resize moves nothing). A video window in the Dock, in full screen or on
  another desktop is left where it is. It is still an ordinary window: it doesn't float
  over other apps, and can be dragged anywhere by its own title bar.
- Finds Chromecasts automatically by Bonjour, tells screens from speakers by the device's own
  capability flags, and reconnects after a Wi-Fi dropout (three attempts over about twelve
  seconds), resuming where it was. When five seconds of searching find none, the list says
  "None found on this network" rather than searching on; a Chromecast that turns on later
  still appears as soon as it answers.
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
- **Volume booster** (dynamic range normalizer plus a limiter), **downmix to stereo**, and an
  **audio delay** adjustable from −2 s to +2 s in 0.05 s steps, each applied in the conversion.
- Honors each device's published limits: the original Chromecasts get at most 1080p at 30
  frames per second (720p above that) and H.264 level 4.1; Nest Hubs get 720p; Chromecast HD
  gets 1080p with HEVC and HDR; Ultra, Google TV and TVs with Cast built in get 4K, HEVC, VP9
  and HDR; only the Google TV Streamer gets AV1.
- Maximum resolution (4K, 1080p, 720p) and conversion quality (6, 12, 20 or 30 Mbps, doubled
  for 4K) are adjustable; "Always convert video" forces conversion for troubleshooting.

### Film and show details
- A **details panel** beside the playlist (toolbar button, ⌥⌘I, or View > Show Details, which reads Hide Details while it is open) shows
  the selected or playing video's poster, title, year, running time, age rating, network,
  genres, ratings, director, writers, cast and plot; for an episode, the show's details plus
  the season and episode number, the episode's name (since 1.1.2 on its own line under
  them, not after a colon), air date, still and synopsis. Since 1.1.3 an episode's still
  sits at the top, above the show's poster, and the panel is open every time Driftcast
  starts (it can be closed for the session). The ratings sit at the right edge beside the
  year and genre lines (`TitleFactsRow`; the user's request, 2026-11-22: they had a row of
  their own under the captions line); the genres keep to one line, a list too long for the room being cut
  short with "…" (the whole list is in its tooltip), so the ratings stay beside the text
  unless the first line itself doesn't fit next to them (a film's IMDb, Rotten Tomatoes and
  Metacritic), when they go under the text, centered, with an empty line between. The year, which leads the first line, is in black and the rest of the
  line gray (the user's request, 2026-11-22; all of it was gray). The toolbar's picker of where to play has "Play on" before
  the device's name ("Play on This Mac"), which alone didn't say what the menu chooses (the
  user's request, 2026-11-22). In the list, an episode's own name is at the end of its name
  line, "The Sopranos S4 E8 · Mergers & Acquisitions" (the user's request, 2026-11-22; it
  was in the line under the name, between the time left and the year, where it was often
  cut off). It gives way first when the row is narrow, and it stays in the lower line for a
  video the person named by hand, whose name is shown as typed. In the list, a video whose file is gone shows its warning
  triangle in red where its picture was (same day; it was gray, as it still is for a file
  that is there but can't be read). An episode's air date is the line under the genres, "Aired 2002-11-03" (the
  user's placing, 2026-11-22; it was a row of its own under the cast). A film with no poster shows a picture taken from the file itself; that
  one is not at the top of the panel, where a poster goes, but under the captions line
  (same day). A real poster stays at the top. For an episode whose own picture is at the
  top, the show's poster is no longer under it at full width (the pair "looked a little
  weird"): it is small (64 points wide) under the episode's name, beside the year and
  genres, which start one line down from the poster's top, with an empty line between the
  episode's name and that row; the picture's place is kept in gray while it loads, and if it doesn't come the
  poster takes the top again. The main window opens 980 by 746
  points the first time (670 high in 1.1.2, 620 before), so that the panel shows an
  episode's still, the show's poster and the title lines under it without scrolling; after
  that macOS remembers the size. The
  panel's own header has a button that folds it away (⌥⌘I brings it back; ⌘I, which
  opened the panel until 1.1.3, now opens the Details window described below). It is a
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
- **Clean names everywhere:** a video is shown by what it is, not its release name:
  "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG" reads "The Sopranos S4 E7" and
  "Heat.1995.1080p.BluRay.x264-GRP" reads "Heat (1995)", without the dots, quality, encoding,
  release group or extension. When space runs short only the name is shortened ("The Sopr…
  S4 E7"), so the episode number or year stays readable. Everyday files are tidied the same
  way where possible: square-bracketed tags at the end ("[dQw4w9WgXcQ]", "[1080p]") and
  hyphens used as spaces go; the dots of a time or date stay ("at 10.30.15", "2024.01.02");
  and a number counts as a film's year only in brackets, at the end of the name or before
  release tags, never inside a date or in the future ("Blade Runner 2049" keeps its number).
  The same name goes to the title card, the Chromecast and the Now Playing panel. New in 1.1.1:
  a release word that is also an everyday word ("Extended", "Proper", "Limited") ends the
  name only when nothing but tags follows it, so "Our Extended Family Christmas" keeps its
  name; of two years in a row the second is the film's ("Wonder Woman 1984 (2020)"); "Heat
  [1995]" keeps its year; a year followed only by the name of a cut is the film's ("Movie 2010
  Directors Cut" is Movie (2010)); "Star Wars Episode 4 A New Hope 1977" is a film, not
  episode 4 of a show; "Spider-Man-2" reads "Spider-Man 2"; and a title corrected by hand is
  the name shown everywhere.
- **A Details window** (new in 1.1.3): Details in a video's right-click menu, or File >
  Details (⌘I) for the selected video (else the playing one), opens a small window (380 by
  720 points, resizable, closed with Esc) with everything the details panel shows, held to
  that video instead of following the selection: poster, title, year, running time, rating,
  genres, review scores, people, plot, the episode, the file with its streams and how it
  would be sent, and its closed captions. There is one such window; Details on another video
  shows that one in it. Until 1.1.3 the command opened the details panel, and with the panel
  already open on that video it changed nothing. The File section (in the panel too) now
  also gives how much has been watched, the file's size and the date it was added to its
  folder.
- **A name of your own** (new in 1.1.3): three ways turn a video's title into a text box
  holding the name, selected to type over. Right-click the video and choose Rename. Or, as
  in the Finder, click the title of the video that is already selected and leave the pointer
  on it: the box opens about a second after the click, unless a second click (a double-click
  plays), a key or a move off the title comes first. A click on any other title only selects
  its row. Or press on any title and hold the mouse button for 0.6 seconds without moving
  it. Return keeps what
  was typed; so does clicking elsewhere; Esc leaves the name as it was. The name is shown as
  typed, with no episode number or year added, in the list, the playback bar, the video
  window's title, the TV's pause and seek panel (as its one line) and the watched list, and
  it heads the details panel when nothing was found online. A Chromecast keeps the name it
  was sent until the video is next started. The name is kept by the file's path, so it is the
  same in every playlist. It says only what to call the video: the file is not renamed, and
  details, posters and subtitles are still looked up by the title read from the file name or
  corrected by hand. Nothing typed, or the name the video has anyway, gives it back the name
  made from its file. A press with Shift, Command, Option or Control held, a double-click,
  and a press that moves more than 4 points (a drag) never open the text box.
- Titles are read from file names: "Heat.1995.1080p.BluRay.x264" is Heat (1995);
  "Sopranos.S1.E11", "Show.S02E05", "Series 3x07" and "Episode 4" are episodes. A result must
  match the title (and the year, when both are known) or it is not shown. "Not this title?
  Search again…" lets you correct the title and year for a file, and the correction is
  remembered; a typed title that finds nothing with the file's year is tried again without it.
- Rows look up their details as soon as they appear. A video played the moment it is added
  waits up to six seconds for that lookup, so the title card and the Chromecast's screen get
  the real poster rather than a frame; the lookup carries on in the background either way.
- Playlist rows show a film's year ("1995") or, for an episode, its name and the year it was
  first shown ("Pine Barrens · 2001"; the number is already in the title line). Until 1.1.2
  a row also showed the first review score ("IMDb 8.3", "TVmaze 8.8"); scores are now in the
  details panel only. The Chromecast shows the poster, with
  the film's year and director or the episode's show, number and name, on its loading and
  pause screens.
- **A title card when a video starts** (switchable): three seconds (five before 1.1.3) of the
  poster beside the title, year, running time, age rating, genres, director, cast and
  ratings, fading in and out. On this Mac and AirPlay it is a short clip stitched in front
  of the film inside the stream, encoded like the film (same codec, bit depth, frame rate and
  sound channels) because an Apple TV stops where the two differ; a Chromecast instead stays on its own poster-and-title
  screen for the same three seconds before playing. HDR films that are passed through get
  no card, so the TV does not switch picture modes twice.
- Only the title and year are sent, never the file; results and artwork are cached, the
  services are asked no faster than they allow, and "Look up posters and details online" in
  Settings turns the whole feature off.

### Subtitles
- Subtitle tracks inside the file in every text format FFmpeg knows (SRT, ASS/SSA, WebVTT,
  MOV text, MicroDVD, SubViewer, SAMI, and more) are sent to the device as text, not drawn
  into the picture.
- Subtitle files next to the video are found automatically when their name is the video's
  name, or goes on from it with a language, a flag or the video's own extension (`Movie.srt`,
  `Movie.en.srt`, `Movie.en.forced.srt`, `Movie.mkv.srt`); "Alien" does not take
  "Aliens.en.srt". The language and "forced" are read from the end of the name. Since 1.1.3
  a `Subs` or `Subtitles` folder beside the video is searched too: a folder there named
  after the video, files there named after it, and everything in it when the video is the
  only one in its folder. Legacy Windows-1252 files are read correctly.
- **Any text encoding:** subtitle files are read as UTF-8, UTF-16 or UTF-32 (with or without a
  byte-order mark), or in the legacy code page their language used (Cyrillic, Central European,
  Greek, Turkish, Hebrew, Arabic, Vietnamese, Thai, Japanese, Chinese, Korean, Western).
- Any subtitle file can be added by hand (SRT, ASS, VTT, SUP, IDX/SUB); it is remembered for
  that video.
- **Picture subtitles become text:** Blu-ray PGS and DVD VobSub subtitles inside an MKV, or as
  `.sup` and `.idx` files, are read with the Vision text recognizer (the vendored macSubtitleOCR
  code) the first time they are used and cached as SRT, so an HEVC film with PGS subtitles plays
  without converting the video. This can be turned off, in which case they are drawn into the
  picture during conversion.
- Other picture subtitles (DVB, XSUB) are drawn into the picture.
- **Nothing comes on by itself** unless asked: Settings > Subtitles has "Always turn on closed
  captions" and "Turn them on when the audio is in another language", in the caption language
  you choose. When one is ticked, a full track in that language is used, else a forced one
  (signs and foreign lines) in it. With "Search OpenSubtitles when the video has
  none in this language" on, a video that lacks them is looked up as it
  starts — fingerprint first, then title (season and episode for a show) — and the best match
  is downloaded, kept with the video and turned on; this takes a few seconds and is tried once
  per video per run.
- **While casting** the video window shrinks to half its size and shows the video under a gray
  veil with a big streaming mark and "Connected to <device>". Under that, new in 1.1.3, two
  short lines say what the file is and what is being done to it: "4K Dolby Vision · HEVC ·
  Dolby Digital+ 5.1" and then "Playing as is", "Repackaged, no quality loss", "Converting to
  1080p H.264", "Picture as is, sound converted to AAC Stereo" or "Sound only" (a speaker),
  with the subtitle that is on after it ("· English subtitles"). A converted picture is named
  the way a file's is, so a wide film sent as 1920x800 reads 1080p. Until the video has been
  read the line is "Streaming video…", as it was before. The picture is
  a silent copy that follows the device's position (the poster stands in until it has a
  picture), and the window keeps only play/pause and the timeline, which moves the position on
  the device. It goes back to its size when playback returns to this Mac. New in 1.1.3: the
  picture's lower left corner shows where the video is and how long is left, in bold type
  sized by the window: "14:08 (22m, 14s left)", the time in white and what is left in
  yellow. What is left is counted to the end credits: the file's credits chapter when it has
  one, else the last 4% of the video (at least 30 seconds, at most a tenth), the point where a
  video also counts as finished. Past it the line gives what is left of the file: "(1m, 40s
  to the end)". An hour or more reads "(1h, 23m, 18s left)". Until the video's length is
  known only the time is shown.
- **Video window footer:** a thin bar under the picture reads "Closed Captions: English,
  Spanish" (or "No closed captions"; "in this video" followed it until 1.1.3) with the same menu as the playback bar.
  Since 1.1.2 the bar is shown only for a video that has captions; with none there is no
  bar, and Find Subtitles Online… is in the Subtitles menu and behind the playback bar's
  button.
- **"I don't care about subtitles"** (Settings > Subtitles) hides that footer and the Closed
  Captions section of the details panel; the menus still work. Since 1.1.2 it is the first
  setting on the page and does more: captions never come on by themselves and none are
  searched for as a video starts, whatever the rules below it say, and the rest of the page is
  grayed out until it is turned off. The rules keep their values and count again then.
- **Subtitle size** is one setting from 60% to 200%, remembered between launches: a slider in
  the menu bar's Subtitles menu (with Larger ⌥⌘= and Smaller ⌥⌘− above it), a Subtitle Size
  submenu with the same steps and presets in the playback bar's and the video window's
  subtitle menus, and the slider in Settings. A change applies at once: this Mac redraws the
  line already on screen at the new size (the player otherwise applies a new size only from
  the next line), and a Chromecast is told the new text style without reloading the video
  (white text with a black outline). An AirPlay TV draws subtitles with its own caption
  settings and ignores the size, so while AirPlaying the size controls are hidden from the
  menus and a line in their place says to change it in the TV's caption settings; the
  Settings slider stays.
- **OpenSubtitles.com search** built in: searches by the file's hash and by title, shows
  language and download count, downloads as SRT and turns the subtitle
  on. Results made for this video are tagged and listed first: **EXACT** when OpenSubtitles
  matched the file's hash, **MATCH** when the subtitle's release name is the file's own or
  comes from the same release group and source (and names no other year or episode; in
  1.1.1 also no other film or cut, and not a whole season's pack). The
  automatic search therefore downloads a matching subtitle first. After those (new in
  1.1.4) come ones tagged **CLOSE**: not this release, but with a name near the video's.
  That is one taken from the same kind of source (both Blu-ray, both DVD, both TV, both
  streaming) and naming no other cut, which is what mostly decides timing, or one that gives
  no source but shares two or more of the release's other words, at least one of them more
  telling than a resolution or a codec (a group, "remastered", "mux").
  Then come ones whose names don't say, then ones from another source or cut. Within each
  group the order is by how many of the video's release words the name shares, and only
  then by downloads. With nothing made for the video, a yellow line above the results says
  so: "No subtitles found for this exact file name. The first 3 are close to it.", or, when
  none is near, "No subtitles found for this file name, and none of these are close to it.
  They may be out of sync." A file whose own name describes no release (a renamed copy)
  can have no CLOSE results. The hearing-impaired column was taken out (the user's request,
  2026-11-21). **Looked up by itself** (new in 1.1.4): a video with no captions in the subtitle
  language is searched for on OpenSubtitles as soon as the details panel shows it or it
  starts playing (searches cost nothing; downloads do, so nothing is downloaded until asked).
  When something is found, a pill beside "No closed captions" in the details panel and in the
  video window (whose captions bar then shows for that video) says how good a match it is:
  "Exact match found" or "Same release found" in green, "Close match found" in blue. Only
  those likely to fit are offered: subtitles for the same title only (another source, or a
  name that says nothing) get no pill, bubble or card, and stay in Find Subtitles Online.
  A bubble opens from the pill once per video, tagged EXACT MATCH, SAME RELEASE or CLOSE MATCH: for a subtitle made from this very file, "Found subtitles for
  this movie (or show). Would you like to add them?"; otherwise it says how near the subtitle
  is to the file. Add Them downloads and adds it (on at once while the video plays), Not Now
  closes it, "See all on OpenSubtitles…" opens the full search. The captions section of the
  panel has the same offer in a card of its own above the Closed Captions section, tinted
  by the match, with Add Them and the link to the full search; the section itself says
  "Looking on OpenSubtitles…" while it looks, or "None on OpenSubtitles either." In the
  panel's captions line the pill sits on its own line under "No closed captions". Lookups
  are kept in `online-subtitles.json`: a subtitle worth offering for 30 days, nothing (or
  nothing worth offering) for 3; a search that failed is tried again the next time the video
  is shown. With "I
  don't care about subtitles" on, nothing is looked up or offered. **Remove Subtitle** (new in
  1.1.4, the user's request: one that wasn't in sync could only be turned off and stayed in
  the video's menus for good): a submenu in the Subtitles menu, the details panel's captions
  menu and the video window's CC menu lists the subtitle files attached to the video (added
  from the disk or from OpenSubtitles; tracks inside the video and files beside it can't be
  removed and aren't listed), and the details panel shows a Remove button beside the captions
  menu when such a file is the one chosen. Removing takes the file off the video in every
  playlist (`Library.detachSubtitle`), turns subtitles off if it was on, and leaves the file
  on the Mac. One that came from OpenSubtitles (told by the result number in its name,
  `OpenSubtitlesClient.fileID(ofDownloaded:)`) is remembered per video in
  `online-subtitles.json` and is passed over from then on, by the lookup and by the search
  made as a video starts; the video is looked up afresh, so the next best can be offered. **In the subtitle menus**
  (the user's request, 2026-11-22: the match showed only in the bubble and the card): when
  the lookup has a likely match for the video, the Subtitles menu, the details panel's
  captions menu and the video window's CC menu carry an item named for it, "Add English
  Subtitles Found Online (Close Match)" (`OnlineSubtitleLookup.menuTitle`), which downloads
  it, adds it and turns it on in one click (`PlaybackController.addFoundSubtitle`); a
  failure shows in an alert, a menu having nowhere to say it. The item goes once the video
  has subtitles in the language. For an episode of a show the window says
  which one beside the title box ("Season 1, Episode 2"), since the search is narrowed to it;
  a film shows nothing there. Nobody is asked for a key:
  Driftcast sends its own (one per app, not per person), and since 1.1.4 the app has no
  screen, button or setting about keys. The key is built in from the builder's keychain, never
  kept in the repository or as plain text in the app (SHIPPING.md section 2a). OpenSubtitles
  counts downloads per network address; a refused key shows as "OpenSubtitles isn't answering
  Driftcast right now" and is logged.

### Playlists and library
- Any number of named playlists in a sidebar; rename, delete, add videos or folders to each.
- Drag files or folders into the window, the sidebar, or onto the Dock icon, or use "Open
  With" from the Finder. Folders are searched recursively and sorted the way the Finder sorts.
  Through 1.1.2, a video opened from the Finder while Driftcast was
  already running was listed and then the app quit: SwiftUI answers an open by closing a
  single window and making it again, and closing the main window quits Driftcast. Both
  windows now decline such events (`handlesExternalEvents(matching: [])` on the scenes) and
  the app delegate alone takes the files.
- **Open…** (new in 1.1.2): File > Open… (⌘O), or the folder button beside the playlist's name,
  chooses videos or folders from the Mac, adds them to the playlist and plays the first, as
  opening a video from the Finder does. A video that is already listed plays from its row and
  isn't listed twice. Choosing something with no video in it says so.
- **Add Videos…:** the + button beside the folder, or File > Add Videos… (⇧⌘O), lists what is
  chosen and leaves whatever is playing alone. In 1.1.1 this was the only command, on ⌘O.
- **Show playlists:** dropping two or more episodes of one show (`Sopranos.S1.E11.mp4`,
  `Show.S02E05.mkv`, `Series 3x07`, `Episode 4`, names that differ only by a number) creates a
  playlist named after the show, in episode order, or adds to an existing one without
  duplicates. An unrelated film in the same drop stays where it was dropped.
- **A playlist for each season** (new in 1.1.2): the show's episodes are split by season, so
  dropping or opening seasons 1 and 2 of a show makes "Sopranos S1" and "Sopranos S2", each in
  episode order, with season 1 shown. A single season still gets its season in the name, so a
  later season lands beside it and not in it. Episodes whose names carry no season number
  (`Episode 4`, names that differ only by a number) stay in one playlist named after the
  show. One episode added on its own stays where it is dropped, since a playlist isn't made
  for a single video, unless its season already has a playlist, which it then joins. Since
  1.1.3 episodes added to a season that is already listed go to their place in episode
  order (episodes 1 to 10 added after 11 to 13 come first) for as long as the list is still
  in file-name order; a list whose rows have been dragged about gets them at the end. An
  empty, untouched playlist that is dropped on becomes the first season's. A
  playlist made by 1.1.1 that is named after the show and holds a single season is renamed
  to that season when more of the show is added; one that mixes seasons is left alone.
- Each row shows a poster frame, the cleaned name, the time left, the stream summary (codec,
  resolution, HDR, audio, track and subtitle counts), and on the right the duration with a bar
  under it of how much has been watched. The bars form one column down the list: blue while
  there is more to watch, green once the video is finished. A video counts as finished where
  its end credits start; its row then says "Finished" instead of the time left and is faded,
  with a checkmark.
- **Sort** (new in 1.1.3), in the right-click menu of a video or of the empty space, puts
  the playlist in order once: By Name (the name each video is shown by, capitals ignored and
  numbers in counting order, so "E2" comes before "E10"), By Date Added (when each file
  arrived in its folder, as the Finder's Date Added has it, newest first; a file that can't
  be found goes last) or Unwatched First (finished videos after the rest). Videos that
  compare the same keep their order. Nothing stays sorted: videos added later go to the end,
  and the order is still yours to change by dragging.
- **Added videos are shown** (new in 1.1.3): after a drop, Add Videos… or Open…, the first
  video added is selected and the list scrolls to it. When everything dropped was listed
  already, the first of those rows is selected instead.
- Under "Nothing playing" the playback bar says "Double-click a video to play it" (it said
  "Not playing" until 1.1.3, the same thing twice).
- Resume where you left off (positions saved every five seconds and on quit); "Play from
  Beginning" clears the position; mark videos watched or unwatched by hand.
- Autoplay of the next video in the playlist; Next and Previous buttons and shortcuts.
- Reorder by drag, move videos between playlists, take videos out of a playlist with the Delete
  key or the right-click menu (the file stays where it is), or delete a video's file from the
  right-click menu after confirming; remove with the Delete key or the right-click
  menu. Missing files are flagged.
- The library is a JSON file in Application Support, written after every change and again on
  quit.
- **A list of the videos you watch** (new in 1.1.1): each video that starts playing is added to
  a list with its file name, its cleaned name and when it was played. File > Export Watched
  Videos… saves it as a CSV spreadsheet with those three columns in that order, newest first.
  Starting the same video again within 30 minutes counts as the same viewing. It can be
  turned off in Settings > General. In 1.1.1 the list is two files in the Movies folder:
  "Videos I have watched on Driftcast" to read, and a JSON file (`filename`, `title`,
  `played`) under it.
- **The list is kept out of sight** (new in 1.1.2): it is one JSON file inside the app's own
  data folder, `~/Library/Application Support/Driftcast/watched-videos.json`, where nobody
  looking through your folders comes across it, and Export (the File menu, or the button in
  Settings > General) is how it comes out. The two files 1.1.1 put in Movies are taken in and
  removed when the app opens; one edited so that it can't all be read is moved into the data
  folder whole instead of being deleted. Out of sight is not locked: the file is plain JSON.
- **Undo** (new in 1.1.3): Edit > Undo (⌘Z) takes back Remove, Move, Sort, Rename, Add
  Videos, and New and Delete Playlist, and Redo puts them back.
- **Missing videos** (new in 1.1.3): a video whose file is gone says so in its row, checked
  off the main thread so a disk that has stopped answering can't freeze the list, and again
  when Driftcast comes to the front. Right-click > Locate… points one at its file's new
  place, keeping its name, subtitles and place in the list (Locate… itself can't be undone,
  and the steps before it are forgotten); Remove Missing Videos clears the ones that are
  gone. A video on a disk that is only unplugged is not counted as gone.
- **Playlists can be reordered** (new in 1.1.3) by dragging them in the sidebar.
- **A playlist from a drop** (new in 1.1.3): videos dropped between or below the playlists,
  from the Finder or dragged out of the list, get a playlist of their own where the line
  was drawn, named after them: the
  season of a show ("The Sopranos S4" for The.Sopranos.S04E12), the show when they span
  seasons (then split by season as usual), a film's title, or what their names share. A
  playlist of that name that is already there takes them instead. Rows dragged from the
  list onto a playlist move there (Option copies); the drag carries a Driftcast-only type,
  never the file, so a row dropped on the Finder copies or moves nothing. Which rows a
  drag holds is noted inside the app as it starts, because macOS would not hand the data
  back at the drop; and the space below the playlists takes rows as an insert into the
  sidebar's table, which otherwise claims a row's drag as a reorder of its own and refuses
  it.
- **Saved playlists that can't be read** (since 1.1.3) are never replaced: the list starts
  empty, and the first change moves the unreadable file aside as `library.unreadable.json`
  before anything is saved. The same goes for corrected titles, typed names and the watched
  list.

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
- Closing the main window quits the app. Closing the video window keeps a device playing, but
  pauses a video playing on this Mac; it also pauses if AirPlay ends while the window is closed,
  rather than going on as sound alone. Play opens the window again.

### Menus and shortcuts
- **Driftcast:** About Driftcast (the full description, requirements, license and website),
  Check for Updates… (also a button in the About window), Settings…
- **File:** Open… (⌘O) and Add Videos… (⇧⌘O) (new in 1.1.2; before, Add Videos… was ⌘O and
  there was no Open…), New Playlist (⇧⌘N), Details (⌘I; since 1.1.3 a window of its own,
  disabled with no video selected or playing), Show in Finder (⇧⌘R), Export Watched Videos…
  (new in 1.1.1).
- **View:** Show Details (⌥⌘I), plus the standard sidebar and toolbar items.
- **Playback:** Play/Pause (⌘P), Stop (⌘.), Skip Forward/Back 10 Seconds (⌥→ / ⌥←), Skip
  Forward/Back 1 Minute (⌥⇧→ / ⌥⇧←), Next/Previous Video (⇧⌘→ / ⇧⌘←), Volume Up/Down (⌘↑ / ⌘↓),
  Mute (since 1.1.3; it follows a TV muted with its own remote), Audio Track submenu, Volume Booster, Downmix to Stereo, Audio Delay (⌥⌘] later, ⌥⌘[
  earlier, Reset).
- **Output:** This Mac, Apple TV or AirPlay TV…, every Chromecast found (speakers in a
  submenu), Disconnect from Chromecast, Search for Devices Again.
- **Subtitles:** Off, every subtitle track and file, Add Subtitle File…, Find Subtitles
  Online…, Larger Subtitles (⌥⌘=), Smaller Subtitles (⌥⌘−), the Subtitle Size slider (these
  three are hidden while AirPlaying), Subtitle Settings…
- **Help:** Driftcast Help, Report a Problem…, Driftcast on GitHub,
  Driftcast Website, Show Error Log (new in 1.1.1).
- **Right-click on a video:** Play / Resume from 12:34 / Pause / Stop, Play from Beginning, Add
  Subtitle File…, Find Subtitles Online…, Details (the Details window), Rename (with one
  video clicked; new in 1.1.3), Show in Finder, Mark as Watched / Unwatched, Move to Playlist
  (any playlist or a new one), Select All, Sort (new in 1.1.3), Add Videos…, Remove from
  Playlist,
  Delete File… (asks "Do you really want to delete this file?", then moves the file to the
  Trash, stops it if it is playing, and takes it out of every playlist; the only command in
  the app that touches a file on disk). New in 1.1.1: a file listed twice is moved once, and a
  file already deleted in the Finder just leaves the playlists. A file that can't be moved
  stays listed, with the system's reason shown and written to the error log.
- **Right-click on a playlist:** Rename, Add Videos…, Delete Playlist. Since 1.1.2: New
  Playlist and Delete Playlist come first, then Rename and Add Videos…; the menu is the
  list's, not the name's, so it opens anywhere on the row; and a right-click in the empty
  space under the playlists offers New Playlist. Delete Playlist takes the playlist out of
  the sidebar at once, without asking; the videos' files are not touched, and the last
  playlist can't be deleted.
- In the list: Space plays or pauses, Return plays the selected video, Delete removes it from
  the playlist (the file stays).
- **Select All** (new in 1.1.2): ⌘A selects every video in the playlist wherever the keyboard is
  in the main window, the sidebar included; while text is being typed it selects the text.
  Select All is also in the right-click menus. In 1.1.1, ⌘A worked only after a click in the
  list.

### Settings
- **General:** resume where you left off (the next video always plays on; until 1.1.3 that
  was a switch here); keep a list of
  the videos you watch, with Show in Finder (new in 1.1.1; since 1.1.2 the button is
  Export…); look up posters
  and details online, OMDb API key, show poster when a movie starts (the title card, three seconds);
  check for updates automatically, last check, Check Now. Until 1.1.3 it also chose which
  ffmpeg to use (the built-in copy, or a folder of your own); a folder chosen then is still
  used. Since 1.1.3 the Settings panes carry no explanatory paragraphs under the poster
  switch, "I don't care about subtitles" or the picture-subtitle settings.
- **Video:** convert on the GPU (VideoToolbox); conversion quality; maximum resolution; always convert; HEVC
  on Chromecast (automatic by model, always, never).
- **Audio:** preferred audio language; surround conversion for Apple devices (Dolby Digital
  Plus 5.1, lossless FLAC, stereo AAC); Chromecast stereo codec (AAC or Opus); pass through
  Dolby surround to Chromecast.
- **Subtitles:** always turn on closed captions; turn them on when the audio is in another
  language; caption language; search OpenSubtitles when the video has none in that language;
  convert picture subtitles to text; subtitle size; "I don't care
  about subtitles".
- Changing a conversion setting while a video plays re-plans and restarts the stream at the
  same position a second later.

### Updates, about, license
- Checks the project's GitHub releases at launch and every eight hours (switchable) and offers
  a new version in a dialog ("Update version X available"): Update Now (downloads it, checks it is signed by Leech Software, closes and reopens as the new version), Remind Me Later, Skip This Version.
- About window with the version, "by Leech Software" linking to leechsoftware.com, how it
  works, what it plays, what you need, tips, the freeware statement, copyright, trademarks, and
  buttons for the license and acknowledgements.
- Freeware: no trial, no time limit, no license key, no account, no ads, no analytics.
- Open source under the GNU General Public License v3; FFmpeg (GPL) and macSubtitleOCR (MIT)
  are credited in `NOTICE.md`, which is also inside the app.
- Universal app (Apple silicon and Intel), Developer ID signed and notarized, macOS 13 Ventura
  or later. Nothing to install besides the app: FFmpeg is inside it.

### Diagnostics
- Every request a device makes to the built-in server and every player event is logged to the
  unified log (subsystem `com.leechsoftware.driftcast`), readable in Console or with
  `/usr/bin/log stream`.
- **Error log** (new in 1.1.1): each failure is written as one line to
  `~/Library/Logs/Driftcast/Errors.log` with the time, the version, what was being done, the
  file, the system's reason and its error numbers. Logged: a video that won't start or stops
  with an error, a TV that connects over AirPlay but never asks for the video, a file that
  can't be moved to the Trash, a failed subtitle search or download, a failed update, a failed
  Chromecast search, a poster card that couldn't be made (ffmpeg can't make one for Dolby
  Digital Plus in 6.1 or 7.1; the film plays without it), and a watched list that can't be
  written. New in 1.1.2: playlists that can't be saved, saved playlists found changed by
  something other than this copy, and another copy of Driftcast that was closed, or made way
  for, at launch. Help > Show Error Log shows the
  file in the Finder. Past 512 KB the older half is dropped.
- The details panel's File section shows a file's streams and, for the current output
  device, exactly what would be passed through, converted or drawn in, and why. Since
  1.1.3 Container is one name, chosen by the file's extension ("MP4"), where it used to
  list the whole family ffprobe's reader covers ("mov,mp4,m4a,3gp,3g2,mj2").
- The audio adjustments popover shows the same "Stream" notes for the playing video.

---

## How a video reaches the TV

1. **You pick a video** (double-click, Return, the right-click menu, or autoplay). Driftcast
   saves the previous video's position, then probes the file with `ffprobe` (JSON output,
   cached per file): duration, container, bit rate, the video stream (codec, profile, level,
   pixel format, size, frame rate, color transfer, Dolby Vision side data), every audio stream
   (codec, profile, channels, language, title, default flag), every supported subtitle
   stream (codec, language, title, default and forced flags), the title written into the file,
   and the chapters, from which the start of the end credits is taken.

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
     text subtitle (AVPlayer can't side-load one) and HEVC is tagged `hvc1`. A local file
     whose own title tag differs from its cleaned name (release files often carry the release
     name there) is repackaged instead, since a TV reading the file shows that tag; the HLS
     output carries no tags. Everything else goes through HLS.
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
   picture size and encoded by a second ffmpeg into a short clip with silent sound while the
   first segments are produced, in the film's own formats (`TitleCard.Format`: HEVC Main 10
   before 10-bit HEVC, H.264 before converted video, and the film's audio codec, channel
   layout and sample rate). The playlist places it before the segment where playback
   starts, between `EXT-X-DISCONTINUITY` tags with its own `EXT-X-MAP`. Every position the device reports is mapped back to film time, and
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
   observer): position, state, volume, finished or error. Progress is saved; once the end
   credits start the video is marked watched, and at the end the next one starts.

---

## The media server

- An HTTP/1.1 server on Network.framework listening on every interface at port **48100** (or a
  system-chosen port if that is taken), handling GET, HEAD and OPTIONS with keep-alive.
- Paths, all under a random per-session id so nothing else on disk is reachable:
  - `/s/<id>/media.<ext>`: the original file with byte ranges (direct play).
  - `/s/<id>/master.m3u8`: HLS master for AVPlayer and AirPlay, with a WebVTT subtitle
    rendition when subtitles are on. Its `BANDWIDTH` is the same estimate as the Chromecast's
    (since 1.1.5; it was a fixed 20 Mbps, which a TCL Roku TV refused over AirPlay).
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
  without video output are listed as speakers; the model name is the fallback. The search
  runs from launch; after five seconds with nothing found the menus say so ("None found on
  this network", "No Chromecasts on this network").
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
- **Since 1.1.3** only Driftcast's own media session on the TV is followed, so another
  phone casting to the same TV is not taken for Driftcast's video; the volume slider follows
  the TV's own volume and mute; playback stopped by voice or from another device is noticed;
  and a dropped connection shows "Reconnecting to …" in the bar and rejoins the playing
  video where it was, paused if it was paused, without relaunching the player on the TV.
- **Not yet verified on hardware.** No Chromecast was available during development. The
  implementation follows Google's documentation and the pychromecast and node-castv2
  projects, and the playlist attributes Google's player documents as required are present.
  That includes all of the 1.1.3 changes above.

---

## This Mac and AirPlay, in detail

- Playback on the Mac uses `AVPlayer` with the standard `AVPlayerView` controls, floating
  controls, full screen and picture in picture. AirPlay is `AVPlayer`'s external playback: the
  TV fetches Driftcast's URLs itself, so HEVC, HDR and Dolby audio reach it untouched.
- The AirPlay list is the system's own. The toolbar's AirPlay button and the "Apple TV or
  AirPlay TV…" items in the Output menus open it through the AirPlay button of the video
  window's player (`AVPlayerView`), the only picker that moves the video: an
  `AVRoutePickerView` the app makes lists the same devices, but on macOS 26 choosing a TV in
  it leaves the video on the Mac. With a video loaded and its window closed, the window opens
  first; with nothing loaded, the toolbar's own picker is the fallback. Confirmed on an
  AirPlay TV.
- The TV's own pause and seek panel shows the cleaned name, short enough not to wrap: an
  episode is the show's name over "Season 4, Episode 7"; a film is its name, without the year
  once it has been found online (the title card showed it), with the year when it hasn't. The
  panel itself is drawn by the TV.
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
  and `.idx`/`.sub` files directly. Each image is recognized with the Vision framework in the
  track's language, your preferred language and English; results are written through an SRT
  fixer and cached in Application Support/Driftcast/OCR keyed by file, modification date and
  track. Without OCR (or for DVB/XSUB), the subtitle is overlaid onto the video during
  conversion.
- Since 1.1.3 the MKV reader keeps every element inside its parent and the file (a file
  still being written, or a damaged one, ends the reading instead of looping), reads tracks
  packed with zlib or header stripping (bzip2, LZO and encrypted ones are burned in), and
  reads only the track that was chosen. The pictures go through Vision's older request
  (`VNRecognizeTextRequest`): macOS 15's newer one crashed inside Vision when several
  pictures were read at once on macOS 26.2, and was about three times slower one at a time.
  One reading uses Vision at a time; it reports its progress, stops when the video is
  stopped, and a track that failed is not tried again until the next launch. "Read Subtitles
  Again" in the subtitles menu throws the kept text away and reads the pictures again.
- Languages: three-letter container codes are mapped to two-letter codes and localized names;
  a file suffix is treated as a language only when the system knows a name for it, so
  `Up.srt` isn't "language up".
- OpenSubtitles: REST API v1 with the app's or your key; search parameters sorted and
  lower-cased as the API requires; the 64-bit movie hash (file size plus word sums of the first
  and last 64 KiB) finds exact releases; downloads land in Application
  Support/Driftcast/Subtitles as `Title.lang.id.srt` (`Title.lang.forced.id.srt` for one that
  covers only the foreign-language lines) and are attached to the video. A file already
  downloaded is used again. Portuguese, Chinese and Norwegian are asked for as `pt-br,pt-pt`,
  `zh-cn,zh-tw` and `no`. Forced-only results are listed last and marked, and the automatic
  search never picks one.

---

## Library and playlists, in detail

- `library.json` in `~/Library/Application Support/Driftcast/` holds playlists (id, name,
  items with id, URL and attached subtitle files), progress per file path (position, duration,
  updated), the set of watched paths and the selected playlist. Writes are coalesced (0.5 s)
  and forced on quit. Since 1.1.2 they go through one queue, so they land in the order they
  were made and the write at quit waits for one already under way; a write that fails goes to
  the error log. Reading the file at launch writes nothing; until 1.1.3 it scheduled a save
  of the list just read.
- **One copy at a time** (new in 1.1.2): every write replaces the whole file with the list
  the running copy holds, so two copies open together each erased what the other had added.
  That happens without anyone meaning it: macOS opens a double-clicked video with the newest
  copy of Driftcast it knows of, in whatever folder, even while another copy is running (one
  in Applications and one in Downloads, or one still on its disk image). The copy being
  opened now asks any copy already running to quit, which makes it save its playlists and
  the place in what it was playing, waits up to six seconds for it to go, and only then
  reads the playlists. If the other copy doesn't quit (it has a question on screen), the new
  one brings it forward and quits instead, touching nothing. Both are noted in the error
  log. A copy that finds the file changed by something else notes that too, once. Versions
  before 1.1.2 know nothing of this, so an older copy opened after a newer one still runs
  beside it. `-AllowSecondCopy YES` on the command line lets a copy start beside another,
  for a test run with its own data folder.
- Progress rules: a video is finished where its end credits start. When the file has a
  chapter named for them in its second half ("End Credits", "Credits", "Abspann",
  "Générique", "Titoli di coda" and other languages), that chapter's start less 10 seconds
  counts (new in 1.1.1: the first such chapter, so a "Post-Credits Scene" chapter doesn't move
  it later); otherwise the last 4% of the file (at least 30 s, at most 10%) is taken as the
  credits. Positions under 10 s are not saved (so a rewind to the start keeps the old resume
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
| `~/Library/Application Support/Driftcast/title-names.json` | names typed in the list with Rename (new in 1.1.3) |
| `~/Library/Application Support/Driftcast/online-subtitles.json` | what OpenSubtitles had for each video looked up by itself (new in 1.1.4): the best result, kept 30 days when worth offering, else 3; and, per video, the results that were added and then removed, which are not offered again |
| `~/Library/Application Support/Driftcast/watched-videos.json` | the list of videos played (since 1.1.2; in 1.1.1 it is `~/Movies/Videos I have watched on Driftcast.txt` and `.json`) |
| `~/Library/Logs/Driftcast/Errors.log` | the error log (new in 1.1.1) |
| `$TMPDIR/DriftcastStreams/<pid>/<session>/` | HLS segments while a video plays; removed when it stops and at quit; folders of copies that are no longer running are cleaned at launch |
| `~/Library/Preferences/com.leechsoftware.driftcast.plist` | settings |
| `Driftcast.app/Contents/Resources/ffmpeg/` | the bundled ffmpeg and ffprobe with their licenses |
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
  and the note in the stream details says so. Passed through, it is labeled correctly.
- No spatial audio virtualization, no phone remote, no network speed test.
- Dolby Vision is passed through as HEVC to devices that report HDR support; whether a given
  TV shows the Dolby Vision layer or only the HDR10 base layer depends on the TV, and
  dual-layer (profile 7) files have not been tested.
- AirPlay to a device the Mac cannot reach on its chosen address (two networks, VPN, firewall)
  shows the warning banner but cannot be fixed from inside the app.
- **One copy at a time** was tried with two hidden test copies under a test identifier: the
  running one saved and quit and the new one carried on; a copy frozen so it couldn't answer
  was left alone and the new one quit. It has not been tried by double-clicking a video in
  the Finder with two real copies installed, and a copy older than 1.1.2 opened second is
  not stopped.
- **What was added for 1.1.3** (20 November 2026). The logic harness (659 checks then; 679 in 1.1.4, the new ones on the built-in key's file,
  subtitle closeness and order, the search's notice and the lookup's offers and cache) covers the
  names, the orders, the time left, playlists and their saved files, missing videos, where
  later episodes go, the updater, the subtitle readers and the Chromecast messages. The rest
  was tried on screen on macOS 26.2, in a separate copy of the app driven with posted mouse
  and key events:
  - Rename from the menu, by a press held on a title, and by a click on the selected title
    and a wait; that a first click, a double-click, a click followed by a key or by moving
    off the title, open no text box.
  - ⌘ with an arrow in the title box; the arrow keys after Return; Space starting the
    selected video with nothing playing.
  - The video window opening beside the main window in the video's shape, staying in front
    after a click on the main window, keeping its shape when resized, and coming back where
    it was.
  - Files dragged in from another program onto a row of the list, onto the empty part of
    the list and onto playlists in the sidebar, given as paths and as file references;
    two earlier episodes dropped on a season of three going in ahead of them.
  - A row of the list dragged, by its title and from beside it, to a new place in the list,
    onto a playlist (it moved there) and below the playlists (a film made a playlist of its
    name); a file from another program dropped below the playlists and onto one.
  - The video window's own bar: its seven controls are there, and forward 10 seconds moved
    the clock by ten; the window moving with the main window, staying in front after clicks
    in it, and coming back from the Dock in front.
  - A playlist dragged to a new place in the sidebar; Undo and Redo of a drop and of Remove
    Missing Videos; Mute from the Playback menu; a video whose file was taken away saying
    "File not found" and offering Locate… and Remove Missing Videos.
- **Not tried for 1.1.3:** a drag from the Finder itself (a stand-in program supplied the
  files); several rows dragged at once to the sidebar; full screen from the video
  window's bar, a double-click or the green button; Space with the keyboard in the video
  window; when the bar shows and hides; Next and Previous selecting their row; an
  episode's still above the poster on screen; Locate…'s file panel; a drag of the video window by its title bar (posted events
  don't move a window on macOS 26); the Details window on screen (its view was drawn off
  screen and looked at); the time label and the details lines while casting (the wording
  is checked by the harness, and the layout was drawn off screen at two window sizes and
  looked at); anything on a Chromecast or AirPlay
  device; the subtitle search sheet's forced mark and downloads-left line, and the
  OpenSubtitles requests behind them, against the real service; Read Subtitles Again and
  the OCR progress in the bar on a real disc rip; mkvmerge and MakeMKV files (compressed
  tracks were tested with files built by the tests). Undo belongs to the main window: with
  the keyboard in the video window, ⌘Z does not reach the list.

---

## Requirements, building, license

- macOS 13 Ventura or later, Apple silicon or Intel; the Mac and the device on the same network.
- Build with Xcode 16 or later from `Driftcast.xcodeproj`; run `Scripts/bundle-ffmpeg.sh` once
  to fetch the media engine (see `SHIPPING.md` for the universal build and notarization). `Tests/run-harness.sh` runs the logic checks.
- Copyright 2026 Leech Software, Inc. GNU General Public License v3 or later (`LICENSE`);
  third-party components and trademarks in `NOTICE.md`; how to contribute in `CONTRIBUTING.md`.
