import Foundation

/// What ffprobe reports about a file, reduced to what playback decisions need.
struct MediaInfo: Hashable, Sendable {
    struct Video: Hashable, Sendable {
        var index: Int
        var codec: String
        var codecTag: String
        var profile: String?
        /// H.264 / HEVC level as ffprobe reports it (41 = 4.1, 120 = HEVC 4.0); 0 when unknown.
        var level: Int = 0
        var pixFmt: String
        var width: Int
        var height: Int
        var fps: Double
        var colorTransfer: String?
        var isDolbyVision: Bool
        /// "progressive", or "tt" / "bb" / "tb" / "bt" for interlaced video; nil when unknown.
        var fieldOrder: String? = nil
        /// Clockwise rotation stored in the file (90, 180, 270). `width` and `height` are already
        /// the picture as it is shown, so a phone's portrait video reads as portrait.
        var rotation: Int = 0
        /// Dolby Vision profile (5, 7, 8...) and base-layer compatibility id, when there is one.
        var dolbyVisionProfile: Int? = nil
        var dolbyVisionCompatibility: Int? = nil

        var isInterlaced: Bool { ["tt", "bb", "tb", "bt"].contains(fieldOrder ?? "") }

        /// Profile 5 has no HDR10 or SDR base layer: shown without Dolby Vision it comes out
        /// green and purple, so it has to be labelled for what it is.
        var needsDolbyVisionTag: Bool { codec == "hevc" && dolbyVisionProfile != nil && dolbyVisionCompatibility == 0 }

        var bitDepth: Int {
            if pixFmt.contains("12") { return 12 }
            if pixFmt.contains("10") || pixFmt == "p010le" { return 10 }
            return 8
        }

        var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" || isDolbyVision }

        var resolutionName: String {
            switch max(height, width * 9 / 16) {
            case 2000...: return "4K"
            case 1300...: return "1440p"
            case 1000...: return "1080p"
            case 700...: return "720p"
            case 560...: return "576p"
            case 1..<560: return "\(height)p"
            default: return "\(width)x\(height)"
            }
        }

        var hdrName: String? {
            if isDolbyVision { return "Dolby Vision" }
            if colorTransfer == "smpte2084" { return "HDR10" }
            if colorTransfer == "arib-std-b67" { return "HLG" }
            return nil
        }

        var summary: String {
            var parts = [Codecs.videoName(codec), resolutionName]
            if let hdr = hdrName { parts.append(hdr) } else if bitDepth > 8 { parts.append("\(bitDepth)-bit") }
            return parts.joined(separator: " ")
        }
    }

    struct Audio: Hashable, Identifiable, Sendable {
        var index: Int
        var codec: String
        var profile: String?
        var channels: Int
        var language: String?
        var title: String?
        var isDefault: Bool
        var sampleRate: Int = 0
        var id: Int { index }

        var codecName: String { Codecs.audioName(codec, profile: profile) }

        var label: String {
            var parts: [String] = []
            if let l = Lang.name(language) { parts.append(l) }
            parts.append("\(codecName) \(Codecs.channelName(channels))")
            if let t = title, !t.isEmpty, t != parts.first { parts.append(t) }
            return parts.joined(separator: " · ")
        }
    }

    struct Subtitle: Hashable, Identifiable, Sendable {
        var index: Int
        var codec: String
        var language: String?
        var title: String?
        var isDefault: Bool
        var isForced: Bool
        var id: Int { index }

        static let pictureCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]
        static let textCodecs: Set<String> = ["subrip", "ass", "ssa", "webvtt", "mov_text", "text", "srt", "microdvd", "subviewer", "jacosub", "sami", "realtext", "stl", "mpl2", "pjs", "vplayer"]

