import AVFoundation
import Combine
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)   // a crash shouldn't lose the lines before it
let mediaDir = URL(fileURLWithPath: CommandLine.arguments[1])
let mkv = mediaDir.appendingPathComponent("Test.Movie.2024.1080p.mkv")
let mp4 = mediaDir.appendingPathComponent("simple.mp4")

// spin, await_, fetch, check and failures are in Tests/HarnessSupport/Helpers.swift, shared
// with the area test files beside it.

Prefs.register()
if let dir = ProcessInfo.processInfo.environment["DRIFTCAST_FFMPEG_DIR"] { Prefs.defaults.set(dir, forKey: Prefs.ffmpegDirectory) }
MediaServer.shared.start()

// Protobuf round trip
let enc = CastProto.encode(source: "sender-0", destination: "receiver-0", namespace: "urn:x-cast:com.google.cast.tp.heartbeat", payload: "{\"type\":\"PING\"}")
let dec = CastProto.decode(enc)
check(dec?.payload == "{\"type\":\"PING\"}" && dec?.destination == "receiver-0" && dec?.namespace.hasSuffix("heartbeat") == true, "Cast protobuf round trip")

// WebVTT parse
let cues = WebVTT.parse("WEBVTT\n\n00:01.000 --> 00:04.000\nA\n\n01:00:02.500 --> 01:00:03.000 align:start\nB\n")
check(cues.count == 2 && cues[0].start == 1 && cues[1].start == 3602.5, "WebVTT parse")

// Probe
let info = try! await_ { try await MediaProbe.shared.probe(mkv) }.get()
print("  mkv:", info.summary)
check(info.video?.codec == "hevc" && info.audio.count == 2 && info.subtitles.count == 1, "probe mkv")
let item = MediaItem(url: mkv)
let choices = SubtitleChoice.available(for: item, info: info)
print("  subtitle choices:", choices.map(\.label))
check(choices.count == 2, "embedded + external subtitle discovered")
let summaryChoices: [SubtitleChoice] = [
    .embedded(MediaInfo.Subtitle(index: 2, codec: "subrip", language: "eng", title: nil, isDefault: true, isForced: false)),
    .embedded(MediaInfo.Subtitle(index: 3, codec: "hdmv_pgs_subtitle", language: "spa", title: nil, isDefault: false, isForced: false)),
    .embedded(MediaInfo.Subtitle(index: 4, codec: "subrip", language: "eng", title: nil, isDefault: false, isForced: true)),
    .external(mediaDir.appendingPathComponent("Movie.en.srt")),
]
check(SubtitleChoice.languageSummary(summaryChoices) == "English, Spanish, English (forced)",
      "closed-caption summary lists each language once, forced marked: \(SubtitleChoice.languageSummary(summaryChoices))")
check(SubtitleChoice.languageSummary([]) == "None", "closed-caption summary of nothing is None")
check(SubtitleChoice.hasFull(summaryChoices, in: "es") && SubtitleChoice.hasFull(summaryChoices, in: "en")
      && !SubtitleChoice.hasFull(summaryChoices, in: "de") && !SubtitleChoice.hasFull(summaryChoices, in: ""),
      "hasFull: Spanish and English (the external file) yes, German no, no language no")
check(!SubtitleChoice.hasFull([summaryChoices[2]], in: "en"), "hasFull: a forced track alone does not count")
check(SubtitleChoice.hasAny([summaryChoices[2]], in: "en") && !SubtitleChoice.hasAny([summaryChoices[2]], in: "es"),
      "hasAny: a forced English track counts as English (no crossed-out mark), not as Spanish")

// Turn-on rules (Settings > Subtitles): never / when the audio is foreign / always
Prefs.defaults.set("es", forKey: Prefs.subtitleLanguage)
Prefs.defaults.set(SubtitleAuto.always.rawValue, forKey: Prefs.subtitleAuto)
let alwaysPick = PlaybackController.preferredSubtitle(summaryChoices, audio: nil)
check(alwaysPick?.language == "spa" && alwaysPick?.isPicture == true, "always: the Spanish track comes on even though it is a picture track")
check(PlaybackController.subtitlesWanted(audio: nil), "always: subtitles are wanted")
check(!PlaybackController.shouldSearchOnline(choices: summaryChoices, audio: nil), "no online search while the video has Spanish subtitles")
Prefs.defaults.set("fr", forKey: Prefs.subtitleLanguage)
check(PlaybackController.preferredSubtitle(summaryChoices, audio: nil) == nil, "always, French wanted: nothing in French, so nothing comes on")
Prefs.defaults.set(true, forKey: Prefs.autoSearchSubtitles)
check(PlaybackController.shouldSearchOnline(choices: summaryChoices, audio: nil) == OpenSubtitlesClient.hasKey, "French missing: OpenSubtitles is asked only when a key exists (\(OpenSubtitlesClient.hasKey))")
Prefs.defaults.set(SubtitleAuto.never.rawValue, forKey: Prefs.subtitleAuto)
check(!PlaybackController.subtitlesWanted(audio: nil) && PlaybackController.preferredSubtitle(summaryChoices, audio: nil) == nil, "never: nothing comes on by itself")
// "I don't care about subtitles" overrides the rule that is set, and gives it back
Prefs.defaults.set("fr", forKey: Prefs.subtitleLanguage)
Prefs.defaults.set(SubtitleAuto.always.rawValue, forKey: Prefs.subtitleAuto)
Prefs.defaults.set(true, forKey: Prefs.hideSubtitleNotices)
check(SubtitleAuto.current == .never && !PlaybackController.subtitlesWanted(audio: nil)
      && !PlaybackController.shouldSearchOnline(choices: summaryChoices, audio: nil),
      "don't care about subtitles: nothing is wanted or searched for, though Always and the search are ticked")
Prefs.defaults.set("es", forKey: Prefs.subtitleLanguage)
check(PlaybackController.preferredSubtitle(summaryChoices, audio: nil) == nil, "don't care about subtitles: a track in the language stays off")
Prefs.defaults.set(false, forKey: Prefs.hideSubtitleNotices)
check(SubtitleAuto.current == .always && PlaybackController.preferredSubtitle(summaryChoices, audio: nil)?.language == "spa",
      "caring again: the rule that was set is back")
for key in [Prefs.subtitleLanguage, Prefs.subtitleAuto, Prefs.autoSearchSubtitles, Prefs.hideSubtitleNotices] { Prefs.defaults.removeObject(forKey: key) }

