import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)   // a crash shouldn't lose the lines before it
let mediaDir = URL(fileURLWithPath: CommandLine.arguments[1])
let mkv = mediaDir.appendingPathComponent("Test.Movie.2024.1080p.mkv")
let mp4 = mediaDir.appendingPathComponent("simple.mp4")

func spin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
func await_<T>(_ op: @escaping () async throws -> T) -> Result<T, Error> {
    var r: Result<T, Error>?
    Task { do { r = .success(try await op()) } catch { r = .failure(error) } }
    spin(120) { r != nil }
    return r!
}
func fetch(_ url: URL, range: String? = nil) -> (Int, Data, [AnyHashable: Any]) {
    var req = URLRequest(url: url); if let range { req.setValue(range, forHTTPHeaderField: "Range") }
    let r = await_ { try await URLSession.shared.data(for: req) }
    let (d, resp) = try! r.get(); let h = resp as! HTTPURLResponse
    return (h.statusCode, d, h.allHeaderFields)
}
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }

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
for key in [Prefs.subtitleLanguage, Prefs.subtitleAuto, Prefs.autoSearchSubtitles] { Prefs.defaults.removeObject(forKey: key) }

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
s1.intro = StreamSession.Intro(card: card!, size: CGSize(width: 1920, height: 1080), atSegment: 0, hardware: true)
let st1 = await_ { try await s1.start(at: 0) }
check((try? st1.get()) != nil, "apple session started \((try? st1.get()) == nil ? "\(st1)" : "")")
let master = try! await_ { await MediaServer.shared.url(path: s1.masterPath, host: host) }.get()
let (_, mdata, _) = fetch(master)
print(String(decoding: mdata, as: UTF8.self).split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
let (_, pl, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("stream.m3u8"))
let plText = String(decoding: pl, as: UTF8.self)
print(plText.split(separator: "\n").prefix(12).map { "  | " + $0 }.joined(separator: "\n"))
check(plText.contains("#EXT-X-PLAYLIST-TYPE:VOD") && plText.contains("#EXT-X-ENDLIST") && plText.contains("seg00003.m4s"), "VOD playlist complete up front")
check(s1.intro != nil && plText.hasPrefix("#EXTM3U") && plText.contains("#EXT-X-MAP:URI=\"intro-init.mp4\"\n#EXTINF:") && plText.contains("intro-0.m4s\n#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:"),
      "title card clip leads the playlist behind a discontinuity (card \(String(format: "%.2f", s1.intro?.duration ?? 0)) s)")
let (introStatus, introInit, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("intro-init.mp4"))
let (introSegStatus, introSeg, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("intro-0.m4s"))
check(introStatus == 200 && introInit.count > 200 && introSegStatus == 200 && introSeg.count > 5_000 && MP4Boxes.codecs(inInit: introInit).first?.hasPrefix("avc1.") == true,
      "card clip served: init \(introInit.count) bytes (\(MP4Boxes.codecs(inInit: introInit))), segment \(introSeg.count) bytes")
let cardLength = s1.intro?.duration ?? 0
check(s1.deviceTime(forFileTime: 0) == cardLength && s1.fileTime(forDeviceTime: 1) == 0 && abs(s1.fileTime(forDeviceTime: 10) - (10 - cardLength)) < 0.001
      && abs(s1.deviceDuration - (info.duration + cardLength)) < 0.001, "timeline mapping around the card")
let subPlaylist = s1.subtitlePlaylist()
check(subPlaylist.contains("subs-card.vtt\n#EXT-X-DISCONTINUITY\n#EXTINF:") && subPlaylist.hasPrefix("#EXTM3U") && !subPlaylist.contains("#EXT-X-DISCONTINUITY\n#EXTINF:3.500,\nsubs-card")
      && s1.subtitleSegment(Int(subCues[0].start / 10)).contains(WebVTT.stamp(subCues[0].start)),
      "subtitle rendition shares the card's discontinuities and keeps file-time cues")
let s1c = StreamSession(plan: applePlan, source: mkv, duration: info.duration, grid: copyGrid, cues: subCues)
s1c.intro = StreamSession.Intro(card: card!, size: CGSize(width: 1920, height: 1080), atSegment: 2, hardware: true)
let midSubs = s1c.subtitlePlaylist()
check(midSubs.contains("subs-2.vtt\n#EXT-X-DISCONTINUITY\n#EXTINF:5.000,\nsubs-card.vtt\n#EXT-X-DISCONTINUITY\n#EXTINF:") && midSubs.contains("subs-3.vtt") && s1c.subtitleSegment(3).contains("WEBVTT"),
      "a mid-file card splits the subtitle segments at the same point: \(midSubs.split(separator: "\n").filter { $0.hasPrefix("subs") || $0.hasPrefix("#EXT-X-D") }.joined(separator: " "))")
let (_, seg1, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("subs-1.vtt"))
print(String(decoding: seg1, as: UTF8.self).split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
// The Chromecast master playlist names the codecs it carries (HEVC Main 10 copied, DTS -> E-AC-3).
let (castStatus, castData, _) = fetch(master.deletingLastPathComponent().appendingPathComponent("cast.m3u8"))
let castText = String(decoding: castData, as: UTF8.self)
print(castText.split(separator: "\n").map { "  | " + $0 }.joined(separator: "\n"))
check(castStatus == 200 && castText.contains("CODECS=\"hvc1.2.4.L") && castText.contains(",ec-3\"") && castText.contains("RESOLUTION=1920x1080") && castText.contains("FRAME-RATE=24.000"),
      "cast playlist carries HEVC Main 10 + E-AC-3 codec strings and the picture size")
let initCodecs = MP4Boxes.codecs(inInit: s1.initSegment() ?? Data())
check(initCodecs.count == 2 && initCodecs[0].hasPrefix("hvc1.2.4.L") && initCodecs[1] == "ec-3", "codec strings read from the init segment: \(initCodecs)")
let (partialStatus, partialData, partialHeaders) = fetch(master.deletingLastPathComponent().appendingPathComponent("init.mp4"), range: "bytes=0-99")
check(partialStatus == 206 && partialData.count == 100 && (partialHeaders["Content-Range"] as? String)?.hasPrefix("bytes 0-99/") == true, "range request on an in-memory body")

let s1b = StreamSession(plan: applePlan, source: mkv, duration: info.duration, grid: copyGrid, cues: nil)
s1b.intro = StreamSession.Intro(card: card!, size: CGSize(width: 1920, height: 1080), atSegment: 2, hardware: true)
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
var names = lib.playlists.first { $0.id == pid }!.items.map(\.title)
check(names == ["Test.Movie.2024.1080p", "hdr", "simple"], "move first to end: \(names)")
lib.move(in: pid, from: IndexSet(integer: 2), to: 0)
names = lib.playlists.first { $0.id == pid }!.items.map(\.title)
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
check(grouped.series == [SeriesName.Group(title: "Sopranos", members: [0, 2])] && grouped.rest == [1, 3], "series: grouping keeps single files out: \(grouped)")
do {
    let dir = mediaDir.appendingPathComponent("series", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let files = ["Sopranos.S1.E12.dolbuy.mp4", "Sopranos.S1.E2.dolbuy.mp4", "Sopranos.S1.E11.dolbuy.mp4", "Heat.1995.mp4"].map { dir.appendingPathComponent($0) }
    files.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) }
    let other = lib.newPlaylist(named: "harness2")
    let before = lib.playlists.count
    let added = lib.add(files, to: other)
    let show = lib.playlists.first { $0.name == "Sopranos" }
    check(lib.playlists.count == before + 1 && show?.items.map(\.title) == ["Sopranos.S1.E2.dolbuy", "Sopranos.S1.E11.dolbuy", "Sopranos.S1.E12.dolbuy"],
          "dropping episodes makes a Sopranos playlist in episode order: \(show?.items.map(\.title) ?? [])")
    check(lib.playlists.first { $0.id == other }?.items.map(\.title) == ["Heat.1995"] && added.count == 4 && lib.selection == show?.id, "the odd film stays in the playlist it was dropped on; the show is selected")
    lib.add(files, to: other)
    check(lib.playlists.filter { $0.name == "Sopranos" }.count == 1 && lib.playlists.first { $0.name == "Sopranos" }?.items.count == 3, "dropping the same episodes again reuses the playlist without duplicates")
    if let show { lib.deletePlaylist(show.id) }
    lib.deletePlaylist(other)
    let empty = lib.newPlaylist()
    lib.add(Array(files.prefix(3)), to: empty)
    check(lib.playlists.first { $0.id == empty }?.name == "Sopranos", "an empty default playlist is renamed to the show")
    lib.deletePlaylist(empty)
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
      && omdb?.runtimeMinutes == 170 && omdb?.link?.absoluteString == "https://www.imdb.com/title/tt0113277/" && omdb?.shortRating == "IMDb 8.3",
      "OMDb parsed with three ratings: \(omdb?.ratings.map(\.value) ?? [])")
check(OMDbClient.parse(Data("{\"Response\":\"False\",\"Error\":\"Movie not found!\"}".utf8), wanted: heat) == nil, "OMDb 'not found' gives nothing")

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
    check(dv5Args.contains("dvh1") && dv5Args.contains("unofficial"), "Dolby Vision profile 5 is labelled dvh1, with its dvcC box")
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
          && !OpenSubtitlesClient.Failure.http(503, "").isKeyRefused && !OpenSubtitlesClient.Failure.badResponse.isKeyRefused, "only a refused key sends the search dialog back to the key box")

    check(TitleCard.seconds == 5, "the poster card lasts five seconds")

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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