        var isPicture: Bool { Self.pictureCodecs.contains(codec) }
        var isSupported: Bool { isPicture || Self.textCodecs.contains(codec) }
    }

    var duration: Double
    var formatName: String
    var bitRate: Int?
    var video: Video?
    var audio: [Audio]
    var subtitles: [Subtitle]
    /// Where the file's own clock starts. Transport streams often start hours in; everything
    /// else in Driftcast counts from the start of the film, so this is subtracted where it matters.
    var startTime: Double = 0

    var summary: String {
        var parts: [String] = []
        if let v = video { parts.append(v.summary) }
        if let a = audio.first(where: \.isDefault) ?? audio.first { parts.append("\(a.codecName) \(Codecs.channelName(a.channels))") }
        if audio.count > 1 { parts.append("\(audio.count) audio tracks") }
        if !subtitles.isEmpty { parts.append(subtitles.count == 1 ? "1 subtitle" : "\(subtitles.count) subtitles") }
        return parts.joined(separator: " · ")
    }
}

enum Codecs {
    static func videoName(_ codec: String) -> String {
        switch codec {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vp8": return "VP8"
        case "mpeg4": return "MPEG-4"
        case "mpeg2video": return "MPEG-2"
        case "mpeg1video": return "MPEG-1"
        case "msmpeg4v3": return "DivX 3"
        case "wmv3", "wmv2", "wmv1": return "WMV"
        case "vc1": return "VC-1"
        case "prores": return "ProRes"
        default: return codec.uppercased()
        }
    }

    static func audioName(_ codec: String, profile: String? = nil) -> String {
        switch codec {
        case "aac": return profile?.contains("HE") == true ? "HE-AAC" : "AAC"
        case "ac3": return "Dolby Digital"
        case "eac3": return profile?.contains("Atmos") == true ? "Dolby Digital+ Atmos" : "Dolby Digital+"
        case "truehd": return profile?.contains("Atmos") == true ? "TrueHD Atmos" : "Dolby TrueHD"
        case "dts":
            if let p = profile, p.contains("MA") { return "DTS-HD MA" }
            if let p = profile, p.contains("HRA") || p.contains("HD") { return "DTS-HD" }
            return "DTS"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "mp3": return "MP3"
        case "mp2": return "MP2"
        case "alac": return "ALAC"
        case let c where c.hasPrefix("pcm_"): return "PCM"
        case "wmav2", "wmapro": return "WMA"
        default: return codec.uppercased()
        }
    }