// Planning
let settings = EncoderSettings.current()
let applePlan = StreamPlanner.plan(info: info, file: mkv, profile: .apple(), settings: settings, audioIndex: 2, subtitle: choices[0], options: PlaybackOptions())
applePlan.notes.forEach { print("  apple:", $0) }
if case .copy = applePlan.videoAction {} else { check(false, "apple copies HEVC") }
if case .encode(.eac3, 6, _) = applePlan.audioAction { check(true, "apple DTS -> EAC3 5.1") } else { check(false, "apple DTS -> EAC3 5.1") }
let castPlan = StreamPlanner.plan(info: info, file: mkv, profile: .chromecast(model: "Chromecast", settings: settings), settings: settings, audioIndex: 1, subtitle: choices[1], options: PlaybackOptions(volumeBoost: true))
castPlan.notes.forEach { print("  cast:", $0) }
check(castPlan.isTranscodingVideo, "basic Chromecast transcodes HEVC")
let mp4Info = try! await_ { try await MediaProbe.shared.probe(mp4) }.get()
let mp4Plan = StreamPlanner.plan(info: mp4Info, file: mp4, profile: .chromecast(model: "Chromecast", settings: settings), settings: settings, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
check(mp4Plan.mode == .direct, "mp4 h264/aac is direct play")

// Direct play over HTTP with ranges
let direct = StreamSession(plan: mp4Plan, source: mp4, duration: mp4Info.duration, grid: nil, cues: nil)
MediaServer.shared.register(direct)
let host = NetworkUtil.primaryIPv4() ?? "127.0.0.1"
print("  LAN host:", host)
let durl = try! await_ { await MediaServer.shared.url(path: direct.directPath, host: host) }.get()
let (st, body, hdrs) = fetch(durl, range: "bytes=100-199")
check(st == 206 && body.count == 100 && (hdrs["Access-Control-Allow-Origin"] as? String) == "*", "range request 206 + CORS")
let size = (try! FileManager.default.attributesOfItem(atPath: mp4.path)[.size] as! NSNumber).intValue
let (st2, body2, _) = fetch(durl)
check(st2 == 200 && body2.count == size, "full GET returns whole file")

// HLS for Apple with subtitles (copy video): complete VOD playlist, keyframe grid
let subCues = try! await_ { try await SubtitleLoader.shared.cues(for: choices[0], media: mkv) }.get()
check(subCues.count == 2, "embedded SRT extracted (\(subCues.count) cues)")
let kf = try! await_ { try await KeyframeIndex.shared.keyframes(for: mkv, streamIndex: 0) }.get()
print("  keyframes:", kf)
let copyGrid = SegmentGrid.keyframes(kf, duration: info.duration)
check(copyGrid.count == 4 && copyGrid.index(at: 25) == 2 && copyGrid.nearestIndex(to: 20.80) == 2, "keyframe grid: \(copyGrid.starts)")
let s1 = StreamSession(plan: applePlan, source: mkv, duration: info.duration, grid: copyGrid, cues: subCues)
MediaServer.shared.register(s1)
// A title card in front of the film: poster frame + title, encoded as its own short clip.
let cardPoster = try! await_ { await Thumbnailer.shared.frame(mkv, at: 5, width: 320) }.get()
var cardDetails = MovieDetails(title: "Test Movie", source: "Test")
cardDetails.year = 2024; cardDetails.runtimeMinutes = 118; cardDetails.certificate = "PG-13"; cardDetails.genres = ["Drama", "Test"]
cardDetails.directors = ["Jane Doe"]; cardDetails.cast = ["Someone", "Someone Else"]; cardDetails.ratings = [.init(source: "IMDb", value: "7.9/10")]
let card = TitleCard.render(poster: cardPoster, title: "Test Movie", details: cardDetails, size: CGSize(width: 1920, height: 1080))
check((card?.count ?? 0) > 20_000 && card?.prefix(2) == Data([0xFF, 0xD8]), "title card rendered as a JPEG (\(card?.count ?? 0) bytes)")
try? card?.write(to: mediaDir.appendingPathComponent("title-card.jpg"))
s1.intro = StreamSession.Intro(card: card!, size: CGSize(width: 1920, height: 1080), atSegment: 0, hardware: true, format: TitleCard.Format(plan: applePlan))
let st1 = await_ { try await s1.start(at: 0) }
check((try? st1.get()) != nil, "apple session started \((try? st1.get()) == nil ? "\(st1)" : "")")
let master = try! await_ { await MediaServer.shared.url(path: s1.masterPath, host: host) }.get()
let (masterStatus, mdata, _) = fetch(master)
let masterText = String(decoding: mdata, as: UTF8.self)
print(masterText.split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
let (_, pl, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("stream.m3u8"))
let plText = String(decoding: pl, as: UTF8.self)
print(plText.split(separator: "\n").prefix(12).map { "  | " + $0 }.joined(separator: "\n"))
check(plText.contains("#EXT-X-PLAYLIST-TYPE:VOD") && plText.contains("#EXT-X-ENDLIST") && plText.contains("seg00003.m4s"), "VOD playlist complete up front")
check(s1.intro != nil && plText.hasPrefix("#EXTM3U") && plText.contains("#EXT-X-MAP:URI=\"intro-init.mp4\"\n#EXTINF:") && plText.contains("intro-0.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:"),
      "title card clip leads the playlist behind a discontinuity (card \(String(format: "%.2f", s1.intro?.duration ?? 0)) s)")
let (introStatus, introInit, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("intro-init.mp4"))
let (introSegStatus, introSeg, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("intro-0.m4s"))
check(introStatus == 200 && introInit.count > 200 && introSegStatus == 200 && introSeg.count > 5_000 && !MP4Boxes.codecs(inInit: introInit).isEmpty,
      "card clip served: init \(introInit.count) bytes (\(MP4Boxes.codecs(inInit: introInit))), segment \(introSeg.count) bytes")
// The card is encoded like the film: an Apple TV stops at a discontinuity where the codecs change.
let (_, filmInit, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("init.mp4"))
let codecKinds = { (d: Data) in MP4Boxes.codecs(inInit: d).map { String($0.prefix(4)) } }
check(!codecKinds(filmInit).isEmpty && codecKinds(introInit) == codecKinds(filmInit),
      "card clip uses the film's codecs: \(codecKinds(introInit)) and \(codecKinds(filmInit))")
let hevcInfo = MediaInfo(duration: 60, formatName: "mov,mp4,m4a,3gp,3g2,mj2", bitRate: nil,
                         video: MediaInfo.Video(index: 0, codec: "hevc", codecTag: "hev1", profile: "Main 10", level: 120, pixFmt: "yuv420p10le", width: 1920, height: 1080, fps: 23.976, colorTransfer: nil, isDolbyVision: false),
                         audio: [MediaInfo.Audio(index: 1, codec: "aac", profile: "LC", channels: 6, language: "eng", title: nil, isDefault: true, sampleRate: 48_000)], subtitles: [])
let hevcPlan = StreamPlanner.plan(info: hevcInfo, file: URL(fileURLWithPath: "/tmp/x.mp4"), profile: .apple(), settings: settings, audioIndex: 1, subtitle: nil, options: PlaybackOptions())
let hevcFormat = TitleCard.Format(plan: hevcPlan)
check(hevcPlan.mode == .hls && hevcPlan.isCopyingVideo && hevcFormat.videoCodec == "hevc" && hevcFormat.tenBit && hevcFormat.audioCodec == "aac"
      && hevcFormat.channels == 6 && hevcFormat.channelLayout == "5.1" && hevcFormat.frameRate == "24000/1001",
      "card format for 10-bit HEVC (hev1) with 5.1 AAC: \(hevcFormat)")
for hardware in [true, false] {
    let dir = mediaDir.appendingPathComponent("card-hevc-\(hardware ? "gpu" : "cpu")")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let jpg = dir.appendingPathComponent("card.jpg")
    try? card!.write(to: jpg)
    let args = TitleCard.ffmpegArguments(card: jpg, size: CGSize(width: 1920, height: 1080), hardware: hardware, format: hevcFormat, outputDirectory: dir)
    let ran = await_ { try await FFmpeg.run(FFmpeg.ffmpeg!, args) }
    let codecs = MP4Boxes.codecs(inInit: (try? Data(contentsOf: dir.appendingPathComponent("intro-init.mp4"))) ?? Data())
    check((try? ran.get()) != nil && codecs.first?.hasPrefix("hvc1.2.") == true && codecs.contains { $0.hasPrefix("mp4a.40.2") },
          "10-bit HEVC card with 5.1 sound, \(hardware ? "on the GPU" : "in software"): \(codecs)")
}
let cardLength = s1.intro?.duration ?? 0
check(s1.deviceTime(forFileTime: 0) == cardLength && s1.fileTime(forDeviceTime: 1) == 0 && abs(s1.fileTime(forDeviceTime: 10) - (10 - cardLength)) < 0.001
      && abs(s1.deviceDuration - (info.duration + cardLength)) < 0.001, "timeline mapping around the card")
let subPlaylist = s1.subtitlePlaylist()
check(subPlaylist.contains("subs-card.vtt\n#EXT-X-DISCONTINUITY\n#EXTINF:") && subPlaylist.hasPrefix("#EXTM3U") && !subPlaylist.contains("#EXT-X-DISCONTINUITY\n#EXTINF:3.500,\nsubs-card")
      && s1.subtitleSegment(Int(subCues[0].start / 10)).contains(WebVTT.stamp(subCues[0].start)),
      "subtitle rendition shares the card's discontinuities and keeps file-time cues")
let s1c = StreamSession(plan: applePlan, source: mkv, duration: info.duration, grid: copyGrid, cues: subCues)
s1c.intro = StreamSession.Intro(card: card!, size: CGSize(width: 1920, height: 1080), atSegment: 2, hardware: true, format: TitleCard.Format(plan: applePlan))
let midSubs = s1c.subtitlePlaylist()
check(midSubs.contains("subs-2.vtt\n#EXT-X-DISCONTINUITY\n#EXTINF:\(String(format: "%.3f", TitleCard.seconds)),\nsubs-card.vtt\n#EXT-X-DISCONTINUITY\n#EXTINF:") && midSubs.contains("subs-3.vtt") && s1c.subtitleSegment(3).contains("WEBVTT"),
      "a mid-file card splits the subtitle segments at the same point: \(midSubs.split(separator: "\n").filter { $0.hasPrefix("subs") || $0.hasPrefix("#EXT-X-D") }.joined(separator: " "))")
let (_, seg1, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("subs-1.vtt"))
print(String(decoding: seg1, as: UTF8.self).split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
// The Chromecast master playlist names the codecs it carries (HEVC Main 10 copied, DTS -> E-AC-3).
let (castStatus, castData, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("cast.m3u8"))
let castText = String(decoding: castData, as: UTF8.self)
print(castText.split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
let castVariant = castText.split(separator: "\n").first { $0.hasPrefix("#EXT-X-STREAM-INF:BANDWIDTH=") }
let castBandwidth = castVariant?.split(separator: ",", maxSplits: 1).first
check(masterStatus == 200 && castBandwidth.map { masterText.contains("\($0),") } == true
      && masterText.contains("SUBTITLES=\"subs\""), "Apple subtitle playlist uses the same stream bandwidth estimate as Cast")
check(castStatus == 200 && castText.contains("CODECS=\"hvc1.2.4.L") && castText.contains(",ec-3\"") && castText.contains("RESOLUTION=1920x1080") && castText.contains("FRAME-RATE=24.000"),
      "cast playlist carries HEVC Main 10 + E-AC-3 codec strings and the picture size")
let initCodecs = MP4Boxes.codecs(inInit: s1.initSegment() ?? Data())
check(initCodecs.count == 2 && initCodecs[0].hasPrefix("hvc1.2.4.L") && initCodecs[1] == "ec-3", "codec strings read from the init segment: \(initCodecs)")
let (partialStatus, partialData, partialHeaders) = fetch(master.deletingLastPathComponent().appendingPathComponent("init.mp4"), range: "bytes=0-99")
check(partialStatus == 206 && partialData.count == 100 && (partialHeaders["Content-Range"] as? String)?.hasPrefix("bytes 0-99/") == true, "range request on an in-memory body")

let s1b = StreamSession(plan: applePlan, source: mkv, duration: info.duration, grid: copyGrid, cues: nil)
s1b.intro = StreamSession.Intro(card: card!, size: CGSize(width: 1920, height: 1080), atSegment: 2, hardware: true, format: TitleCard.Format(plan: applePlan))
let midPlaylist = s1b.mediaPlaylist() ?? ""
check(midPlaylist.hasPrefix("#EXTM3U\n#EXT-X-VERSION:7") && midPlaylist.contains("#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:") && midPlaylist.contains("seg00001.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"intro-init.mp4\"")
      && s1b.deviceTime(forFileTime: 5) == 5 && abs(s1b.deviceTime(forFileTime: 25) - (25 + TitleCard.seconds)) < 0.001 && s1b.deviceStartTime(forFileTime: 22) == copyGrid.start(of: 2),
      "a card before the resume segment sits between two discontinuities; earlier times are unchanged")

// AVPlayer plays it from the start and reports a real duration
let player = AVPlayer()
player.isMuted = true
let avItem = AVPlayerItem(url: master)
player.replaceCurrentItem(with: avItem)
spin(20) { avItem.status != .unknown }
check(avItem.status == .readyToPlay, "AVPlayer ready (\(avItem.error?.localizedDescription ?? "ok"))")
player.play()
spin(6)
let t = player.currentTime().seconds
check(t > cardLength + 0.5, "AVPlayer advanced through the card into the film, at \(String(format: "%.1f", t)) s")
let dur = avItem.duration.seconds
check(abs(dur - (info.duration + cardLength)) < 1.5, "AVPlayer sees the real duration plus the card \(String(format: "%.1f", dur)) (file \(String(format: "%.1f", info.duration)) + card \(String(format: "%.1f", cardLength)))")
let legible = try? await_ { try await avItem.asset.loadMediaSelectionGroup(for: .legible) }.get()
check((legible?.options.count ?? 0) >= 1, "subtitle rendition visible to AVPlayer: \(legible?.options.map(\.displayName) ?? [])")
// Seek far ahead: the server must start a second ffmpeg job there and stitch its segments in.
await_ { await player.seek(to: CMTime(seconds: 31.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity) }
spin(5)
let t2 = player.currentTime().seconds
check(t2 > 32 && t2 < 40 && player.timeControlStatus == .playing, "copy-mode seek past converted range plays on at \(String(format: "%.1f", t2)) s (status \(player.timeControlStatus.rawValue))")
player.pause(); player.replaceCurrentItem(with: nil)
s1.stop()

// Transcode for Chromecast on the fixed 4 s grid, starting mid-file, then seeking back to 0
let castGrid = SegmentGrid.fixed(duration: info.duration)
check(castGrid.count == 10 && castGrid.index(at: 21.9) == 5, "fixed grid \(castGrid.count) segments")
let s2 = StreamSession(plan: castPlan, source: mkv, duration: info.duration, grid: castGrid, cues: nil)
MediaServer.shared.register(s2)
let started2 = await_ { try await s2.start(at: 20) }
check((try? started2.get()) != nil, "cast session started at 20 s")
let curl = try! await_ { await MediaServer.shared.url(path: s2.streamPath, host: host) }.get()
let probe = Process(); probe.executableURL = FFmpeg.ffprobe; let pipe = Pipe(); probe.standardOutput = pipe
probe.arguments = ["-v", "error", "-show_entries", "stream=codec_name,channels,width,height,pix_fmt", "-of", "compact", curl.absoluteString]
try! probe.run(); probe.waitUntilExit()
let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
print(out.split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
check(out.contains("codec_name=h264") && out.contains("pix_fmt=yuv420p") && out.contains("codec_name=aac") && out.contains("channels=2"), "cast stream is H.264 8-bit + AAC stereo")
let cast2 = s2.castPlaylist() ?? ""
check(cast2.contains("CODECS=\"avc1.64") && cast2.contains(",mp4a.40.2\"") && cast2.contains("VIDEO-RANGE=SDR"), "converted stream advertises H.264 High + AAC-LC: \(cast2.split(separator: "\n").last ?? "")")
let p2 = AVPlayer(); p2.isMuted = true
let item2 = AVPlayerItem(url: curl)
p2.replaceCurrentItem(with: item2)
spin(20) { item2.status != .unknown }
check(item2.status == .readyToPlay, "AVPlayer ready on cast stream (\(item2.error?.localizedDescription ?? "ok"))")
await_ { await p2.seek(to: CMTime(seconds: 20, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity) }
p2.play(); spin(5)
let t3 = p2.currentTime().seconds
check(t3 > 22 && t3 < 30, "plays from the mid-file job at \(String(format: "%.1f", t3)) s")
await_ { await p2.seek(to: CMTime(seconds: 1, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity) }
spin(5)
let t4 = p2.currentTime().seconds
check(t4 > 2 && t4 < 10 && p2.timeControlStatus == .playing, "seek back to the start restarts a job there: \(String(format: "%.1f", t4)) s")
p2.pause(); p2.replaceCurrentItem(with: nil)
s2.stop()

// Thumbnail
let thumb = try! await_ { await Thumbnailer.shared.frame(mkv, at: 10, width: 240) }.get()
check((thumb?.count ?? 0) > 1000, "thumbnail frame from MKV (\(thumb?.count ?? 0) bytes)")
print("  movieHash:", OpenSubtitlesClient.movieHash(for: mkv) ?? "nil")
s1.stop(); s2.stop()

// HDR source to a non-HDR Chromecast: hardware tone mapping
let hdr = mediaDir.appendingPathComponent("hdr.mkv")
let hdrInfo = try! await_ { try await MediaProbe.shared.probe(hdr) }.get()
check(hdrInfo.video?.isHDR == true, "HDR detected: \(hdrInfo.video?.hdrName ?? "none")")
let hdrPlan = StreamPlanner.plan(info: hdrInfo, file: hdr, profile: .chromecast(model: "Chromecast", settings: settings), settings: settings, audioIndex: nil, subtitle: nil, options: PlaybackOptions())
hdrPlan.notes.forEach { print("  hdr:", $0) }
let s3 = StreamSession(plan: hdrPlan, source: hdr, duration: hdrInfo.duration, grid: .fixed(duration: hdrInfo.duration), cues: nil)
MediaServer.shared.register(s3)
let ok3 = await_ { try await s3.start(at: 0) }
check((try? ok3.get()) != nil, "HDR transcode started")
_ = try? await_ { try await s3.segment(0) }.get()
let hurl = try! await_ { await MediaServer.shared.url(path: s3.streamPath, host: host) }.get()
let p3 = Process(); p3.executableURL = FFmpeg.ffprobe; let pipe3 = Pipe(); p3.standardOutput = pipe3
p3.arguments = ["-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_name,pix_fmt,color_transfer,color_primaries,width,height", "-of", "compact", hurl.absoluteString]
try! p3.run(); p3.waitUntilExit()
let out3 = String(decoding: pipe3.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
print("  |", out3.trimmingCharacters(in: .whitespacesAndNewlines))
check(out3.contains("codec_name=h264") && out3.contains("color_transfer=bt709") && out3.contains("width=1280"), "HDR tone-mapped to BT.709 H.264 in hardware")
s3.stop()

MainActor.assumeIsolated {
// OCR of picture subtitles (vendored macSubtitleOCR + Vision)
let pgs = mediaDir.appendingPathComponent("pgs.mkv")
let pgsInfo = try! await_ { try await MediaProbe.shared.probe(pgs) }.get()
let pgsChoice = SubtitleChoice.available(for: MediaItem(url: pgs), info: pgsInfo).first { $0.isPicture }!
check(PictureSubtitleOCR.supports(pgsChoice, media: pgs), "PGS in MKV is OCR-able")
let ocrStart = Date()
let ocr = await_ { try await PictureSubtitleOCR.shared.cues(for: pgsChoice, media: pgs, info: pgsInfo, preferredLanguage: "en") }
switch ocr {
case .success(let c):
    c.forEach { print(String(format: "  ocr %.1f-%.1f: %@", $0.start, $0.end, $0.text)) }
    check(c.count == 3 && c[0].text.lowercased().contains("picture subtitle") && c[1].text.lowercased().contains("quick brown fox"), "OCR read the PGS cues in \(String(format: "%.1f", Date().timeIntervalSince(ocrStart))) s")
case .failure(let e): check(false, "OCR failed: \(e)")
}
let supChoice = SubtitleChoice.external(mediaDir.appendingPathComponent("test.sup"))
let ocr2 = try? await_ { try await PictureSubtitleOCR.shared.cues(for: supChoice, media: pgs, info: pgsInfo, preferredLanguage: "en") }.get()
check(ocr2?.count == 3, "external .sup OCR (\(ocr2?.count ?? 0) cues)")

// Playlist reorder without SwiftUI
let lib = Library()
let pid = lib.newPlaylist(named: "harness")
lib.add([mp4, mkv, hdr], to: pid)
lib.move(in: pid, from: IndexSet(integer: 0), to: 3)
var names = lib.playlists.first { $0.id == pid }!.items.map(\.baseName)
check(names == ["Test.Movie.2024.1080p", "hdr", "simple"], "move first to end: \(names)")
lib.move(in: pid, from: IndexSet(integer: 2), to: 0)
names = lib.playlists.first { $0.id == pid }!.items.map(\.baseName)
check(names == ["simple", "Test.Movie.2024.1080p", "hdr"], "move last to start: \(names)")
lib.deletePlaylist(pid)

do {
    let from = lib.newPlaylist(named: "harness-from"), to = lib.newPlaylist(named: "harness-to")
    lib.add([mp4, mkv, hdr], to: from)
    let ids = Set(lib.playlists.first { $0.id == from }!.items.prefix(2).map(\.id))
    lib.moveItems(ids, from: from, to: to)
    check(lib.playlists.first { $0.id == from }!.items.count == 1 && lib.playlists.first { $0.id == to }!.items.map(\.id).allSatisfy(ids.contains) && lib.playlists.first { $0.id == to }!.items.count == 2, "move videos to another playlist")
    lib.deletePlaylist(from); lib.deletePlaylist(to)
}

// Subtitle size: one preference behind the menu slider, Larger/Smaller and Settings, snapped to
// tenths and kept between 60% and 200%.
do {
    let before = Prefs.double(Prefs.subtitleScale)
    SubtitleSize.current = 1.0
    SubtitleSize.increase(); SubtitleSize.increase()
    check(abs(SubtitleSize.current - 1.2) < 0.0001 && SubtitleSize.label(SubtitleSize.current) == "120%", "two steps larger from normal is 120% (\(SubtitleSize.current))")
    SubtitleSize.current = 5
    check(SubtitleSize.current == 2.0 && !SubtitleSize.canIncrease, "the size stops at 200%")
    SubtitleSize.current = 0.1
    check(SubtitleSize.current == 0.6 && !SubtitleSize.canDecrease, "the size stops at 60%")
    check(SubtitleSize.normalized(1.1000000000000001) == 1.1 && SubtitleSize.normalized(0) == 1.0 && SubtitleSize.normalized(.nan) == 1.0, "odd values are snapped or fall back to normal")
    Prefs.defaults.set(before, forKey: Prefs.subtitleScale)
}

// Delete File: the file goes (to the Trash in the app; removed outright here), it leaves every
// playlist, its progress is forgotten, and a file that can't be trashed stays listed.
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("harness-delete-\(UUID().uuidString).mp4")
    let copied = (try? FileManager.default.copyItem(at: mp4, to: tmp)) != nil
    check(copied, "a throwaway copy of the test video exists for the delete check")
    let a = lib.newPlaylist(named: "harness-del-a"), b = lib.newPlaylist(named: "harness-del-b")
    lib.add([tmp, mkv], to: a); lib.add([tmp], to: b)
    lib.markWatched(tmp)
    struct Refused: Error {}
    let stuck = lib.deleteFiles([tmp], trash: { _ in throw Refused() })
    let stillListed = lib.playlists.first { $0.id == a }!.items.contains { $0.url.path == tmp.path }
    check(stuck.count == 1 && stillListed && lib.watched.contains(tmp.path), "a file that can't be trashed stays listed")
    let failed = lib.deleteFiles([tmp], trash: { try FileManager.default.removeItem(at: $0) })
    let inA = lib.playlists.first { $0.id == a }!.items.map(\.url.path)
    let inB = lib.playlists.first { $0.id == b }!.items
    check(failed.isEmpty && !FileManager.default.fileExists(atPath: tmp.path) && inA == [mkv.path] && inB.isEmpty
          && !lib.watched.contains(tmp.path), "a deleted file leaves every playlist and its watched mark goes (a: \(inA.count), b: \(inB.count))")
    lib.deletePlaylist(a); lib.deletePlaylist(b)
}

// Deleting a file that is listed twice, or one already deleted in the Finder, is not a failure
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("harness-delete-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let twice = dir.appendingPathComponent("twice.mp4"), missing = dir.appendingPathComponent("missing.mp4")
    try! Data("x".utf8).write(to: twice); try! Data("x".utf8).write(to: missing)
    let pl = lib.newPlaylist(named: "harness-delete-again")
    lib.add([twice, missing], to: pl)
    var calls = 0
    let both = lib.deleteFiles([twice, twice], trash: { calls += 1; try FileManager.default.removeItem(at: $0) })
    check(both.isEmpty && calls == 1, "a file chosen twice is trashed once (\(calls) tries, \(both.count) failures)")
    try! FileManager.default.removeItem(at: missing)
    let real = lib.deleteFiles([missing])   // the real Trash, on a file that isn't there
    let left = lib.playlists.first { $0.id == pl }!.items.count
    check(real.isEmpty && left == 0, "a file already deleted in the Finder just leaves the playlist (\(real.count) failures, \(left) rows left)")
    let unplugged = URL(fileURLWithPath: "/Volumes/harness-no-such-disk/Movies/film.mp4")
    let away = lib.deleteFiles([unplugged])   // adding skips files that aren't there, so only the answer is checked
    check(away.count == 1, "a file on a disk that isn't connected is reported, not taken as deleted (\(away.count) failures)")
    lib.deletePlaylist(pl)
    try? FileManager.default.removeItem(at: dir)
}

// Open: what is chosen is added, and the answer is the video to play with its playlist
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("harness-open-\(UUID().uuidString)")
    let folder = dir.appendingPathComponent("Folder")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let one = dir.appendingPathComponent("one.mp4"), notes = dir.appendingPathComponent("notes.txt")
    for f in [one, notes, folder.appendingPathComponent("b.mkv"), folder.appendingPathComponent("a.mkv")] { try! Data("x".utf8).write(to: f) }
    let shown = lib.selection
    let pl = lib.newPlaylist(named: "harness-open"), other = lib.newPlaylist(named: "harness-open-other")
    @MainActor func rows() -> Int { lib.playlists.first { $0.id == pl }!.items.count }
    lib.selection = pl
    let first = lib.addToPlay([one], to: pl)
    check(first?.item.url == one && first?.queue.map(\.url) == [one], "an opened video is added and is the one to play")
    let again = lib.addToPlay([one], to: pl)
    check(again != nil && again?.item.id == first?.item.id && rows() == 1, "a video opened again plays from its row and isn't listed twice (\(rows()) rows)")
    let dropped = lib.addToPlay([folder], to: pl)
    check(dropped?.item.url.lastPathComponent == "a.mkv" && dropped?.queue.count == 3, "an opened folder is added and its first video plays, the playlist after it (\(dropped?.item.url.lastPathComponent ?? "nil"), \(dropped?.queue.count ?? 0))")
    let droppedAgain = lib.addToPlay([folder], to: pl)
    check(droppedAgain?.item.id == dropped?.item.id && rows() == 3, "a folder opened again plays its first video from the list (\(rows()) rows)")
    check(lib.addToPlay([notes], to: pl) == nil && lib.addToPlay([], to: pl) == nil && rows() == 3, "a file that isn't a video opens nothing")
    lib.selection = other
    let elsewhere = lib.addToPlay([one], to: pl)
    check(elsewhere?.item.id == first?.item.id && elsewhere?.queue.count == 3, "a listed video opened into a playlist that isn't on show plays from that playlist")
    lib.deletePlaylist(pl); lib.deletePlaylist(other)
    lib.selection = shown
    try? FileManager.default.removeItem(at: dir)
}

// The error log: one line an error, with the reason and the numbers behind it
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("harness-logs-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("Logs/Errors.log")
    let under = NSError(domain: NSOSStatusErrorDomain, code: -5000)
    let refused = NSError(domain: NSCocoaErrorDomain, code: 513,
                          userInfo: [NSLocalizedDescriptionKey: "“a.mp4” couldn’t be moved to the trash.", NSUnderlyingErrorKey: under])
    ErrorLog.record("Delete File", "/Volumes/Films/a.mp4", error: refused, to: file)
    ErrorLog.record("Playback", "first line\nsecond line", to: file)
    ErrorLog.flush()
    let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    check(lines.count == 2 && lines[0].hasSuffix("Delete File: /Volumes/Films/a.mp4: “a.mp4” couldn’t be moved to the trash. [NSCocoaErrorDomain 513, NSOSStatusErrorDomain -5000]"),
          "error log: the reason and its error numbers on one line (\(lines.first ?? "nothing written"))")
    check(lines.count == 2 && lines[1].hasSuffix("Playback: first line | second line") && lines[1].hasPrefix("20"),
          "error log: a message with line breaks stays one dated line (\(lines.last ?? ""))")
    let filler = String(repeating: "x", count: 1000)
    for _ in 0..<700 { ErrorLog.record("Fill", filler, to: file) }
    ErrorLog.record("Last", "kept", to: file)
    ErrorLog.flush()
    let grown = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    check(grown.utf8.count <= ErrorLog.sizeLimit && grown.utf8.count > 100_000 && grown.hasSuffix("Last: kept\n") && grown.hasPrefix("20"),
          "error log: past its limit the older half goes, from a whole line (\(grown.utf8.count) bytes)")
    try? FileManager.default.removeItem(at: dir)
}

// The list of videos played: one JSON file in the app's own data folder, and a spreadsheet to export
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("harness-watched-\(UUID().uuidString)")
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    let a = WatchedList.Entry(title: "The Sopranos S4 E7", filename: "The.Sopranos.S04E07.1080p.mkv", played: t0)
    let b = WatchedList.Entry(title: "Amélie, \"the film\" (2001)", filename: "Amelie, 2001.mkv", played: t0 + 7200)
    let first = try! WatchedList.add(a, in: dir)
    let restarted = try! WatchedList.add(.init(title: a.title, filename: a.filename, played: t0 + 600), in: dir)
    let nextDay = try! WatchedList.add(.init(title: a.title, filename: a.filename, played: t0 + 3600), in: dir)
    try! WatchedList.add(b, in: dir)
    let read = WatchedList.entries(in: dir)
    check(first && !restarted && nextDay && read.count == 3 && read.first == a && read.last == b,
          "watched list: each viewing once, read back as written (\(read.count) entries)")
    let json = (try? String(contentsOf: WatchedList.jsonURL(in: dir), encoding: .utf8)) ?? ""
    let order = ["\"filename\"", "\"title\"", "\"played\""].compactMap { json.range(of: $0)?.lowerBound }
    check(order.count == 3 && order == order.sorted() && json.contains("\"title\": \"Amélie, \\\"the film\\\" (2001)\"") && json.contains("\"played\": \"20"),
          "watched list: JSON has filename, title, played, in that order")
    let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(written == ["watched-videos.json"], "watched list: one file is written, and nothing to read beside it (\(written))")
    check(WatchedList.folder.path.hasSuffix("/Library/Application Support/Driftcast") && !WatchedList.jsonURL().path.contains("/Movies/"),
          "watched list: it is kept in the app's own data folder, not in Movies")
    let csv = WatchedList.csv(read)
    check(Array(csv.utf8.prefix(3)) == [0xEF, 0xBB, 0xBF]
          && csv.contains("File,Title,Played\r\n\"Amelie, 2001.mkv\",\"Amélie, \"\"the film\"\" (2001)\",20")
          && csv.contains("\r\nThe.Sopranos.S04E07.1080p.mkv,The Sopranos S4 E7,20") && csv.hasSuffix("\r\n"),
          "watched list: the spreadsheet quotes commas and quotes, newest first")
    // A row edited by hand into a date the app doesn't write: kept in a copy, not just dropped
    let edited = WatchedList.encode(read).replacingOccurrences(of: WatchedList.encode([b]).split(separator: "\n")[4], with: "    \"played\": \"last Tuesday\"")
    try! Data(edited.utf8).write(to: WatchedList.jsonURL(in: dir))
    try! WatchedList.add(.init(title: "Heat (1995)", filename: "Heat.1995.mkv", played: t0 + 90_000), in: dir)
    let copy = (try? String(contentsOf: WatchedList.unreadableURL(in: dir), encoding: .utf8)) ?? ""
    let after = WatchedList.entries(in: dir)
    check(copy.contains("last Tuesday") && copy.contains("Amélie") && after.count == 3 && after.last?.title == "Heat (1995)",
          "watched list: a row that can't be read is kept in a copy beside the list (\(after.count) entries after)")
    let risky = WatchedList.csv([.init(title: "=HYPERLINK(\"http://x\")", filename: "@file.mkv", played: t0), .init(title: "+1 (2013)", filename: "-30-.mkv", played: t0)])
    check(risky.contains("\r\n'-30-.mkv,'+1 (2013),") && risky.contains("\r\n'@file.mkv,\"'=HYPERLINK(\"\"http://x\"\")\","),
          "watched list: a name that starts like a formula is plain text in the spreadsheet")
    try! Data("not a list".utf8).write(to: WatchedList.jsonURL(in: dir))
    try! WatchedList.add(a, in: dir)
    let aside = (try? String(contentsOf: WatchedList.unreadableURL(in: dir), encoding: .utf8)) == "not a list"
    check(aside && WatchedList.entries(in: dir) == [a], "watched list: a JSON file that can't be read is set aside, not written over")
    try? FileManager.default.removeItem(at: dir)
}

// The list version 1.1.1 kept in the Movies folder is taken in, and nothing is left there
do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("harness-watched-old-\(UUID().uuidString)")
    let movies = root.appendingPathComponent("Movies"), store = root.appendingPathComponent("Store")
    try! fm.createDirectory(at: movies, withIntermediateDirectories: true)
    let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    let a = WatchedList.Entry(title: "Heat (1995)", filename: "Heat.1995.mkv", played: t0)
    let b = WatchedList.Entry(title: "Alien (1979)", filename: "Alien.1979.mkv", played: t0 + 7200)
    let c = WatchedList.Entry(title: "Ronin (1998)", filename: "Ronin.1998.mkv", played: t0 + 90_000)
    let oldJSON = movies.appendingPathComponent(WatchedList.name + ".json"), oldText = movies.appendingPathComponent(WatchedList.name + ".txt")
    func left() -> [String] { ((try? fm.contentsOfDirectory(atPath: movies.path)) ?? []).sorted() }
    try! Data(WatchedList.encode([a, b]).utf8).write(to: oldJSON)
    try! Data("the readable list".utf8).write(to: oldText)
    try! Data("keep me".utf8).write(to: movies.appendingPathComponent("Holiday.mov"))
    try! WatchedList.add(c, in: store)        // played with the new version before the old list was taken in
    try! WatchedList.add(b, in: store)
    try! WatchedList.takeIn(from: movies, to: store)
    var now = WatchedList.entries(in: store)
    check(now == [a, b, c] && left() == ["Holiday.mov"],
          "old watched list: its entries join the new one in the order played, each once, and only its own files leave Movies (\(now.count) entries, left: \(left()))")
    try! WatchedList.takeIn(from: movies, to: store)
    check(WatchedList.entries(in: store) == [a, b, c], "old watched list: with nothing left in Movies, nothing changes")

    // One that was edited by hand and can't all be read: moved in whole, not deleted
    let store2 = root.appendingPathComponent("Store2")
    let edited = WatchedList.encode([a, b]).replacingOccurrences(of: WatchedList.encode([b]).split(separator: "\n")[4], with: "    \"played\": \"last Tuesday\"")
    try! Data(edited.utf8).write(to: oldJSON)
    try! Data("the readable list".utf8).write(to: oldText)
    try! Data("an earlier copy".utf8).write(to: movies.appendingPathComponent(WatchedList.name + " (unreadable).json"))
    try! WatchedList.takeIn(from: movies, to: store2)
    now = WatchedList.entries(in: store2)
    let whole = (try? String(contentsOf: store2.appendingPathComponent("watched-videos (from Movies).json"), encoding: .utf8)) ?? ""
    let kept = ((try? fm.contentsOfDirectory(atPath: store2.path)) ?? []).sorted()
    check(now == [a] && whole.contains("last Tuesday") && whole.contains("Alien") && left() == ["Holiday.mov"] && kept.count == 4,
          "old watched list: one that can't all be read is moved in whole with its text and earlier copy, out of view and not lost (\(kept))")

    // Not a list at all, and a text file with no JSON: moved in, nothing written over
    let store3 = root.appendingPathComponent("Store3")
    try! WatchedList.add(c, in: store3)
    try! Data("not a list".utf8).write(to: oldJSON)
    try! WatchedList.takeIn(from: movies, to: store3)
    try! Data("only the text".utf8).write(to: oldText)
    try! WatchedList.takeIn(from: movies, to: store3)
    let text = (try? String(contentsOf: store3.appendingPathComponent("watched-videos (from Movies).txt"), encoding: .utf8)) ?? ""
    check(WatchedList.entries(in: store3) == [c] && text == "only the text" && left() == ["Holiday.mov"],
          "old watched list: a file that isn't a list, or a text file alone, is moved in and the list here is untouched")
    try? fm.removeItem(at: root)
}

// A title corrected by hand is the name shown everywhere, and the one looked up
do {
    let file = URL(fileURLWithPath: "/tmp/harness-titles/tt0113277.mkv")
    let before = MediaItem(url: file).displayName
    TitleOverrides.set(MediaTitle(title: "Heat", year: 1995), for: file)
    let shown = MediaItem(url: file).displayName
    let lookedUp = try! await_ { await MetadataLookup.shared.title(for: file) }.get()
    try! await_ { await MetadataLookup.shared.setTitle(nil, for: file) }.get()
    let back = MediaItem(url: file).displayName
    check(before == "Tt0113277" && shown == "Heat (1995)" && lookedUp == MediaTitle(title: "Heat", year: 1995) && back == before,
          "corrected title: shown in the list and used for the lookup, and undone with the file name (\(before) -> \(shown) -> \(back))")
}

// A name typed in the list (Rename) is what the video is called, and nothing more
do {
    let file = URL(fileURLWithPath: "/tmp/harness-titles/The.Sopranos.S04E01.1080p.BluRay.x265-RARBG.mkv")
    let item = MediaItem(url: file)
    let before = item.displayName
    var redraws = 0
    let watching = lib.objectWillChange.sink { redraws += 1 }
    lib.setName("  The Sopranos (last)\n", for: file)
    let named = item.displayName
    let tv = item.tvLines(lookedUp: true)
    let lookedUp = try! await_ { await MetadataLookup.shared.title(for: file) }.get()
    let saved = (try? Data(contentsOf: TitleOverrides.namesFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    check(before == "The Sopranos S4 E1" && named == "The Sopranos (last)" && item.givenName == named && redraws == 1,
          "a typed name: shown as typed, without the spaces around it, and the list redraws (\(before) -> \(named))")
    check(tv.title == named && tv.subtitle == nil, "a typed name: the one line on the TV's panel (\(tv.title), \(tv.subtitle ?? "no second line"))")
    check(lookedUp == MediaTitle(title: "The Sopranos", season: 4, episode: 1) && item.parsedTitle == lookedUp,
          "a typed name: details are still looked up by what the file says (\(lookedUp.displayName))")
    check(saved?[file.path] == named, "a typed name: saved beside the corrected titles")
    lib.setName("The Sopranos (last)", for: file)
    check(redraws == 1, "a typed name: the same name again changes nothing (\(redraws) redraws)")

    // Under the typed name sits the title corrected by hand, which shows again when the name goes
    TitleOverrides.set(MediaTitle(title: "Sopranos", season: 4, episode: 1), for: file)
    let over = item.displayName
    lib.setName("   ", for: file)
    let cleared = item.displayName
    let left = (try? Data(contentsOf: TitleOverrides.namesFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    check(over == named && cleared == "Sopranos S4 E1" && item.givenName == nil && left?[file.path] == nil,
          "a typed name: nothing typed gives the video back its own name (\(over) -> \(cleared))")
    // Return in a text box that still holds the video's own name pins nothing to the file
    lib.setName("Sopranos S4 E1", for: file)
    let pinned = item.givenName
    TitleOverrides.set(nil, for: file)
    check(pinned == nil && item.displayName == before, "a typed name: the name the video has anyway isn't kept (\(item.displayName))")
    check(TitleOverrides.cleaned("Heat\n(the long one)", insteadOf: "Heat (1995)") == "Heat (the long one)"
          && TitleOverrides.cleaned("", insteadOf: "Heat (1995)") == nil,
          "a typed name: kept on one line; empty is no name")
    watching.cancel()
}

// Opening a video that is already listed must not list it twice
do {
    let pl = lib.newPlaylist(named: "harness-dupes")
    let first = lib.add([mp4, mkv], to: pl)
    let again = lib.add([mp4], to: pl)
    let count = lib.playlists.first { $0.id == pl }!.items.count
    check(first.count == 2 && again.isEmpty && count == 2, "a video added twice is listed once (\(count) rows, second add returned \(again.count))")
    lib.deletePlaylist(pl)
}

// A lookup with a deadline answers in time and lets the work finish for the cache
do {
    let quick = try! await_ { await Deadline.first(within: 2) { () async -> Int? in 7 } }.get()
    let slow = try! await_ { await Deadline.first(within: 0.2) { () async -> Int? in try? await Task.sleep(nanoseconds: 1_000_000_000); return 9 } }.get()
    check(quick == 7 && slow == nil, "deadline: quick work answers (\(quick ?? -1)), slow work gives nil (\(slow.map(String.init) ?? "nil"))")
}

// Series detection: a batch of episodes becomes a playlist named after the show
func seriesTitle(_ s: String) -> String { SeriesName.title(fromFileName: s) ?? "nil" }
check(seriesTitle("Sopranos.S1.E11.dolbuy") == "Sopranos", "series: Sopranos.S1.E11 -> \(seriesTitle("Sopranos.S1.E11.dolbuy"))")
check(seriesTitle("The.Wire.S02E05.1080p.BluRay") == "The Wire", "series: S02E05 -> \(seriesTitle("The.Wire.S02E05.1080p.BluRay"))")
check(seriesTitle("the_office_3x07_hdtv") == "The Office", "series: 3x07 -> \(seriesTitle("the_office_3x07_hdtv"))")
check(seriesTitle("[Group] Some Show - 03 [1080p]") == "Some Show", "series: fan release -> \(seriesTitle("[Group] Some Show - 03 [1080p]"))")
check(seriesTitle("Planet Earth Episode 4") == "Planet Earth", "series: Episode 4 -> \(seriesTitle("Planet Earth Episode 4"))")
check(SeriesName.title(fromFileName: "Test.Movie.2024.1080p") == nil && SeriesName.title(fromFileName: "Blade Runner 2049") == nil, "series: plain movies have no show name")
check(SeriesName.commonTitle(["Lecture 01", "Lecture 02", "Lecture 10"]) == "Lecture", "series: common start -> \(SeriesName.commonTitle(["Lecture 01", "Lecture 02", "Lecture 10"]) ?? "nil")")
check(SeriesName.commonTitle(["The Matrix", "The Godfather"]) == nil && SeriesName.commonTitle(["simple", "hdr", "Test.Movie.2024.1080p"]) == nil, "series: unrelated movies are not grouped")
let grouped = SeriesName.group(["Sopranos.S1.E11.x", "Heat.1995", "Sopranos.S1.E12.x", "Lost.S01E01"])
check(grouped.series == [SeriesName.Group(show: "Sopranos", season: 1, members: [0, 2])] && grouped.series.first?.title == "Sopranos S1" && grouped.rest == [1, 3],
      "series: grouping keeps single files out, and names the season: \(grouped)")
let home = ["The.Wire.S02E05.720p", "Office 3x07", "Show Season 4 Episode 1", "Dune Part 2", "Planet Earth Episode 4", "Heat.1995"].map { SeriesName.seasonPlaylist(forFileName: $0) ?? "nil" }
check(home == ["The Wire S2", "Office S3", "Show S4", "nil", "nil", "nil"], "series: an episode's season playlist is named only when its name gives a season: \(home)")
let seasons = SeriesName.group(["Show.S02E05.x", "Show.S01E02.x", "Show.S02E01.x", "Show.S10E01.x", "Other 3x07", "Other 3x08", "Other Season 4 Episode 1", "Heat.1995"])
check(seasons.series.map(\.title) == ["Show S1", "Show S2", "Show S10", "Other S3", "Other S4"] && seasons.series.map(\.members) == [[1], [0, 2], [3], [4, 5], [6]] && seasons.rest == [7],
      "series: a group for each season, in season order, a lone episode of another season included: \(seasons.series.map(\.title)) \(seasons.series.map(\.members))")
let unnumbered = SeriesName.group(["Planet Earth Episode 1", "Planet Earth Episode 2", "Lecture 01", "Lecture 02"])
check(unnumbered.series.map(\.title) == ["Planet Earth", "Lecture"] && unnumbered.series.allSatisfy { $0.season == nil },
      "series: episodes with no season number stay under the show's name: \(unnumbered.series.map(\.title))")
do {
    let dir = mediaDir.appendingPathComponent("series", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let files = ["Sopranos.S1.E12.dolbuy.mp4", "Sopranos.S1.E2.dolbuy.mp4", "Sopranos.S1.E11.dolbuy.mp4", "Heat.1995.mp4"].map { dir.appendingPathComponent($0) }
    files.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) }
    let other = lib.newPlaylist(named: "harness2")
    let before = lib.playlists.count
    let added = lib.add(files, to: other)
    let show = lib.playlists.first { $0.name == "Sopranos S1" }
    check(lib.playlists.count == before + 1 && show?.items.map(\.baseName) == ["Sopranos.S1.E2.dolbuy", "Sopranos.S1.E11.dolbuy", "Sopranos.S1.E12.dolbuy"],
          "dropping episodes makes a Sopranos S1 playlist in episode order: \(show?.items.map(\.baseName) ?? [])")
    check(lib.playlists.first { $0.id == other }?.items.map(\.baseName) == ["Heat.1995"] && added.count == 4 && lib.selection == show?.id, "the odd film stays in the playlist it was dropped on; the show is selected")
    lib.add(files, to: other)
    check(lib.playlists.filter { $0.name == "Sopranos S1" }.count == 1 && lib.playlists.first { $0.name == "Sopranos S1" }?.items.count == 3, "dropping the same episodes again reuses the playlist without duplicates")
    if let show { lib.deletePlaylist(show.id) }
    lib.deletePlaylist(other)
    let empty = lib.newPlaylist()
    lib.add(Array(files.prefix(3)), to: empty)
    check(lib.playlists.first { $0.id == empty }?.name == "Sopranos S1", "an empty default playlist is renamed to the show and season")
    lib.deletePlaylist(empty)

    // Two seasons dropped together: a playlist for each
    let two = ["Wire.S02E02.mkv", "Wire.S01E03.mkv", "Wire.S02E01.mkv", "Wire.S01E01.mkv"].map { dir.appendingPathComponent($0) }
    two.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) }
    let fresh = lib.newPlaylist()
    let count = lib.playlists.count
    let both = lib.add(two, to: fresh)
    let s1 = lib.playlists.first { $0.name == "Wire S1" }, s2 = lib.playlists.first { $0.name == "Wire S2" }
    check(s1?.items.map(\.baseName) == ["Wire.S01E01", "Wire.S01E03"] && s2?.items.map(\.baseName) == ["Wire.S02E01", "Wire.S02E02"] && both.count == 4,
          "two seasons dropped together make a playlist each, in episode order: \(s1?.items.map(\.baseName) ?? []) \(s2?.items.map(\.baseName) ?? [])")
    check(s1?.id == fresh && lib.playlists.count == count + 1 && lib.selection == fresh && both.first?.baseName == "Wire.S01E01",
          "the empty playlist dropped on becomes season 1, season 2 is added beside it, and season 1 is shown")
    let open = lib.addToPlay(two, to: fresh)
    check(open?.item.baseName == "Wire.S01E01" && open?.queue.count == 2, "opening both seasons again plays season 1's first episode, with season 1 after it")
    if let s1 { lib.deletePlaylist(s1.id) }
    if let s2 { lib.deletePlaylist(s2.id) }

    // One episode alone stays where it is dropped, unless its season already has a playlist
    let film = lib.newPlaylist(named: "harness-films")
    lib.selection = film
    let alone = lib.playlists.count
    let single = lib.add([two[1]], to: film)        // Wire.S01E03, and there is no Wire S1 playlist
    check(single.count == 1 && lib.playlists.count == alone && lib.playlists.first { $0.id == film }?.items.map(\.baseName) == ["Wire.S01E03"] && lib.selection == film,
          "one episode dropped alone stays in the playlist it was dropped on, and no playlist is made for it")
    lib.remove(Set(single.map(\.id)), from: film)
    lib.add(two, to: film)                          // both seasons together: the season playlists are made
    let later = dir.appendingPathComponent("Wire.S01E05.mkv")
    FileManager.default.createFile(atPath: later.path, contents: Data())
    lib.selection = film
    let joined = lib.add([later], to: film)
    let season1 = lib.playlists.first { $0.name == "Wire S1" }
    check(joined.count == 1 && season1?.items.map(\.baseName) == ["Wire.S01E01", "Wire.S01E03", "Wire.S01E05"]
          && lib.playlists.first { $0.id == film }?.items.isEmpty == true && lib.selection == season1?.id,
          "with its season's playlist there, an episode dropped alone joins it and that playlist is shown: \(season1?.items.map(\.baseName) ?? [])")
    let twice = lib.add([later], to: film)
    let opened = lib.addToPlay([later], to: film)
    check(twice.isEmpty && lib.playlists.first { $0.name == "Wire S1" }?.items.count == 3 && opened?.item.baseName == "Wire.S01E05" && opened?.queue.count == 3,
          "the same episode again is not listed twice, and opening it plays it from its season's playlist")
    lib.deletePlaylist(film)

    // A show's playlist from before, named after the show alone
    guard let old = season1?.id else { fatalError("no Wire S1 playlist") }
    lib.playlists.filter { $0.name == "Wire S2" }.forEach { lib.deletePlaylist($0.id) }
    lib.rename(old, to: "Wire")
    lib.add([two[0], two[2]], to: old)              // season 2
    let renamed = lib.playlists.first { $0.id == old }
    let beside = lib.playlists.first { $0.name == "Wire S2" }
    check(renamed?.name == "Wire S1" && renamed?.items.count == 3 && beside?.items.count == 2,
          "an older playlist named after the show that holds one season takes the season's name when more of the show is added: \(renamed?.name ?? "nil") \(renamed?.items.count ?? 0)")
    // One that mixes seasons
    if let beside { lib.moveItems(Set(beside.items.map(\.id)), from: beside.id, to: old); lib.deletePlaylist(beside.id) }
    lib.rename(old, to: "Wire")
    let third = ["Wire.S03E01.mkv", "Wire.S03E02.mkv"].map { dir.appendingPathComponent($0) }
    third.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) }
    lib.add(third, to: old)
    check(lib.playlists.first { $0.id == old }?.name == "Wire" && lib.playlists.first { $0.id == old }?.items.count == 5
          && lib.playlists.first { $0.name == "Wire S3" }?.items.count == 2,
          "an older playlist that mixes seasons is left as it is, and a new season gets its own")
    for name in ["Wire", "Wire S1", "Wire S2", "Wire S3"] { lib.playlists.filter { $0.name == name }.forEach { lib.deletePlaylist($0.id) } }
}

// Sort in the right-click menu, and which video the list shows after videos are added
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("harness-sort-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let files = ["Zulu", "alpha", "Part 10", "Part 2", "Beta (1999)"].map { dir.appendingPathComponent($0 + ".mkv") }
    files.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) }
    let pl = lib.newPlaylist(named: "harness-sort")
    let was = lib.reveal
    let added = lib.add(files, to: pl)
    @MainActor func order() -> [String] { lib.playlists.first { $0.id == pl }?.items.map(\.displayName) ?? [] }
    check(added.count == 5 && lib.reveal?.item == added.first?.id && lib.reveal != was,
          "after an add, the first video added is the one to select and scroll to")
    let shown = lib.reveal
    lib.add([files[3]], to: pl)
    check(lib.reveal?.item == added[3].id && lib.reveal != shown && order().count == 5,
          "adding a video that is listed already points at its row, and doesn't list it twice")

    lib.sort(pl, by: .name)
    check(order() == ["Alpha", "Beta (1999)", "Part 2", "Part 10", "Zulu"], "sort by name: capitals don't matter and 2 comes before 10 \(order())")
    lib.setName("Aardvark", for: files[0])
    lib.sort(pl, by: .name)
    check(order().first == "Aardvark", "sort by name: goes by the name a video was given \(order())")
    lib.setName("", for: files[0])

    // Newest first; the two with the same date keep their order, and a file with no date goes last.
    let day = 86_400.0, t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let dates: [String: Date] = ["Zulu.mkv": t0, "alpha.mkv": t0.addingTimeInterval(2 * day), "Part 2.mkv": t0.addingTimeInterval(day),
                                 "Part 10.mkv": t0.addingTimeInterval(day)]
    lib.sort(pl, by: .name)
    lib.sort(pl, by: .dateAdded) { dates[$0.lastPathComponent] }
    check(order() == ["Alpha", "Part 2", "Part 10", "Zulu", "Beta (1999)"], "sort by date added: newest first, undated last \(order())")
    check(Library.dateAdded(files[0]) != nil && Library.dateAdded(dir.appendingPathComponent("gone.mkv")) == nil,
          "date added: read from the disk; none for a file that isn't there")

    lib.markWatched(files[1]); lib.markWatched(files[3])          // alpha and Part 2
    lib.sort(pl, by: .unwatchedFirst)
    check(order() == ["Part 10", "Zulu", "Beta (1999)", "Alpha", "Part 2"], "sort unwatched first: finished videos go after the rest, each group as it was \(order())")
    lib.saveNow()
    let kept = Library().playlists.first { $0.name == "harness-sort" }?.items.map(\.displayName) ?? []
    check(kept == order(), "a sorted playlist is saved in its new order")
    files.forEach { lib.clearProgress($0) }
    lib.deletePlaylist(pl)
    lib.saveNow()
    try? FileManager.default.removeItem(at: dir)
}

// One copy of the app, two copies at once, and saves that fail.
do {
    // Reading the playlists writes nothing back. It used to schedule a save of the list just
    // read, which half a second later could land on top of a newer one.
    do {
        lib.saveNow()
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/library.json")
        func written() -> Date? { (try? FileManager.default.attributesOfItem(atPath: store.path))?[.modificationDate] as? Date }
        let was = written()
        let count = Library().playlists.count
        Thread.sleep(forTimeInterval: 0.9)
        check(was != nil && written() == was && count == lib.playlists.count, "reading the playlists leaves the file as it was")
    }

    // Helpers sit inside the block, as the others in this file do.
    @MainActor func listed(_ library: Library, _ playlist: String) -> [String] {
        library.playlists.first { $0.name == playlist }?.items.map(\.baseName) ?? []
    }
    func logged(_ phrase: String) -> Int {
        ErrorLog.flush()
        return ((try? String(contentsOf: ErrorLog.url, encoding: .utf8)) ?? "").components(separatedBy: phrase).count - 1
    }

    // As reported: videos dropped in, another opened by double-clicking, then paused. In one copy
    // of the app nothing leaves the list, on screen or in what is saved.
    do {
        let pl = lib.newPlaylist(named: "harness-pause")
        lib.add([mp4, mkv], to: pl)                                  // dropped
        let opened = lib.addToPlay([hdr], to: pl)                    // another, double-clicked
        lib.updateProgress(for: hdr, position: 60, duration: 600)    // what pausing saves
        lib.save()
        lib.saveNow()
        let reread = Library()
        check(opened != nil && listed(lib, "harness-pause").count == 3 && listed(reread, "harness-pause") == listed(lib, "harness-pause"),
              "dropping, opening another and pausing keeps every video, in the list and on disk: \(listed(reread, "harness-pause"))")
        lib.deletePlaylist(pl)
        lib.saveNow()
    }

    // Two copies open at once. Each writes its whole list, so the one that saves last wins and
    // what was dropped into the other is gone from the file. This is why only one copy runs
    // (SingleCopy). A copy that finds the file changed under it says so in the error log, once.
    do {
        let pl = lib.newPlaylist(named: "harness-copies")
        lib.saveNow()
        let other = Library()                           // a second copy, open since before the drop
        let before = logged("most likely a second copy")
        lib.add([mp4, mkv], to: pl)                     // dropped into the first
        lib.saveNow()
        other.add([hdr], to: other.playlists.first { $0.name == "harness-copies" }?.id)
        other.saveNow()                                 // the second saves: its list has no dropped videos
        check(listed(Library(), "harness-copies") == ["hdr"], "a second copy's save replaces the list, losing what was dropped into the first: \(listed(Library(), "harness-copies"))")
        check(logged("most likely a second copy") == before + 1, "the copy that wrote over another's list says so in the error log")
        other.saveNow()
        check(logged("most likely a second copy") == before + 1, "and says it once, not at every save")
        lib.saveNow()
        check(listed(Library(), "harness-copies") == ["simple", "Test.Movie.2024.1080p"] && logged("most likely a second copy") == before + 2,
              "the first copy's next save puts its own list back, and it notes the change too: \(listed(Library(), "harness-copies"))")
        lib.deletePlaylist(pl)
        lib.saveNow()
        let quiet = logged("most likely a second copy")
        lib.save(); lib.saveNow(); lib.saveNow()
        check(logged("most likely a second copy") == quiet, "a copy on its own never reports another")

        let t0 = Date()
        check(SingleCopy.replaced([(1, t0.addingTimeInterval(-60)), (2, nil), (3, t0.addingTimeInterval(5))], by: t0) == [1, 2],
              "the copy being opened replaces the ones open before it, not one opened after it")
        check(SingleCopy.replaced([(4, t0)], by: t0).isEmpty, "two copies starting in the same moment don't each close the other")
        check(SingleCopy.takeOver(), "with no other copy running, the one opened just starts")
    }

    // A save that fails is written to the error log, once while it lasts.
    do {
        let before = logged("Playlists: saving them")
        let nowhere = LibraryFile(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/library.json"))
        nowhere.queue.sync { nowhere.write { Data("{}".utf8) }; nowhere.write { Data("{}".utf8) } }
        struct Refused: Error {}
        nowhere.queue.sync { nowhere.write { throw Refused() } }
        check(logged("Playlists: saving them") == before + 1, "a save that fails is logged once (\(logged("Playlists: saving them") - before))")
    }
}

}
// Language codes
check(Lang.isLanguageCode("en") && Lang.isLanguageCode("ger") && !Lang.isLanguageCode("up") && !Lang.isLanguageCode("1080p"), "language code check (up/1080p rejected)")
check(SubtitleChoice.external(mediaDir.appendingPathComponent("Up.srt")).language == nil, "Up.srt has no language")
check(!DeviceProfile.chromecast(model: "Chromecast", settings: settings).audioCodecs.contains("vorbis"), "vorbis not copied to Chromecast")
check(DeviceProfile.chromecast(model: "Google Home Mini", settings: settings).audioOnly && !DeviceProfile.chromecast(model: "Google Nest Hub", settings: settings).audioOnly, "audio-only detection")
// Device limits from Google's supported-media table, and the TXT record's capability flags
let classic = DeviceProfile.chromecast(model: "Chromecast", settings: settings)
let hub = DeviceProfile.chromecast(model: "Google Nest Hub", settings: settings)
let ultra = DeviceProfile.chromecast(model: "Chromecast Ultra", settings: settings)
check(classic.maxHeight == 1080 && classic.maxH264Level == 41 && classic.maxHeightAbove30fps == 720 && !classic.videoCodecs.contains("hevc"),
      "classic Chromecast: 1080p30, H.264 4.1, no HEVC")
check(hub.maxHeight == 720 && ultra.maxHeight == 2160 && ultra.videoCodecs.contains("hevc") && ultra.supportsHDR, "Nest Hub 720p; Ultra 4K HEVC HDR")
check(CastDeviceInfo.isAudioOnly(model: "Some Soundbar", capabilities: 4) && !CastDeviceInfo.isAudioOnly(model: "Unknown Thing", capabilities: 5)
      && DeviceProfile.chromecast(model: "Unknown Thing", capabilities: 36, settings: settings).audioOnly, "capability flags decide audio-only devices")
let fast = MediaInfo(duration: 60, formatName: "matroska", bitRate: nil,
                     video: MediaInfo.Video(index: 0, codec: "h264", codecTag: "avc1", profile: "High", level: 42, pixFmt: "yuv420p", width: 1920, height: 1080, fps: 59.94, colorTransfer: nil, isDolbyVision: false),
                     audio: [MediaInfo.Audio(index: 1, codec: "aac", profile: "LC", channels: 2, language: "eng", title: nil, isDefault: true)], subtitles: [])
let fastPlan = StreamPlanner.plan(info: fast, file: URL(fileURLWithPath: "/tmp/x.mkv"), profile: classic, settings: settings, audioIndex: 1, subtitle: nil, options: PlaybackOptions())
if case .transcode(let h, _, _) = fastPlan.videoAction, h == 720 { check(true, "1080p60 H.264 4.2 is converted to 720p for a classic Chromecast") }
else { check(false, "1080p60 H.264 4.2 is converted to 720p for a classic Chromecast: \(fastPlan.notes)") }
let fastUltra = StreamPlanner.plan(info: fast, file: URL(fileURLWithPath: "/tmp/x.mp4"), profile: ultra, settings: settings, audioIndex: 1, subtitle: nil, options: PlaybackOptions())
check(fastUltra.isCopyingVideo || fastUltra.mode == .direct, "the same file is passed through to a Chromecast Ultra")
// File names -> titles
let heat = MediaTitle.parse(fileName: "Heat.1995.1080p.BluRay.x264-GRP")
check(heat.title == "Heat" && heat.year == 1995 && !heat.isEpisode && heat.searchQuery == "Heat 1995", "title: Heat.1995.1080p -> \(heat)")
let sop = MediaTitle.parse(fileName: "Sopranos.S1.E11.dolby")
check(sop.title == "Sopranos" && sop.season == 1 && sop.episode == 11 && sop.episodeLabel == "Season 1, Episode 11", "title: Sopranos.S1.E11 -> \(sop)")
let wire = MediaTitle.parse(fileName: "The.Wire.S02E05.720p.HDTV.x264")
check(wire.title == "The Wire" && wire.season == 2 && wire.episode == 5, "title: The.Wire.S02E05 -> \(wire)")
let office = MediaTitle.parse(fileName: "the office 3x07 webrip")
check(office.title == "The Office" && office.season == 3 && office.episode == 7, "title: 3x07 -> \(office)")
let odyssey = MediaTitle.parse(fileName: "2001.A.Space.Odyssey.1968.2160p.UHD")
check(odyssey.title == "2001 A Space Odyssey" && odyssey.year == 1968, "title: a year at the start stays: \(odyssey)")
let plain = MediaTitle.parse(fileName: "Dune Part Two 2160p HDR")
check(plain.title == "Dune Part Two" && plain.year == nil, "title: no year, cut at release tag: \(plain)")
// Release names -> the names shown in the list, the windows and on the TV
let rarbg = MediaTitle.parse(fileName: "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG")
check(rarbg.displayName == "The Sopranos S4 E7" && rarbg.title == "The Sopranos" && rarbg.titleTag == "S4 E7", "display name: release name -> \(rarbg.displayName)")
check(heat.displayName == "Heat (1995)" && office.displayName == "The Office S3 E7" && plain.displayName == "Dune Part Two" && sop.displayName == "Sopranos S1 E11",
      "display names: \(heat.displayName), \(office.displayName), \(plain.displayName), \(sop.displayName)")
check(MediaTitle.parse(fileName: "Inception (2010)").displayName == "Inception (2010)", "display name: a tidy name stays as it is")
check(MediaTitle.parse(fileName: "Some.Film.x264-GRP").displayName == "Some Film", "display name: a tag joined to its group by a hyphen is cut")
check(MediaTitle.parse(fileName: "Spider-Man.No.Way.Home.2021.2160p.WEB-DL").displayName == "Spider-Man No Way Home (2021)", "display name: a hyphen inside the title stays")
check(MediaTitle.parse(fileName: "Show.Episode.12.720p").displayName == "Show E12", "display name: an episode with no season")
// Everyday files: the name made readable, keeping dates and times
let everyday: [(String, String)] = [
    ("Screen Recording 2024-01-02 at 10.30.15 AM", "Screen Recording 2024-01-02 at 10.30.15 AM"),
    ("My_Birthday_Party_2023-05-12", "My Birthday Party 2023-05-12"),
    ("Birthday 2023 at Grandmas", "Birthday 2023 at Grandmas"),
    ("IMG_1234", "IMG 1234"),
    ("vacation.video.final", "Vacation Video Final"),
    ("Drone_flight_4K_60fps", "Drone flight"),
    ("Never Gonna Give You Up [dQw4w9WgXcQ]", "Never Gonna Give You Up"),
    ("my-summer-vacation-2023", "My Summer Vacation (2023)"),
    ("Party 12.05.2023", "Party 12.05.2023"),
    ("The.Daily.Show.2024.01.02.Guest.720p", "The Daily Show 2024.01.02 Guest"),
    ("Blade Runner 2049", "Blade Runner 2049"),
    ("Blade.Runner.2049.2017.1080p.BluRay", "Blade Runner 2049 (2017)"),
    ("Inception (2010) [1080p] [YTS.MX]", "Inception (2010)"),
    ("Heat 1995-GRP", "Heat (1995)"),
    ("Heat [1995]", "Heat (1995)"),
    ("Dune [1984] [1080p]", "Dune (1984)"),
    ("Show [S01E02]", "Show S1 E2"),
    // A release tag that is an everyday word ends the title only when tags alone follow it
    ("Our Extended Family Christmas 2023", "Our Extended Family Christmas (2023)"),
    ("A Proper Wedding", "A Proper Wedding"),
    ("The Limited Edition Story", "The Limited Edition Story"),
    ("The.Extended.Family.S01E02.720p", "The Extended Family S1 E2"),
    ("Heat.1995.EXTENDED.1080p.BluRay.x264-GRP", "Heat (1995)"),
    ("Some.Film.Extended.Cut.1080p.BluRay", "Some Film"),
    ("Some.Film.Criterion.Collection.1080p", "Some Film"),
    ("Some.Film.PROPER.720p.HDTV", "Some Film"),
    ("Some Film Unrated", "Some Film"),
    // Two numbers before a year are a date only when they can be, and no release tags follow
    ("Fahrenheit.9.11.2004.DVDRip.XviD", "Fahrenheit 9 11 (2004)"),
    ("Die.Hard.4.0.2007.1080p.BluRay", "Die Hard 4 0 (2007)"),
    // Two years in a row: the second is when the film came out
    ("Wonder.Woman.1984.2020.1080p.WEB-DL", "Wonder Woman 1984 (2020)"),
    ("Death.Race.2000.1975.720p.BluRay", "Death Race 2000 (1975)"),
    // "Episode 4" with more of the name and then a year is a film; with tags after it, an episode
    ("Star.Wars.Episode.4.A.New.Hope.1977.1080p.BluRay", "Star Wars Episode 4 A New Hope (1977)"),
    ("Planet.Earth.Episode.03.2006.1080p.BluRay", "Planet Earth E3"),
    // A year followed only by the name of a cut is the film's year
    ("Movie 2010 Directors Cut", "Movie (2010)"),
    ("Movie 2010 Director's Cut", "Movie (2010)"),
    ("Blade Runner 1982 The Final Cut", "Blade Runner (1982)"),
    ("Project 2023 Final", "Project 2023 Final"),
    // A hyphenated title with its number keeps its hyphen; a slug still becomes words
    ("Spider-Man-2", "Spider-Man 2"),
    ("X-Men-2", "X-Men 2"),
    ("my-video-2", "My Video 2"),
]
check(heat.tvLines(lookedUp: true) == ("Heat", nil) && heat.tvLines(lookedUp: false) == ("Heat (1995)", nil),
      "TV panel: a film found online drops its year, an unknown one keeps it")
check(rarbg.tvLines(lookedUp: true) == ("The Sopranos", "Season 4, Episode 7") && rarbg.tvLines(lookedUp: false) == ("The Sopranos", "Season 4, Episode 7"),
      "TV panel: an episode is the show's name over its season and episode")
// Subtitle release names against the video's file name
let video = "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG"
let releaseCases: [(String, Bool, String)] = [
    ("The.Sopranos.S04E07.1080p.BluRay.x265-RARBG", true, "the same name"),
    ("The.Sopranos.S04E07.1080p.BluRay.x265-RARBG.en.srt", true, "the same name with a language and extension"),
    ("The Sopranos S04E07 720p BluRay x264-RARBG", true, "same group and source, another size"),
    ("The.Sopranos.S04E07.1080p.WEB-DL.x264-RARBG", false, "same group, a streaming source"),
    ("The.Sopranos.S04E07.1080p.BluRay.x264-DEMAND", false, "another group"),
    ("The.Sopranos.S04E08.1080p.BluRay.x265-RARBG", false, "another episode"),
    ("The Sopranos Season 4", false, "no release at all"),
]
for (sub, expected, why) in releaseCases {
    check(ReleaseMatch.isSameRelease(sub, as: video) == expected, "subtitle match: \(why) (\(sub))")
}
check(ReleaseMatch.isSameRelease("Heat.2013.1080p.BluRay.x264-GRP", as: "Heat.1995.1080p.BluRay.x264-GRP") == false
      && ReleaseMatch.isSameRelease("Heat.1995.720p.BluRay.x264-GRP", as: "Heat.1995.1080p.BluRay.x264-GRP"),
      "subtitle match: another year's film from the same group isn't a match")
check(ReleaseMatch.isSameRelease("Aliens.720p.BluRay.x264-GRP", as: "Alien.1080p.BluRay.x264-GRP") == false
      && ReleaseMatch.isSameRelease("Heat.1995.EXTENDED.720p.BluRay.x264-GRP", as: "Heat.1995.1080p.BluRay.x264-GRP") == false
      && ReleaseMatch.isSameRelease("Heat.1995.Directors.Cut.720p.BluRay.x264-GRP", as: "Heat.1995.Director's.Cut.1080p.BluRay.x264-GRP"),
      "subtitle match: another film or another cut from the same group isn't a match")
check(ReleaseMatch.isSameRelease("The.Sopranos.S04.720p.BluRay.x264-RARBG", as: "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG") == false
      && ReleaseMatch.isSameRelease("Alien.3.720p.BluRay.x264-GRP", as: "Alien.1080p.BluRay.x264-GRP") == false,
      "subtitle match: a season's pack or a sequel from the same group isn't a match")
check(ReleaseMatch.group("Movie.2010.1080p.WEB.H-264") == nil && ReleaseMatch.group("Movie.2010.1080p.BluRay.DTS-ES") == nil
      && ReleaseMatch.group("Spider-Man") == nil && ReleaseMatch.group("Movie.2010.720p.x264-GRP.pt-BR") == "grp",
      "release group: a codec, an audio format or a title's own hyphen isn't a group; a region after the language is skipped")
check(ReleaseMatch.group("Movie.2010.1080p.WEB-DL") == nil && ReleaseMatch.group("Spider-Man.2002.1080p") == nil
      && ReleaseMatch.group("x264-GRP.en") == "grp", "release group: a hyphenated tag or title isn't a group")
for (file, shown) in everyday {
    let got = MediaTitle.parse(fileName: file).displayName
    check(got == shown, "display name: \(file) -> \(got)")
}
// The title written into a file (a TV reading the file itself would show it)
let taggedJSON = #"{"format":{"duration":"10","format_name":"mov","tags":{"title":"The.Sopranos.S04E07.1080p.BluRay.x265-RARBG"}},"streams":[]}"#
let untaggedJSON = #"{"format":{"duration":"10","format_name":"mov"},"streams":[]}"#
check((try? MediaProbe.parse(Data(taggedJSON.utf8)))?.embeddedTitle == "The.Sopranos.S04E07.1080p.BluRay.x265-RARBG"
      && (try? MediaProbe.parse(Data(untaggedJSON.utf8)))?.embeddedTitle == nil, "probe: the file's own title tag is read")
// Where the end credits start, from the file's chapters
func chaptersJSON(_ chapters: [(Double, String)], start: Double = 0) -> Data {
    let list = chapters.map { #"{"start_time":"\#($0.0)","tags":{"title":"\#($0.1)"}}"# }.joined(separator: ",")
    return Data(#"{"format":{"duration":"7200","format_name":"matroska","start_time":"\#(start)"},"streams":[],"chapters":[\#(list)]}"#.utf8)
}
let filmChapters: [(Double, String)] = [(0, "Opening Credits"), (3000, "Chapter 12"), (6800.5, "End Credits")]
check((try? MediaProbe.parse(chaptersJSON(filmChapters)))?.creditsStart == 6800.5
      && (try? MediaProbe.parse(chaptersJSON(filmChapters, start: 10)))?.creditsStart == 6790.5,
      "probe: the end credits chapter is found, counted from the film's start")
check((try? MediaProbe.parse(chaptersJSON(filmChapters + [(7100, "Post-Credits Scene")])))?.creditsStart == 6800.5,
      "probe: a post-credits scene after the credits doesn't move their start")
check((try? MediaProbe.parse(chaptersJSON([(10, "Chapter 1"), (6700, "Générique de fin")])))?.creditsStart == 6700
      && (try? MediaProbe.parse(chaptersJSON([(6900, "ABSPANN")])))?.creditsStart == 6900,
      "probe: credits chapters in other languages, any case or accents")
check((try? MediaProbe.parse(chaptersJSON([(0, "Opening Credits"), (3000, "Chapter 12")])))?.creditsStart == nil
      && (try? MediaProbe.parse(chaptersJSON([])))?.creditsStart == nil
      && (try? MediaProbe.parse(Data(untaggedJSON.utf8)))?.creditsStart == nil,
      "probe: opening credits, unnamed chapters or none at all mark no end credits")
// Where a video counts as finished
check(WatchProgress.finishPoint(duration: 7200) == 6912 && WatchProgress.finishPoint(duration: 120) == 108
      && abs(WatchProgress.finishPoint(duration: 3232.1) - (3232.1 - 129.284)) < 0.001,
      "finished: the last 4% is taken as the credits, 30 s at least, a tenth at most")
check((try? MediaProbe.parse(chaptersJSON([(10, "Chapter 1"), (5000, "The Credit Crunch"), (6000, "Accreditation")])))?.creditsStart == nil
      && (try? MediaProbe.parse(chaptersJSON([(10, "Chapter 1"), (5000, "The Credit Crunch"), (6900, "End Credit")])))?.creditsStart == 6900,
      "credits chapter: \"credit\" inside another name isn't the credits")
check(WatchProgress.finishPoint(duration: 7200, creditsStart: 6800) == 6790
      && WatchProgress.finishPoint(duration: 7200, creditsStart: 100) == 6912
      && WatchProgress.finishPoint(duration: 7200, creditsStart: 7300) == 6912,
      "finished: a credits chapter is used when it's in the second half")
// The casting window's corner: where the video is, and how long until its credits
do {
    check(WatchProgress.creditsPoint(duration: 7200) == 6912 && WatchProgress.creditsPoint(duration: 7200, creditsStart: 6800) == 6800
          && WatchProgress.creditsPoint(duration: 7200, creditsStart: 100) == 6912,
          "credits: where the chapter says, else the last 4%")
    let chapter = TimeLeft(position: 848.7, duration: 2300, creditsStart: 2182)
    check(chapter.stamp == "14:08" && chapter.left == "22m, 14s left",
          "time left: counted to the credits chapter (\(chapter.stamp) (\(chapter.left ?? "nil")))")
    let film = TimeLeft(position: 3600, duration: 7200), start = TimeLeft(position: 0, duration: 7200)
    check(film.stamp == "1:00:00" && film.left == "55m, 12s left" && start.stamp == "0:00" && start.left == "1h, 55m, 12s left",
          "time left: without a chapter, to where the credits are taken to start (\(film.left ?? "nil"); \(start.left ?? "nil"))")
    let nearly = TimeLeft(position: 6900.9, duration: 7200), credits = TimeLeft(position: 7000, duration: 7200)
    let over = TimeLeft(position: 7300, duration: 7200)
    check(nearly.left == "12s left" && credits.left == "3m, 20s to the end" && over.left == "0s to the end",
          "time left: in the credits, what is left of the file (\(nearly.left ?? "nil"); \(credits.left ?? "nil"); \(over.left ?? "nil"))")
    // The two numbers add up to the same moment at every second on the way there
    let sums = Set(stride(from: 0.0, to: 2182, by: 0.37).map { p -> Int in
        let t = TimeLeft(position: p, duration: 2300, creditsStart: 2182)
        let parts = (t.left ?? "").replacingOccurrences(of: " left", with: "").replacingOccurrences(of: ",", with: "").split(separator: " ")
        let left = parts.reduce(0) { $0 + (Int($1.dropLast()) ?? 0) * ($1.hasSuffix("h") ? 3600 : $1.hasSuffix("m") ? 60 : 1) }
        return Int(p) + left
    })
    check(sums == [2182], "time left: the time and what is left tick together (\(sums.sorted()))")
    let unknown = TimeLeft(position: 75, duration: 0)
    check(unknown.stamp == "1:15" && unknown.left == nil && TimeLeft(position: .nan, duration: .infinity).stamp == "0:00",
          "time left: only the time until the length is known")
}
check(TitleMatch.score(candidate: "Heat", year: 1995, wanted: heat) == 5 && TitleMatch.score(candidate: "Heat", year: 1986, wanted: heat) == 0
      && TitleMatch.score(candidate: "The Office", year: 2005, wanted: office) > 0 && TitleMatch.score(candidate: "Heat Wave", year: 1995, wanted: heat) == 3
      && TitleMatch.score(candidate: "Cheat", year: 1995, wanted: heat) == 0, "title matching: exact, year, prefix, no substring inside words")
// Wikipedia search -> article summary -> Wikidata facts (canned copies of real answers)
let wikiSearch = """
{"query":{"search":[{"title":"Heat 2","pageid":1},{"title":"Heat (1995 film)","pageid":43566},{"title":"Heat (disambiguation)","pageid":2},{"title":"In the Heat of the Night (film)","pageid":3},{"title":"Heat (soundtrack)","pageid":4}]}}
"""
check(Wikipedia.pickPage(Data(wikiSearch.utf8), wanted: heat) == "Heat (1995 film)", "Wikipedia: the 1995 film article is picked over the sequel, the disambiguation page and the soundtrack")
check(Wikipedia.pickPage(Data(wikiSearch.utf8), wanted: MediaTitle(title: "Heat", year: 1972)) == nil, "Wikipedia: a different year matches nothing")
let wikiSummary = """
{"type":"standard","title":"Heat (1995 film)","description":"1995 crime drama film by Michael Mann","wikibase_item":"Q42198",
 "thumbnail":{"source":"https://upload.wikimedia.org/thumb.jpg","width":220,"height":332},"originalimage":{"source":"https://upload.wikimedia.org/Heatposter.jpg","width":220,"height":332},
 "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Heat_(1995_film)"}},
 "extract":"Heat is a 1995 American epic crime drama film written and directed by Michael Mann and starring Al Pacino and Robert De Niro."}
"""
let summary = Wikipedia.parseSummary(Data(wikiSummary.utf8), wanted: heat)
check(summary?.details.title == "Heat" && summary?.details.year == 1995 && summary?.qid == "Q42198" && summary?.details.directors == ["Michael Mann"]
      && summary?.details.posterURL?.absoluteString == "https://upload.wikimedia.org/Heatposter.jpg" && summary?.details.synopsis?.hasPrefix("Heat is a 1995") == true
      && summary?.details.showTitle == nil, "Wikipedia summary parsed: \(summary?.details.title ?? "nil") \(summary?.details.year ?? 0) by \(summary?.details.directors ?? [])")
check(Wikipedia.parseSummary(Data("{\"type\":\"disambiguation\",\"title\":\"Heat\",\"extract\":\"Heat may refer to:\"}".utf8), wanted: heat) == nil
      && Wikipedia.parseSummary(Data("{\"type\":\"standard\",\"title\":\"Heat\",\"description\":\"form of energy\",\"extract\":\"In thermodynamics, heat is energy.\"}".utf8), wanted: heat) == nil,
      "Wikipedia: disambiguation pages and non-film articles are rejected")
let wikidata = """
{"entities":{"Q42198":{"claims":{
 "P31":[{"mainsnak":{"datavalue":{"value":{"id":"Q11424"}}}}],
 "P57":[{"mainsnak":{"datavalue":{"value":{"id":"Q270097"}}}}],
 "P58":[{"mainsnak":{"datavalue":{"value":{"id":"Q270097"}}}}],
 "P161":[{"mainsnak":{"datavalue":{"value":{"id":"Q41163"}}},"qualifiers":{"P1545":[{"datavalue":{"value":"2"}}]}},{"mainsnak":{"datavalue":{"value":{"id":"Q36949"}}},"qualifiers":{"P1545":[{"datavalue":{"value":"1"}}]}}],
 "P136":[{"mainsnak":{"datavalue":{"value":{"id":"Q652256"}}}}],
 "P1657":[{"mainsnak":{"datavalue":{"value":{"id":"Q18665344"}}}}],
 "P2047":[{"mainsnak":{"datavalue":{"value":{"amount":"+170","unit":"http://www.wikidata.org/entity/Q7727"}}}}],
 "P577":[{"mainsnak":{"datavalue":{"value":{"time":"+1996-02-29T00:00:00Z"}}}},{"mainsnak":{"datavalue":{"value":{"time":"+1995-12-15T00:00:00Z"}}}}],
 "P345":[{"mainsnak":{"datavalue":{"value":"tt0113277"}}}],
 "P444":[{"mainsnak":{"datavalue":{"value":"8.3/10"}},"qualifiers":{"P447":[{"datavalue":{"value":{"id":"Q105584"}}}]},"rank":"normal"},
         {"mainsnak":{"datavalue":{"value":"87%"}},"qualifiers":{"P447":[{"datavalue":{"value":{"id":"Q105584"}}}]},"rank":"normal"},
         {"mainsnak":{"datavalue":{"value":"76/100"}},"qualifiers":{"P447":[{"datavalue":{"value":{"id":"Q150248"}}}]},"rank":"normal"},
         {"mainsnak":{"datavalue":{"value":"8.0/10"}},"qualifiers":{"P447":[{"datavalue":{"value":{"id":"Q37312"}}}]},"rank":"deprecated"},
         {"mainsnak":{"datavalue":{"value":"8.3/10"}},"qualifiers":{"P447":[{"datavalue":{"value":{"id":"Q37312"}}}]},"rank":"normal"}]}}}}
"""
let claims = Wikidata.parseEntity(Data(wikidata.utf8), qid: "Q42198")
check(claims.directors == ["Q270097"] && claims.cast == ["Q36949", "Q41163"] && claims.durationMinutes == 170 && claims.year == 1995 && claims.imdbID == "tt0113277" && !claims.isSeries
      && claims.labelIDs == ["Q270097", "Q36949", "Q41163", "Q652256", "Q18665344"], "Wikidata claims parsed, cast in billing order: \(claims.labelIDs)")
check(claims.ratings.map { "\($0.source) \($0.value)" } == ["IMDb 8.3/10", "Rotten Tomatoes 87%", "Metacritic 76/100"],
      "Wikidata review scores: IMDb first, the Tomatometer over the average, deprecated values skipped: \(claims.ratings.map { "\($0.source) \($0.value)" })")
// Wikidata keeps names that are the same in every language under "mul" rather than "en".
let labels = Wikidata.parseLabels(Data("""
{"entities":{"Q270097":{"labels":{"mul":{"value":"Michael Mann"}}},"Q36949":{"labels":{"en":{"value":"Al Pacino"}}},"Q41163":{"labels":{"mul":{"value":"Robert De Niro"}}},"Q652256":{"labels":{"en":{"value":"crime film"}}},"Q18665344":{"labels":{"en":{"value":"R"}}}}}
""".utf8))
check(Wikidata.labelsURL(["Q1"])?.absoluteString.contains("languages=en%7Cmul") == true, "Wikidata: labels are asked for in English and the shared 'mul' language")
let heatDetails = Wikidata.apply(claims, labels: labels, to: summary!.details)
check(heatDetails.directors == ["Michael Mann"] && heatDetails.cast == ["Al Pacino", "Robert De Niro"] && heatDetails.genres == ["Crime"] && heatDetails.certificate == "R"
      && heatDetails.runtimeMinutes == 170 && heatDetails.runtimeText == "2h 50m" && heatDetails.link?.absoluteString == "https://www.imdb.com/title/tt0113277/",
      "Wikidata facts applied with labels: \(heatDetails.directors) \(heatDetails.cast) \(heatDetails.genres)")
check(Wikipedia.summaryURL(pageTitle: "Heat (1995 film)")?.absoluteString == "https://en.wikipedia.org/api/rest_v1/page/summary/Heat_(1995_film)", "Wikipedia summary address")
let tvmazeShow = """
{"id":527,"name":"The Sopranos","premiered":"1999-01-10","genres":["Drama","Crime"],"rating":{"average":8.9},"network":{"name":"HBO"},"averageRuntime":60,
 "summary":"<p>The story of <b>Tony Soprano</b>.</p><p>Family &amp; business.</p>","image":{"medium":"https://m/med.jpg","original":"https://m/orig.jpg"},"url":"https://www.tvmaze.com/shows/527/the-sopranos"}
"""
let show = TVmaze.parseShow(Data(tvmazeShow.utf8), wanted: sop)
check(show?.1 == 527 && show?.0.title == "The Sopranos" && show?.0.ratings.first?.value == "8.9/10" && show?.0.network == "HBO"
      && show?.0.synopsis == "The story of Tony Soprano.\n\nFamily & business." && show?.0.posterURL?.absoluteString == "https://m/orig.jpg",
      "TVmaze show parsed, HTML stripped: \(show?.0.synopsis ?? "nil")")
let tvmazeEpisode = """
{"id":1,"name":"Pine Barrens","season":3,"number":11,"airdate":"2001-05-06","runtime":55,"summary":"<p>Paulie and Christopher get lost.</p>","image":{"medium":"https://m/ep.jpg"}}
"""
let episode = TVmaze.parseEpisode(Data(tvmazeEpisode.utf8), into: show!.0)
check(episode.season == 3 && episode.episode == 11 && episode.episodeTitle == "Pine Barrens" && episode.airDate == "2001-05-06" && episode.isEpisode
      && episode.episodeLabel == "Season 3, Episode 11" && episode.episodeImageURL?.absoluteString == "https://m/ep.jpg", "TVmaze episode merged into the show")
let omdbJSON = """
{"Title":"Heat","Year":"1995","Rated":"R","Released":"15 Dec 1995","Runtime":"170 min","Genre":"Action, Crime, Drama","Director":"Michael Mann","Writer":"Michael Mann (screenplay)",
 "Actors":"Al Pacino, Robert De Niro, Val Kilmer","Plot":"A group of high-end professional thieves...","Poster":"https://m.media-amazon.com/images/heat.jpg",
 "Ratings":[{"Source":"Internet Movie Database","Value":"8.3/10"},{"Source":"Rotten Tomatoes","Value":"88%"},{"Source":"Metacritic","Value":"76/100"}],
 "imdbRating":"8.3","imdbID":"tt0113277","Type":"movie","Response":"True"}
"""
let omdb = OMDbClient.parse(Data(omdbJSON.utf8), wanted: heat)
check(omdb?.ratings.map(\.source) == ["IMDb", "Rotten Tomatoes", "Metacritic"] && omdb?.cast.count == 3 && omdb?.writers == ["Michael Mann"]
      && omdb?.runtimeMinutes == 170 && omdb?.link?.absoluteString == "https://www.imdb.com/title/tt0113277/" && omdb?.ratings.first?.value == "8.3/10",
      "OMDb parsed with three ratings: \(omdb?.ratings.map(\.value) ?? [])")
check(OMDbClient.parse(Data("{\"Response\":\"False\",\"Error\":\"Movie not found!\"}".utf8), wanted: heat) == nil, "OMDb 'not found' gives nothing")

// The year on a playlist row: a film's own; for an episode the year it was first shown, not
// the year the show began. No review score there.
check(omdb?.listYear == 1995, "a film's row shows its year (\(omdb?.listYear.map(String.init) ?? "nil"))")
check(episode.year != 2001 && episode.listYear == 2001, "an episode's row shows the year it aired, not the show's (\(episode.year.map(String.init) ?? "nil") -> \(episode.listYear.map(String.init) ?? "nil"))")
do {
    var undated = episode
    undated.airDate = nil
    check(undated.listYear == nil, "an episode with no air date shows no year rather than the show's")
    check(MovieDetails.year(in: "03 Nov 2002") == 2002 && MovieDetails.year(in: "2002-11-03") == 2002
          && MovieDetails.year(in: "N/A") == nil && MovieDetails.year(in: "") == nil && MovieDetails.year(in: "0000-00-00") == nil,
          "the year is read from a date however the source writes it")
}

// Update check
check(AppVersion.isNewer("v1.10", than: "1.9") && AppVersion.isNewer("1.0.1", than: "1.0") && !AppVersion.isNewer("1.2", than: "1.2.0")
      && !AppVersion.isNewer("v1.0", than: "1.0") && !AppVersion.isNewer("0.9", than: "1.0") && !AppVersion.isNewer("nightly", than: "1.0")
      && AppVersion.isNewer("2.0-beta", than: "1.5"), "update: version comparison")
check(UpdateConfig.validated("some-one/Drift.cast") != nil && UpdateConfig.validated("") == nil && UpdateConfig.validated("a/b/c") == nil
      && UpdateConfig.validated("a b/c") == nil && UpdateConfig.validated("owner/") == nil, "update: repository name check")
do {
    let json = """
    {"tag_name":"v1.2","html_url":"https://github.com/o/r/releases/tag/v1.2","draft":false,"prerelease":false,
     "assets":[{"name":"notes.txt","browser_download_url":"https://github.com/o/r/releases/download/v1.2/notes.txt"},
               {"name":"Driftcast.zip","browser_download_url":"https://github.com/o/r/releases/download/v1.2/Driftcast.zip"}]}
    """
    let found = GitHubReleases.parse(data: Data(json.utf8), status: 200)
    check(found == .release(AppRelease(version: "1.2", page: URL(string: "https://github.com/o/r/releases/tag/v1.2")!,
                                       download: URL(string: "https://github.com/o/r/releases/download/v1.2/Driftcast.zip")!)),
          "update: release read from GitHub's answer: \(found)")
    check(GitHubReleases.parse(data: Data("{\"message\":\"Not Found\"}".utf8), status: 404) == .none, "update: no release published yet")
    check(GitHubReleases.parse(data: Data("{}".utf8), status: 200) == .failed && GitHubReleases.parse(data: Data(json.utf8), status: 403) == .failed, "update: unreadable or refused answers fail quietly")
    let elsewhere = json.replacingOccurrences(of: "https://github.com/o/r/releases/download/v1.2/Driftcast.zip", with: "http://example.com/Driftcast.zip")
    if case .release(let r) = GitHubReleases.parse(data: Data(elsewhere.utf8), status: 200) {
        check(r.download == nil, "update: a download link outside GitHub is not offered")
    } else { check(false, "update: a download link outside GitHub is not offered") }
    check(GitHubReleases.latestURL(repository: "o/r")?.absoluteString == "https://api.github.com/repos/o/r/releases/latest", "update: API address")
}
// MARK: Encoding and backward compatibility
do {
    func probe(_ name: String) -> (URL, MediaInfo) {
        let url = mediaDir.appendingPathComponent(name)
        return (url, try! await_ { try await MediaProbe.shared.probe(url) }.get())
    }
    func run(_ exe: URL, _ args: [String]) -> String {
        let p = Process(); p.executableURL = exe; p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
    let apple = DeviceProfile.apple()
    let hardwareOn = EncoderSettings(hardware: true, videoBitrateMbps: 8, maxResolution: 2160, forceTranscode: false, castHEVC: .auto, castAudio: .aac, castPassthrough: false, appleSurround: .eac3)
    var forced = hardwareOn; forced.forceTranscode = true
    let noOptions = PlaybackOptions()
    func args(_ plan: StreamPlan, route: StreamPlan.Route = .gpu, start: Double = 0) -> [String] {
        plan.ffmpegArguments(input: mp4, startTime: start, limitSeconds: nil, outputDirectory: mediaDir, filePrefix: "x", route: route)
    }

    check(FFmpeg.hasFilter("scale_vt") && FFmpeg.hasFilter("zscale") && !FFmpeg.hasFilter("no_such_filter"), "the ffmpeg in use has the GPU scaler and software tone-mapper")
    let version = String(decoding: try! await_ { try await FFmpeg.run(FFmpeg.ffmpeg!, ["-hide_banner", "-version"]) }.get(), as: UTF8.self)
    print("  ffmpeg:", version.split(separator: "\n").first ?? "")
    #if arch(x86_64)
    print("  running as x86_64")
    #endif

    // GPU routes, most on the GPU first.
    let (sdr, sdrInfo) = probe("sdr444.mkv")
    let sdrPlan = StreamPlanner.plan(info: sdrInfo, file: sdr, profile: apple, settings: forced, audioIndex: nil, subtitle: nil, options: noOptions)
    let gpu = args(sdrPlan)
    check(gpu.contains("videotoolbox_vld") && gpu.joined(separator: " ").contains("hwupload,scale_vt=w=1280:h=720") && gpu.contains("h264_videotoolbox"), "SDR conversion runs decode, scale and encode on the GPU")
    check(gpu.contains("-g") && !gpu.contains("-maxrate"), "VideoToolbox gets a GOP length and no -maxrate")
    let middle = args(sdrPlan, route: .hardwareEncoder)
    check(!middle.contains("-hwaccel") && middle.contains("h264_videotoolbox") && middle.joined(separator: " ").contains("scale=-2"), "second route: software decode and scale, hardware encode")
    let cpu = args(sdrPlan, route: .software)
    check(cpu.contains("libx264") && !cpu.joined(separator: " ").contains("videotoolbox"), "last route: software only")

    // Keyframes: one per 4-second segment rather than one every 12 frames.
    let gop = StreamSession(plan: sdrPlan, source: sdr, duration: sdrInfo.duration, grid: .fixed(duration: sdrInfo.duration), cues: nil)
    let gopStarted = await_ { try await gop.start(at: 0) }
    check((try? gopStarted.get()) != nil, "GPU conversion of a 4:4:4 source started \((try? gopStarted.get()) == nil ? "\(gopStarted)" : "")")
    if let body = try? await_({ try await gop.segment(0) }).get(), let head = gop.initSegment() {
        let file = mediaDir.appendingPathComponent("gop-check.mp4")
        try! (head + body).write(to: file)
        let flags = run(FFmpeg.ffprobe!, ["-v", "error", "-select_streams", "v", "-show_entries", "packet=flags", "-of", "csv=p=0", file.path])
        let keyframes = flags.split(separator: "\n").filter { $0.contains("K") }.count
        check(keyframes == 1, "a 4-second converted segment has one keyframe (\(keyframes))")
    } else { check(false, "first converted segment") }
    gop.stop()

    // A transport stream whose clock starts 50 minutes in.
    let (ts, tsInfo) = probe("offset.ts")
    check(tsInfo.startTime > 2999, "start of the file's clock read: \(tsInfo.startTime)")
    let tsCopy = StreamPlanner.plan(info: tsInfo, file: ts, profile: apple, settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions)
    check(args(tsCopy).contains("-start_at_zero"), "the clock is moved to zero")
    let tsKeys = try! await_ { try await KeyframeIndex.shared.keyframes(for: ts, streamIndex: tsInfo.video!.index) }.get()
    let tsGrid = SegmentGrid.keyframes(tsKeys.map { $0 - tsInfo.startTime }, duration: tsInfo.duration)
    check(tsGrid.count >= 7 && tsGrid.starts.last! < tsInfo.duration, "keyframe grid counts from the start of the film: \(tsGrid.starts.prefix(4))")
    let tsSession = StreamSession(plan: tsCopy, source: ts, duration: tsInfo.duration, grid: tsGrid, cues: nil)
    let tsStart = await_ { try await tsSession.start(at: 12.5) }
    let wanted = tsGrid.index(at: 12.5)
    check((try? tsStart.get()) != nil && abs((tsSession.producedRange?.lowerBound ?? -1) - tsGrid.start(of: wanted)) < 0.2,
          "remuxing part-way through lands on the right segment (\(tsSession.producedRange.map { "\($0)" } ?? "nil"), wanted \(tsGrid.start(of: wanted)))")
    let tsLater = await_ { try await tsSession.segment(tsGrid.count - 1) }
    check((try? tsLater.get())?.isEmpty == false, "the transport stream's AAC survives past the first segment \((try? tsLater.get()) == nil ? "\(tsLater)" : "")")
    tsSession.stop()
    let tsConvert = StreamPlanner.plan(info: tsInfo, file: ts, profile: apple, settings: forced, audioIndex: nil, subtitle: nil, options: noOptions)
    let tsFixed = SegmentGrid.fixed(duration: tsInfo.duration)
    let tsSession2 = StreamSession(plan: tsConvert, source: ts, duration: tsInfo.duration, grid: tsFixed, cues: nil)
    let tsStart2 = await_ { try await tsSession2.start(at: 12) }
    check((try? tsStart2.get()) != nil && abs((tsSession2.producedRange?.lowerBound ?? -1) - 12) < 0.2,
          "converting part-way through lands on the right segment (\(tsSession2.producedRange.map { "\($0)" } ?? "nil"))")
    tsSession2.stop()

    // Interlaced: never copied, deinterlaced before the (software) scaler.
    let (interlaced, intInfo) = probe("interlaced.ts")
    check(intInfo.video?.isInterlaced == true, "interlaced video detected (\(intInfo.video?.fieldOrder ?? "?"))")
    let intPlan = StreamPlanner.plan(info: intInfo, file: interlaced, profile: apple, settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions)
    let intArgs = args(intPlan)
    check(intPlan.isTranscodingVideo && intArgs.joined(separator: " ").contains("bwdif=") && !intArgs.contains("videotoolbox_vld"), "interlaced H.264 is converted and deinterlaced")
    let intSession = StreamSession(plan: intPlan, source: interlaced, duration: intInfo.duration, grid: .fixed(duration: intInfo.duration), cues: nil)
    check((try? await_ { try await intSession.start(at: 0) }.get()) != nil, "deinterlaced conversion ran")
    if let body = try? await_({ try await intSession.segment(0) }).get(), let head = intSession.initSegment() {
        let file = mediaDir.appendingPathComponent("int-check.mp4")
        try! (head + body).write(to: file)
        let order = run(FFmpeg.ffprobe!, ["-v", "error", "-select_streams", "v", "-show_entries", "stream=field_order", "-of", "csv=p=0", file.path])
        check(order.contains("progressive"), "output is progressive (\(order.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }
    intSession.stop()

    // A phone's portrait video.
    let (rotated, rotInfo) = probe("rotated.mp4")
    check(rotInfo.video?.rotation == 90 && rotInfo.video?.width == 1080 && rotInfo.video?.height == 1920, "rotation read; size is the picture as shown (\(rotInfo.video?.width ?? 0)x\(rotInfo.video?.height ?? 0))")
    let rotCast = StreamPlanner.plan(info: rotInfo, file: rotated, profile: .chromecast(model: "Chromecast Ultra", settings: hardwareOn), settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions)
    check(rotCast.isTranscodingVideo && !args(rotCast).contains("videotoolbox_vld"), "rotated video is turned for a Chromecast, off the GPU route")
    let rotApple = StreamPlanner.plan(info: rotInfo, file: rotated, profile: apple, settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions)
    check(!rotApple.isTranscodingVideo, "rotated video is left to AVPlayer")

    // Sample rates, durations and the odd cases in the probe.
    let (hires, hiresInfo) = probe("hires.mkv")
    check(hiresInfo.audio.first?.sampleRate == 96_000, "sample rate read")
    let hiresPlan = StreamPlanner.plan(info: hiresInfo, file: hires, profile: apple, settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions)
    let hiresArgs = args(hiresPlan)
    if let i = hiresArgs.firstIndex(of: "-ar") { check(hiresArgs[i + 1] == "48000", "96 kHz audio converted to 48 kHz") } else { check(false, "96 kHz audio converted to 48 kHz") }
    let (_, rawInfo) = probe("raw.h264")
    check(abs(rawInfo.duration - 8) < 0.5, "a raw stream's length is measured (\(rawInfo.duration))")
    let (_, cameraInfo) = probe("camera.avi")
    check(cameraInfo.video?.codec == "mjpeg", "Motion JPEG from a camera counts as video")
    func fixture(_ stream: String) -> MediaInfo { try! MediaProbe.parse(Data("{\"format\":{},\"streams\":[\(stream)]}".utf8)) }
    check(fixture("{\"index\":0,\"codec_name\":\"h264\",\"codec_type\":\"video\",\"avg_frame_rate\":\"0/0\",\"r_frame_rate\":\"25/1\"}").video?.fps == 25, "unknown average frame rate falls back to the nominal one")
    check(fixture("{\"index\":0,\"codec_name\":\"mjpeg\",\"codec_type\":\"video\",\"avg_frame_rate\":\"0/0\",\"r_frame_rate\":\"0/0\"}").video == nil, "cover art without its flag isn't taken for video")
    let dv5 = fixture("{\"index\":0,\"codec_name\":\"hevc\",\"codec_type\":\"video\",\"pix_fmt\":\"yuv420p10le\",\"width\":3840,\"height\":2160,\"avg_frame_rate\":\"24/1\",\"side_data_list\":[{\"side_data_type\":\"DOVI configuration record\",\"dv_profile\":5,\"dv_bl_signal_compatibility_id\":0}]}")
    let dv8 = fixture("{\"index\":0,\"codec_name\":\"hevc\",\"codec_type\":\"video\",\"pix_fmt\":\"yuv420p10le\",\"width\":3840,\"height\":2160,\"avg_frame_rate\":\"24/1\",\"color_transfer\":\"smpte2084\",\"side_data_list\":[{\"side_data_type\":\"DOVI configuration record\",\"dv_profile\":8,\"dv_bl_signal_compatibility_id\":1}]}")
    let dv5Args = args(StreamPlanner.plan(info: dv5, file: mp4, profile: apple, settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions))
    let dv8Args = args(StreamPlanner.plan(info: dv8, file: mp4, profile: apple, settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions))
    check(dv5Args.contains("dvh1") && dv5Args.contains("unofficial"), "Dolby Vision profile 5 is labeled dvh1, with its dvcC box")
    check(dv8Args.contains("hvc1") && !dv8Args.contains("dvh1"), "Dolby Vision profile 8 stays hvc1 for its HDR10 base layer")
    // A hand-built init segment with a dvh1 sample entry and a dvcC box (profile 5, level 6).
    func box(_ type: String, _ body: Data) -> Data {
        var d = Data(withUnsafeBytes(of: UInt32(body.count + 8).bigEndian) { Data($0) })
        d.append(Data(type.utf8)); d.append(body); return d
    }
    let dvcc = box("dvcC", Data([1, 0, 5 << 1 | 6 >> 5, (6 & 0x1F) << 3 | 0b101, 0, 0, 0, 0]))
    let entry = box("dvh1", Data(count: 78) + dvcc)
    let stsd = box("stsd", Data(count: 8) + entry)
    let tree = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
    check(MP4Boxes.codecs(inInit: tree) == ["dvh1.05.06"], "Dolby Vision codec string for the Cast playlist: \(MP4Boxes.codecs(inInit: tree))")

    // Software tone-mapping.
    var softwareOnly = hardwareOn; softwareOnly.hardware = false
    let (hdrFile, hdrProbe) = probe("hdr.mkv")
    let hdrSoft = StreamPlanner.plan(info: hdrProbe, file: hdrFile, profile: .chromecast(model: "Chromecast", settings: softwareOnly), settings: softwareOnly, audioIndex: nil, subtitle: nil, options: noOptions)
    check(args(hdrSoft).joined(separator: " ").contains("tonemap=tonemap=hable"), "HDR is tone-mapped when hardware encoding is off")
    let hdrSoftSession = StreamSession(plan: hdrSoft, source: hdrFile, duration: hdrProbe.duration, grid: .fixed(duration: hdrProbe.duration), cues: nil)
    check((try? await_ { try await hdrSoftSession.start(at: 0) }.get()) != nil, "software tone-mapping ran")
    hdrSoftSession.stop()

    // A thumbnail from the very end of a file, where there's no keyframe left to land on.
    let (_, _) = probe("sdr444.mkv")
    let ending = try! await_ { await Thumbnailer.shared.frame(sdr, at: 11.9, width: 160) }.get()
    check((ending?.count ?? 0) > 500, "thumbnail near the end of a file")

    // Text subtitles in the encodings they are really found in.
    func encoded(_ text: String, _ page: CFStringEncodings) -> Data {
        text.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(page.rawValue))))!
    }
    let samples: [(String, String, CFStringEncodings)] = [
        ("Привет, как дела? Это проверка кодировки субтитров.", "ru", .windowsCyrillic),
        ("Zażółć gęślą jaźń, to jest test napisów.", "pl", .windowsLatin2),
        ("Καλημέρα, πώς είσαι; Δοκιμή υποτίτλων.", "el", .windowsGreek),
        ("Merhaba, nasılsın? Altyazı denemesi, güzel günler.", "tr", .windowsLatin5),
        ("שלום, מה שלומך? בדיקת כתוביות.", "he", .windowsHebrew),
        ("こんにちは、お元気ですか。字幕のテストです。", "ja", .dosJapanese),
        ("你好，这是字幕编码测试。今天天气很好。", "zh", .GB_18030_2000),
        ("안녕하세요, 자막 인코딩 시험입니다.", "ko", .EUC_KR),
    ]
    for (text, language, page) in samples {
        check(SubtitleText.decode(encoded(text, page), language: language) == text, "subtitle text decoded: \(language)")
    }
    let latin = "¿Qué tal? Añade el café, señor.".data(using: .windowsCP1252)!
    check(SubtitleText.decode(latin, language: "es") == "¿Qué tal? Añade el café, señor.", "subtitle text decoded: es (Windows-1252)")
    let bom16 = Data([0xFF, 0xFE]) + "Hello there".data(using: .utf16LittleEndian)!
    check(SubtitleText.decode(bom16, language: nil) == "Hello there", "subtitle text decoded: UTF-16 with a mark")
    check(SubtitleText.decode("Hello there, friend".data(using: .utf16LittleEndian)!, language: nil) == "Hello there, friend", "subtitle text decoded: UTF-16 without a mark")
    check(SubtitleText.decode(Data([0xEF, 0xBB, 0xBF]) + Data("Plain".utf8), language: nil) == "Plain", "subtitle text decoded: UTF-8 mark dropped")
    let russian = mediaDir.appendingPathComponent("Movie.ru.srt")
    try! encoded("1\n00:00:01,000 --> 00:00:03,000\nПривет, мир\n\n", .windowsCyrillic).write(to: russian)
    let russianCues = try! await_ { try await SubtitleLoader.shared.cues(for: .external(russian), media: mp4) }.get()
    check(russianCues.first?.text == "Привет, мир", "Windows-1251 subtitle file reaches the player intact: \(russianCues.first?.text ?? "nil")")

    check(OpenSubtitlesClient.Failure.http(403, "").isKeyRefused && OpenSubtitlesClient.Failure.http(401, "").isKeyRefused && OpenSubtitlesClient.Failure.noKey.isKeyRefused
          && !OpenSubtitlesClient.Failure.http(503, "").isKeyRefused && !OpenSubtitlesClient.Failure.badResponse.isKeyRefused, "only a refused key counts as OpenSubtitles turning the app down")

    check(TitleCard.seconds == 3, "the poster card lasts three seconds")

    // The self-updater: what stands between a download and replacing the app.
    let updateRoot = mediaDir.appendingPathComponent("update-test", isDirectory: true)
    try? FileManager.default.removeItem(at: updateRoot)
    try! FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)
    func makeBundle(_ path: String, _ marker: String) -> URL {
        let url = updateRoot.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try! marker.write(to: url.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        return url
    }
    func marker(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("Contents/marker.txt"), encoding: .utf8) }
    let openerLog = updateRoot.appendingPathComponent("opened.txt")
    let opener = updateRoot.appendingPathComponent("opener.sh")
    try! "#!/bin/sh\necho \"$1\" >> \"\(openerLog.path)\"\n".write(to: opener, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
    func swap(_ prepared: UpdateInstaller.Prepared) {
        try? FileManager.default.removeItem(at: openerLog)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["0.6"]
        try! holder.run()
        try! UpdateInstaller.swapAfterExit(prepared, of: holder.processIdentifier, opener: opener.path)
        spin(0.2)
        check(FileManager.default.fileExists(atPath: prepared.installed.path) && marker(prepared.installed) != nil && !FileManager.default.fileExists(atPath: openerLog.path), "update: nothing is touched until the app has quit")
        spin(8) { FileManager.default.fileExists(atPath: openerLog.path) }
    }
    let installedCopy = makeBundle("Apps/Driftcast.app", "old")
    let stagingOne = updateRoot.appendingPathComponent("Apps/.staging-one", isDirectory: true)
    let newCopy = makeBundle("Apps/.staging-one/unpacked/Driftcast.app", "new")
    swap(.init(installed: installedCopy, replacement: newCopy, staging: stagingOne))
    check(marker(installedCopy) == "new", "update: the new copy takes the old one's place")
    check(!FileManager.default.fileExists(atPath: stagingOne.path), "update: nothing is left behind")
    check(((try? String(contentsOf: openerLog, encoding: .utf8)) ?? "").contains("Apps/Driftcast.app"), "update: the new copy is opened afterwards")
    let stagingTwo = makeBundle("Apps/.staging-two", "folder")
    swap(.init(installed: installedCopy, replacement: stagingTwo.appendingPathComponent("does-not-exist.app"), staging: stagingTwo))
    check(marker(installedCopy) == "new" && ((try? String(contentsOf: openerLog, encoding: .utf8)) ?? "").contains("Apps/Driftcast.app"), "update: if the new copy can't go in, the old one stays and reopens")
    check((try? UpdateInstaller.checkReplaceable(installedCopy)) != nil, "update: a copy in a writable folder can be replaced")
    check((try? UpdateInstaller.checkReplaceable(URL(fileURLWithPath: "/System/Applications/Calculator.app"))) == nil, "update: a copy in a protected folder can't")
    check((try? UpdateInstaller.checkReplaceable(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Driftcast.app"))) == nil, "update: a translocated copy can't")
    check((try? UpdateInstaller.verify(installedCopy, newerThan: "0")) == nil, "update: an unsigned bundle is refused")
    let zipRelease = AppRelease(version: "2", page: URL(string: "https://github.com/o/r")!, download: URL(string: "https://github.com/o/r/releases/download/v2/Driftcast.zip"))
    let dmgRelease = AppRelease(version: "2", page: URL(string: "https://github.com/o/r")!, download: URL(string: "https://github.com/o/r/releases/download/v2/Driftcast.dmg"))
    check(UpdateInstaller.canInstall(zipRelease) && !UpdateInstaller.canInstall(dmgRelease), "update: only a zip installs itself")
    // A real download over HTTP, with progress, to the staging name it would use.
    let directPlan = StreamPlanner.plan(info: try! await_ { try await MediaProbe.shared.probe(mp4) }.get(), file: mp4, profile: apple, settings: hardwareOn, audioIndex: nil, subtitle: nil, options: noOptions)
    let directSession = StreamSession(plan: directPlan, source: mp4, duration: 30, grid: nil, cues: nil)
    MediaServer.shared.register(directSession)
    let directURL = try! await_ { await MediaServer.shared.url(path: directSession.directPath, host: host) }.get()
    final class Seen: @unchecked Sendable { var last = 0.0 }
    let seen = Seen()
    let got = updateRoot.appendingPathComponent("download.bin")
    let fetched = await_ { try await UpdateInstaller.download(directURL, to: got) { seen.last = $0 } }
    check((try? fetched.get()) != nil && (try? Data(contentsOf: got))?.count == (try? Data(contentsOf: mp4))?.count && seen.last > 0.9, "update: download with progress (\(seen.last))")
    let missing = URL(string: "http://\(host):\(directURL.port ?? 0)/s/nothing/media.mp4")!
    let refused = await_ { try await UpdateInstaller.download(missing, to: updateRoot.appendingPathComponent("nothing.bin")) { _ in } }
    check((try? refused.get()) == nil, "update: a failed download is reported")
    MediaServer.shared.unregister(directSession)
    if let path = ProcessInfo.processInfo.environment["DRIFTCAST_RELEASE_ZIP"] {
        // The actual released app.
        let unpackFolder = updateRoot.appendingPathComponent("real", isDirectory: true)
        let real = try! await_ { try await UpdateInstaller.unpack(URL(fileURLWithPath: path), into: unpackFolder) }.get()
        check((try? UpdateInstaller.verify(real, newerThan: "0.5")) != nil, "update: a genuine release passes every check")
        var notNewer = false
        do { try UpdateInstaller.verify(real, newerThan: "99") } catch UpdateInstaller.Failure.notNewer { notNewer = true } catch {}
        check(notNewer, "update: an older release is refused")
        let licence = real.appendingPathComponent("Contents/Resources/Licenses/LICENSE.txt")
        let handle = try! FileHandle(forWritingTo: licence)
        _ = try! handle.seekToEnd(); try! handle.write(contentsOf: Data("tampered".utf8)); try! handle.close()
        var tampered = false
        do { try UpdateInstaller.verify(real, newerThan: "0.5") } catch UpdateInstaller.Failure.notSigned { tampered = true } catch {}
        check(tampered, "update: a release altered by one byte is refused")
    } else {
        print("  (no signed release on this Mac to test the signature check against)")
    }

    // Hardware that won't start: a stand-in ffmpeg that refuses VideoToolbox.
    let shim = mediaDir.appendingPathComponent("shim", isDirectory: true)
    try? FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
    let real = FFmpeg.ffmpeg!, realProbe = FFmpeg.ffprobe!
    let attempts = mediaDir.appendingPathComponent("shim-attempts.txt")
    try? FileManager.default.removeItem(at: attempts)
    let script = "#!/bin/bash\ncase \"$*\" in *-f\\ hls*h264_videotoolbox*|*h264_videotoolbox*-f\\ hls*) echo \"$*\" >> \"\(attempts.path)\"; echo 'simulated: VT session failed' >&2; exit 1;; esac\nexec \"\(real.path)\" \"$@\"\n"
    try! script.write(to: shim.appendingPathComponent("ffmpeg"), atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.appendingPathComponent("ffmpeg").path)
    try? FileManager.default.removeItem(at: shim.appendingPathComponent("ffprobe"))
    try! FileManager.default.createSymbolicLink(at: shim.appendingPathComponent("ffprobe"), withDestinationURL: realProbe)
    let savedDir = Prefs.string(Prefs.ffmpegDirectory)
    Prefs.defaults.set(shim.path, forKey: Prefs.ffmpegDirectory)
    let fallback = StreamSession(plan: sdrPlan, source: sdr, duration: sdrInfo.duration, grid: .fixed(duration: sdrInfo.duration), cues: nil)
    let fallbackStart = await_ { try await fallback.start(at: 0) }
    let tried = ((try? String(contentsOf: attempts, encoding: .utf8)) ?? "").split(separator: "\n").count
    check((try? fallbackStart.get()) != nil && tried >= 2, "a refused hardware encoder falls back to software (\(tried) attempts) \((try? fallbackStart.get()) == nil ? "\(fallbackStart)" : "")")
    fallback.stop()
    Prefs.defaults.set(savedDir, forKey: Prefs.ffmpegDirectory)

    // Pacing: ffmpeg stays within reach of the player and the disk isn't filled.
    let (long, longInfo) = probe("long.mkv")
    let longPlan = StreamPlanner.plan(info: longInfo, file: long, profile: apple, settings: forced, audioIndex: nil, subtitle: nil, options: noOptions)
    let longGrid = SegmentGrid.fixed(duration: longInfo.duration)
    let pacing = StreamSession(plan: longPlan, source: long, duration: longInfo.duration, grid: longGrid, cues: nil)
    check((try? await_ { try await pacing.start(at: 0) }.get()) != nil, "long file started (\(longGrid.count) segments)")
    let pacingDir = StreamSession.temporaryRoot.appendingPathComponent(pacing.id, isDirectory: true)
    func segmentFiles() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: pacingDir.path)) ?? []).filter { $0.hasSuffix(".m4s") } }
    spin(4)
    let early = segmentFiles().count
    check(early >= 20 && early < longGrid.count * 2 / 3, "ffmpeg stops about five minutes ahead (\(early) of \(longGrid.count) segments written)")
    spin(2)
    check(segmentFiles().count <= early + 2, "and stays stopped while nothing is asked for (\(segmentFiles().count))")
    let far = 90
    let farData = await_ { try await pacing.segment(far) }
    check((try? farData.get()) != nil, "it carries on when the player gets near \((try? farData.get()) == nil ? "\(farData)" : "")")
    spin(1)
    let oldFile = segmentFiles().sorted().first ?? ""
    check(!segmentFiles().contains(where: { $0.hasSuffix("-00000.m4s") }), "what has been played is deleted (first left: \(oldFile))")
    let back = await_ { try await pacing.segment(2) }
    check((try? back.get())?.isEmpty == false, "going back past that converts it again \((try? back.get()) == nil ? "\(back)" : "")")
    pacing.stop()
    spin(1.5)
    let leftovers = run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", pacing.id]).trimmingCharacters(in: .whitespacesAndNewlines)
    check(leftovers.isEmpty, "no frozen ffmpeg left behind after stopping (\(leftovers))")
}

// The checks kept in files of their own, one per area (Tests/HarnessSupport).
print("-- subtitles"); subtitleTests()
print("-- streaming"); streamingTests()
print("-- library and names"); MainActor.assumeIsolated { libraryTests() }
print("-- Chromecast"); castTests()
print("-- playback and windows"); MainActor.assumeIsolated { playbackTests() }
print("-- updater"); updaterTests()

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
