# Driftcast privacy policy

Last updated: 9 November 2026

Driftcast is a free, open-source Mac app from Leech Software, Inc. It plays the videos on your
Mac on the devices in your home.

**The short version: Leech Software collects nothing.** There is no account, no analytics, no
advertising, no crash reporting and no server of ours for the app to talk to. Because the source
code is public, you can check every statement below yourself.

## Your videos stay on your network

- Your video files are sent only from your Mac to the device you choose, over your own network.
- Nothing is uploaded to Leech Software or to anyone else.
- The app's built-in media server uses a random address for each video, and it can only reach
  the video you are playing.

## What leaves your Mac, and when

Driftcast contacts four kinds of online service. Each one receives only what is listed here.

| Service | What it receives | When | How to stop it |
|---|---|---|---|
| Wikipedia and Wikidata (films), TVmaze (shows) | The title read from the file's name, with the year, or the season and episode for a show | When a video is added to a playlist | Turn off "Look up posters and details online" in Settings > General |
| OMDb | The same title details, and the key you entered | Only if you enter an OMDb key | Remove the key |
| OpenSubtitles.com | The film or show name, season and episode, the languages you want, a fingerprint computed from the file, and the API key | When you search for subtitles, or as a video starts if you turned on "Search OpenSubtitles when the video has none in this language" | Don't search, and leave that setting off (it is off by default) |
| GitHub | A request for the newest release of Driftcast | At launch and every eight hours | Turn off "Check for updates automatically" in Settings > General |

- The file itself, its folder path and anything about you are never sent to these services.
- The fingerprint sent to OpenSubtitles is a 64-bit number computed from the file's size and its
  first and last 64 KiB. It identifies a release, and the video can't be rebuilt from it.
- Like any website, these services can see your internet address when the app contacts them.
  Their own privacy policies apply to what they do with it.
- If you choose Update Now, the new version is downloaded from GitHub.

## What stays on your Mac

All of this stays on your Mac, and deleting the folders or files removes it.

| Where | What |
|---|---|
| `~/Library/Application Support/Driftcast/` | Your playlists, playback positions and watched marks, corrected titles, downloaded subtitles and text read from picture subtitles |
| `~/Library/Caches/Driftcast/` | Poster frames, keyframe indexes, film and show details and their artwork |
| `~/Library/Preferences/com.leechsoftware.driftcast.plist` | Your settings, including any API keys you enter |
| The system temporary folder | Video segments while a video plays, removed when it stops |
| The macOS unified log | Requests from your devices and player events, for troubleshooting. It is never sent anywhere by the app |

## Permissions

- **Local network:** macOS 15 and later ask once for permission to use your local network. The
  app needs it to find your devices and send them video.
- **Files:** the app reads the videos and subtitle files you add, and subtitle files beside those
  videos.
- The app doesn't use your camera, microphone, contacts, photos or location.

## Children

The app collects no information from anyone, including children.

## Changes

Any change to this policy will appear in this file, in the app's public source code history at
<https://github.com/leechsoftware/driftcast>.

## Contact

Questions are welcome through <https://leechsoftware.com> or as an
[issue on GitHub](https://github.com/leechsoftware/driftcast/issues).