    static func channelName(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    static func subtitleName(_ codec: String) -> String {
        switch codec {
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "webvtt": return "WebVTT"
        case "mov_text": return "Text"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }
}

/// Runs ffprobe and caches results per file.
actor MediaProbe {
    static let shared = MediaProbe()

    private var cache: [URL: MediaInfo] = [:]
    private var inFlight: [URL: Task<MediaInfo, Error>] = [:]
    private let limiter = AsyncLimiter(4)

    func cached(_ url: URL) -> MediaInfo? { cache[url] }

    func probe(_ url: URL) async throws -> MediaInfo {
        if let info = cache[url] { return info }
        if let task = inFlight[url] { return try await task.value }
        let limiter = self.limiter
        let task = Task<MediaInfo, Error> {
            guard let exe = FFmpeg.ffprobe else { throw FFmpegError.notFound }
            await limiter.acquire()
            do {
                let data = try await FFmpeg.run(exe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
                var info = try Self.parse(data)
                if info.duration <= 0, let v = info.video { info.duration = await Self.measureDuration(exe, url, video: v) }
                await limiter.release()
                return info
            } catch {
                await limiter.release()
                throw error
            }
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let info = try await task.value
        cache[url] = info
        return info
    }

    /// Files that don't say how long they are (raw .h264 / .hevc streams, some recordings):
    /// counts the video's packets. Zero when that doesn't work either.
    private static func measureDuration(_ exe: URL, _ url: URL, video: MediaInfo.Video) async -> Double {
        guard video.fps > 0, let data = try? await FFmpeg.run(exe, ["-v", "error", "-select_streams", "\(video.index)", "-count_packets",
                                                                    "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", url.path]) else { return 0 }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: ",\n "))
        return Double(text).map { $0 / video.fps } ?? 0
    }

    static func parse(_ data: Data) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFmpegError.failed("ffprobe returned unreadable output.")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = root["streams"] as? [[String: Any]] ?? []
        var duration = Double(format["duration"] as? String ?? "") ?? 0
        var video: MediaInfo.Video?
        var audio: [MediaInfo.Audio] = []
        var subs: [MediaInfo.Subtitle] = []

        for s in streams {
            let index = s["index"] as? Int ?? 0
            let codec = s["codec_name"] as? String ?? "unknown"
            let tags = s["tags"] as? [String: Any] ?? [:]
            let language = (tags["language"] ?? tags["LANGUAGE"]) as? String
            let title = (tags["title"] ?? tags["TITLE"]) as? String
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            let isDefault = (disposition["default"] as? Int) == 1
            let isForced = (disposition["forced"] as? Int) == 1

            switch s["codec_type"] as? String {
            case "video":
                if (disposition["attached_pic"] as? Int) == 1 || video != nil { continue }
                let fps = parseRate(s["avg_frame_rate"] as? String) ?? parseRate(s["r_frame_rate"] as? String) ?? 0
                // Cover art without the attached-picture flag: a still image has no frame rate.
                // Motion JPEG from older cameras is real video and does have one.
                if ["mjpeg", "png", "bmp"].contains(codec), fps <= 0 || Int(s["nb_frames"] as? String ?? "") == 1 { continue }
                let sideData = s["side_data_list"] as? [[String: Any]] ?? []
                let dovi = sideData.first { ($0["side_data_type"] as? String)?.contains("DOVI") == true }
                let matrix = sideData.first { $0["rotation"] != nil }
                let turn = (((matrix?["rotation"] as? Int) ?? 0) % 360 + 360) % 360
                var width = s["width"] as? Int ?? 0, height = s["height"] as? Int ?? 0
                if turn == 90 || turn == 270 { swap(&width, &height) }
                video = MediaInfo.Video(
                    index: index, codec: codec,
                    codecTag: s["codec_tag_string"] as? String ?? "",
                    profile: s["profile"] as? String,
                    level: max(0, s["level"] as? Int ?? 0),
                    pixFmt: s["pix_fmt"] as? String ?? "yuv420p",
                    width: width, height: height,
                    fps: fps,
                    colorTransfer: s["color_transfer"] as? String,
                    isDolbyVision: dovi != nil,
                    fieldOrder: s["field_order"] as? String,
                    rotation: turn,
                    dolbyVisionProfile: dovi?["dv_profile"] as? Int,
                    dolbyVisionCompatibility: dovi?["dv_bl_signal_compatibility_id"] as? Int)
                if duration == 0 { duration = Double(s["duration"] as? String ?? "") ?? 0 }
            case "audio":
                audio.append(MediaInfo.Audio(index: index, codec: codec, profile: s["profile"] as? String,
                                             channels: s["channels"] as? Int ?? 2, language: language,
                                             title: title, isDefault: isDefault,
                                             sampleRate: Int(s["sample_rate"] as? String ?? "") ?? 0))
            case "subtitle":
                let sub = MediaInfo.Subtitle(index: index, codec: codec, language: language, title: title,
                                             isDefault: isDefault, isForced: isForced)
                if sub.isSupported { subs.append(sub) }
            default:
                continue
            }
        }
        let bitRate = Int(format["bit_rate"] as? String ?? "")
        return MediaInfo(duration: duration, formatName: format["format_name"] as? String ?? "",
                         bitRate: bitRate, video: video, audio: audio, subtitles: subs,
                         startTime: Double(format["start_time"] as? String ?? "") ?? 0)
    }

    private static func parseRate(_ s: String?) -> Double? {
        guard let s else { return nil }
        let parts = s.split(separator: "/").compactMap { Double($0) }
        // "0/0" is ffprobe's "don't know"; returning nil lets the caller try the other rate.
        if parts.count == 2 { return parts[1] > 0 && parts[0] > 0 ? parts[0] / parts[1] : nil }
        return parts.first
    }
}
