import Foundation

/// What a playback device can decode natively.
struct DeviceProfile: Sendable {
    enum Family: Sendable { case apple, chromecast }

    var family: Family
    var videoCodecs: Set<String>
    var maxHeight: Int
    var supportsHDR: Bool
    var audioCodecs: Set<String>
    var maxCopyChannels: Int
    var directExtensions: Set<String>
    /// Speakers and speaker groups: the video stream is dropped and only audio is sent.
    var audioOnly = false
    /// Highest H.264 level the device decodes (41 = 4.1); 0 means no limit is known.
    var maxH264Level = 0
    /// Tallest picture the device plays above 30 frames per second (older Chromecasts manage
    /// 1080p only at 30 fps, and 720p at 60).
    var maxHeightAbove30fps = 2160

    /// Apple TV, AirPlay 2 TVs and this Mac (all through AVPlayer).
    static func apple() -> DeviceProfile {
        DeviceProfile(family: .apple, videoCodecs: ["h264", "hevc"], maxHeight: 2160, supportsHDR: true,
                      audioCodecs: ["aac", "ac3", "eac3", "flac", "alac", "mp3"], maxCopyChannels: 8,
                      directExtensions: ["mp4", "m4v", "mov"])
    }

    /// Which generation of Cast hardware a model name describes. Google publishes the limits
    /// per device (developers.google.com/cast/docs/media); the TXT record's `md` names the model.
    enum CastHardware {
        /// Chromecast 1st to 3rd generation: 1080p30 or 720p60, H.264 up to level 4.1/4.2, no HEVC.
        case classic
        /// Chromecast HD (2022): 1080p, HEVC and HDR.
        case hd
        /// Chromecast Ultra, Chromecast with Google TV, Google TV Streamer, TVs with Cast built in.
        case fourK
        /// Nest Hub and other smart displays: 720p.
        case display
        /// Speakers and groups.
        case audio

        static func detect(model: String, capabilities: Int?) -> CastHardware {
            let m = model.lowercased()
            if CastDeviceInfo.isAudioOnly(model: model, capabilities: capabilities) { return .audio }
            if m.contains("hub") || m.contains("smart display") { return .display }
            if m == "chromecast hd" { return .hd }
            if m == "chromecast" || m == "eureka dongle" { return .classic }
            return .fourK
        }
    }

    /// Chromecast capabilities vary by model; `capabilities` is the TXT record's `ca` bitmask.
    static func chromecast(model: String, capabilities: Int? = nil, settings: EncoderSettings) -> DeviceProfile {
        let m = model.lowercased()
        let hardware = CastHardware.detect(model: model, capabilities: capabilities)
        let hevcCapable = hardware == .fourK || hardware == .hd
        let hevc: Bool
        switch settings.castHEVC {
        case .on: hevc = true
        case .off: hevc = false
        case .auto: hevc = hevcCapable
        }
        var video: Set<String> = ["h264"]
        switch hardware {
        case .classic: video.insert("vp8")
        case .display: video.insert("vp9")
        case .hd, .fourK: video.insert("vp9")
        case .audio: break
        }
        if hevc { video.insert("hevc") }
        if m.contains("streamer") { video.insert("av1") }
        var audio: Set<String> = ["aac", "mp3", "opus", "flac"] // Vorbis can't go in fMP4
        if settings.castPassthrough { audio.formUnion(["ac3", "eac3"]) }

        let maxHeight: Int, maxLevel: Int, fastHeight: Int
        switch hardware {
        case .classic: maxHeight = 1080; maxLevel = 41; fastHeight = 720
        case .hd: maxHeight = 1080; maxLevel = 42; fastHeight = 1080
        case .display: maxHeight = 720; maxLevel = 41; fastHeight = 720
        case .fourK, .audio: maxHeight = 2160; maxLevel = 51; fastHeight = 2160
        }
        return DeviceProfile(family: .chromecast, videoCodecs: video, maxHeight: maxHeight,
                             supportsHDR: hevcCapable && hevc, audioCodecs: audio,
                             maxCopyChannels: settings.castPassthrough ? 8 : 2,
                             directExtensions: ["mp4", "m4v", "webm"],
                             audioOnly: hardware == .audio,
                             maxH264Level: maxLevel, maxHeightAbove30fps: fastHeight)
    }
}

/// Encoder preferences, read from Settings at the moment a stream starts.
struct EncoderSettings: Sendable, Equatable {
    enum CastHEVC: String, CaseIterable, Sendable { case auto, on, off }
    enum CastAudio: String, CaseIterable, Sendable { case aac, opus }
    enum AppleSurround: String, CaseIterable, Sendable { case eac3, flac, stereo }

    var hardware: Bool
    var videoBitrateMbps: Int
    var maxResolution: Int
    var forceTranscode: Bool
    var castHEVC: CastHEVC
    var castAudio: CastAudio
    var castPassthrough: Bool
    var appleSurround: AppleSurround

    static func current() -> EncoderSettings {
        EncoderSettings(
            hardware: Prefs.bool(Prefs.hardwareEncoding),
            videoBitrateMbps: max(2, Prefs.int(Prefs.videoBitrate)),
            maxResolution: max(480, Prefs.int(Prefs.maxResolution)),
            forceTranscode: Prefs.bool(Prefs.forceTranscode),
            castHEVC: CastHEVC(rawValue: Prefs.string(Prefs.castHEVC)) ?? .auto,
            castAudio: CastAudio(rawValue: Prefs.string(Prefs.castAudioCodec)) ?? .aac,
            castPassthrough: Prefs.bool(Prefs.castPassthrough),
            appleSurround: AppleSurround(rawValue: Prefs.string(Prefs.appleSurround)) ?? .eac3)
    }
}

/// Per-playback audio adjustments from the Now Playing bar.
struct PlaybackOptions: Hashable, Sendable {
    var volumeBoost = false
    var downmix = false
    /// Seconds; positive delays the audio, negative makes it earlier.
    var avSyncOffset: Double = 0
}

struct StreamPlan: Sendable {
    enum Mode: Sendable { case direct, hls }
    enum VideoAction: Sendable { case none, copy, transcode(maxHeight: Int, bitrateKbps: Int, hardware: Bool) }
    enum AudioCodec: String, Sendable { case aac, eac3, flac, opus }
    enum AudioAction: Sendable { case none, copy, encode(AudioCodec, channels: Int, bitrateKbps: Int) }

    /// How much of a conversion runs on the GPU, most first. A stream starts at the top and
    /// steps down if ffmpeg won't start that way (a virtual machine, an old GPU, a stuck session).
    enum Route: Int, Sendable {
        /// Decode, scale and encode all in VideoToolbox: frames never come back to the CPU.
        case gpu
        /// Decode and scale in software, encode in VideoToolbox.
        case hardwareEncoder
        /// libx264.
        case software
    }

    static let segmentSeconds = 4

    var mode: Mode
    var video: MediaInfo.Video?
    var videoAction: VideoAction
    var audio: MediaInfo.Audio?
    var audioAction: AudioAction
    var textSubtitle: SubtitleChoice?
    var burnSubtitle: SubtitleChoice?
    var options: PlaybackOptions
    var notes: [String]
    /// The file's overall bit rate, when ffprobe knew it (for playlist BANDWIDTH estimates).
    var sourceBitRate: Int?
    /// Where the file's own clock starts (see `MediaInfo.startTime`).
    var sourceStartTime: Double = 0

    /// The video is dropped (speakers and speaker groups).
    var isAudioOnly: Bool {
        if case .none = videoAction { return video != nil }
        return false
    }

    var isRemuxOnly: Bool {
        if case .transcode = videoAction { return false }
        if case .encode = audioAction { return false }
        return true
    }

    var isTranscodingVideo: Bool {
        if case .transcode = videoAction { return true }
        return false
    }

    /// The picture size the device receives: the source's, or scaled to the conversion height.
    var outputVideoSize: CGSize? {
        guard let v = video, v.width > 0, v.height > 0, !isAudioOnly else { return nil }
        if case .transcode(let maxHeight, _, _) = videoAction, v.height > maxHeight {
            return CGSize(width: max(2, v.width * maxHeight / v.height / 2 * 2), height: maxHeight)
        }
        return CGSize(width: v.width, height: v.height)
    }

    var isCopyingVideo: Bool {
        if case .copy = videoAction { return true }
        return false
    }

    /// ffmpeg arguments writing fMP4 HLS segments (`<prefix>00000.m4s`…) into `outputDirectory`
    /// from `startTime`. Timestamps are kept absolute (`-copyts`) so segments from several runs
    /// line up on one timeline.
    func ffmpegArguments(input: URL, startTime: Double, limitSeconds: Double?, outputDirectory dir: URL,
                         filePrefix: String, route: Route = .gpu) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-copyts"]
        let seek: [String] = startTime > 0.0005 ? ["-ss", String(format: "%.4f", startTime)] : []
        // A file whose clock doesn't start at zero (transport streams, recordings): with -copyts
        // its timestamps would stay hours in, off the grid that counts from the start of the film.
        if abs(sourceStartTime) > 0.02 { args.append("-start_at_zero") }

        var useHardware = false
        if case .transcode(_, _, let hardware) = videoAction { useHardware = hardware && route != .software }
        // Deinterlacing, drawing in subtitles and turning the picture are CPU filters, so those
        // need the frames in ordinary memory.
        let allOnGPU = useHardware && route == .gpu && burnSubtitle == nil && video.map { !$0.isInterlaced && $0.rotation == 0 && $0.height > 0 } == true
            && FFmpeg.hasFilter("scale_vt")
        // VideoToolbox decodes what the Mac's GPU can (H.264, HEVC, VP9, ProRes, MPEG-2...) and
        // ffmpeg carries on in software for the rest, which hwupload then hands to the GPU.
        var hardwareDecode: [String] = []
        if useHardware && route == .gpu {
            hardwareDecode = ["-hwaccel", "videotoolbox"]
            if allOnGPU { hardwareDecode += ["-hwaccel_output_format", "videotoolbox_vld"] }
        }

        args += ["-fflags", "+genpts"] + hardwareDecode + seek + ["-i", input.path]
        var nextInput = 1

        var audioInput = 0
        if audio != nil, options.avSyncOffset != 0 {
            args += ["-itsoffset", String(format: "%.3f", options.avSyncOffset)] + seek + ["-i", input.path]
            audioInput = nextInput
            nextInput += 1
        }

        var burnSource: String?
        if let burn = burnSubtitle {
            switch burn {
            case .embedded(let s):
                burnSource = "[0:\(s.index)]"
            case .external(let url):
                args += seek + ["-i", url.path]
                burnSource = "[\(nextInput):s:0]"
                nextInput += 1
            }
        }

        let seg = Self.segmentSeconds
        if let v = video {
            switch videoAction {
            case .none:
                args += ["-vn"]
            case .copy:
                args += ["-map", "0:\(v.index)", "-c:v", "copy"]
                if v.needsDolbyVisionTag {
                    // Written with its dvcC box, which the muxer only adds at this strictness.
                    args += ["-tag:v", "dvh1", "-strict", "unofficial"]
                } else if v.codec == "hevc" {
                    args += ["-tag:v", "hvc1"]
                }
            case .transcode(let height, let kbps, _):
                var graph = ""
                var label = "[0:\(v.index)]"
                if v.isInterlaced {
                    // Only frames flagged as interlaced are touched, so film on DVD stays sharp.
                    graph += "\(label)bwdif=mode=send_frame:parity=auto:deint=interlaced[deint];"
                    label = "[deint]"
                }
                if let src = burnSource {
                    // Picture subtitles (PGS / VobSub) are composited onto the video.
                    graph += "\(label)\(src)overlay=eof_action=pass[ov];"
                    label = "[ov]"
                }
                // Even, because 4:2:0 video can't have an odd size.
                let scale = "scale=-2:'trunc(min(\(height),ih)/2)*2'"
                let outH = min(height, v.height) / 2 * 2
                let outW = v.height > 0 ? max(2, v.width * outH / v.height / 2 * 2) : 0
                // Converting to BT.709 is what tone-maps PQ / HLG to SDR on the GPU.
                let toSDR = v.isHDR ? ":color_matrix=bt709:color_primaries=bt709:color_transfer=bt709" : ""
                if allOnGPU || (useHardware && v.isHDR && v.height > 0) {
                    // hwupload needs the device created up front; frames already on the GPU pass through it.
                    args.insert(contentsOf: ["-init_hw_device", "videotoolbox"], at: 1)
                    graph += "\(label)hwupload,scale_vt=w=\(outW):h=\(outH)\(toSDR)[vout]"
                } else if v.colorTransfer == "smpte2084" || v.colorTransfer == "arib-std-b67", FFmpeg.hasFilter("zscale") {
                    // HDR to SDR in software, for when hardware encoding is off or unavailable.
                    // Scaled first: the tone-mapping is the slow part.
                    graph += "\(label)\(scale),zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p[vout]"
                } else {
                    graph += "\(label)\(scale),format=yuv420p[vout]"
                }
                args += ["-filter_complex", graph, "-map", "[vout]"]
                // TVs and Chromecasts don't take more than 60 frames a second.
                let fps = v.fps > 61 ? 60 : v.fps
                if v.fps > 61 { args += ["-fpsmax", "60"] }
                if useHardware {
                    // -g matters: without it VideoToolbox starts a new keyframe every 12 frames
                    // and spends most of the bit rate on them. No -maxrate: it can stall the
                    // encoder at the high rates used for 4K.
                    let gop = max(1, Int(((fps > 0 ? fps : 30) * Double(seg)).rounded(.up)))
                    args += ["-c:v", "h264_videotoolbox", "-b:v", "\(kbps)k", "-g", "\(gop)",
                             "-profile:v", "high", "-allow_sw", "1", "-realtime", "0"]
                } else {
                    args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-maxrate", "\(kbps)k",
                             "-bufsize", "\(kbps * 2)k", "-profile:v", "high"]
                }
                args += ["-force_key_frames", "expr:gte(t,n_forced*\(seg))"]
            }
        } else {
            args += ["-vn"]
        }

        if let a = audio {
            args += ["-map", "\(audioInput):\(a.index)"]
            switch audioAction {
            case .none, .copy:
                args += ["-c:a", "copy"]
                // AAC in a transport stream carries ADTS headers, which MP4 doesn't allow: without
                // this ffmpeg stops after the first segment. Other sources pass through unchanged.
                if a.codec == "aac" { args += ["-bsf:a", "aac_adtstoasc"] }
            case .encode(let codec, let channels, let kbps):
                var filters: [String] = []
                if options.volumeBoost {
                    // Lifts quiet dialogue and tames loud effects, then guards against clipping.
                    filters.append("dynaudnorm=f=150:g=15:p=0.9:m=10")
                    filters.append("alimiter=limit=0.95")
                }
                filters.append("aresample=async=1")
                args += ["-af", filters.joined(separator: ",")]
                switch codec {
                case .aac:
                    args += ["-c:a", "aac", "-b:a", "\(kbps)k"]
                    // AAC would keep a Blu-ray's 96 kHz, which TV decoders commonly refuse.
                    if a.sampleRate > 48_000 { args += ["-ar", "48000"] }
                case .opus: args += ["-c:a", "libopus", "-b:a", "\(kbps)k"]
                case .eac3: args += ["-c:a", "eac3", "-b:a", "\(kbps)k"]
                case .flac: args += ["-c:a", "flac", "-strict", "-2"]
                }
                args += ["-ac", "\(channels)"]
            }
        } else {
            args += ["-an"]
        }

        args += ["-sn", "-dn", "-map_metadata", "-1", "-map_chapters", "-1", "-max_muxing_queue_size", "4096"]
        if let limitSeconds { args += ["-t", String(format: "%.3f", limitSeconds)] }
        // Copied video splits at every source keyframe (hls_time 0); converted video on the 4 s grid.
        let hlsTime = (video != nil && isCopyingVideo) ? "0" : "\(seg)"
        args += ["-f", "hls", "-hls_time", hlsTime, "-hls_list_size", "0", "-start_number", "0",
                 "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", filePrefix + "init.mp4",
                 "-hls_flags", "independent_segments+temp_file",
                 "-hls_segment_filename", dir.appendingPathComponent(filePrefix + "%05d.m4s").path,
                 dir.appendingPathComponent(filePrefix + "playlist.m3u8").path]
        return args
    }
}

enum StreamPlanner {
    /// Decides, per stream, whether the device can take the original or needs a converted copy.
    /// Passing streams through untouched is always preferred: it costs no quality and almost no CPU.
    /// `subtitleIsText` marks a picture subtitle that OCR has already turned into cues, so it is
    /// sent as a text track instead of being drawn into the video.
    static func plan(info: MediaInfo, file: URL, profile: DeviceProfile, settings: EncoderSettings,
                     audioIndex: Int?, subtitle: SubtitleChoice?, subtitleIsText: Bool = false,
                     options: PlaybackOptions) -> StreamPlan {
        var notes: [String] = []
        let burn = (subtitle?.isPicture == true && !subtitleIsText) ? subtitle : nil
        let text = subtitle != nil && burn == nil ? subtitle : nil
        var heightLimit = min(profile.maxHeight, settings.maxResolution)
        if let v = info.video, v.fps > 31 { heightLimit = min(heightLimit, profile.maxHeightAbove30fps) }

        // Video
        var videoAction: StreamPlan.VideoAction = .none
        if profile.audioOnly {
            if info.video != nil { notes.append("Video: not sent, this device plays audio only") }
        } else if let v = info.video {
            var reasons: [String] = []
            if settings.forceTranscode { reasons.append("conversion is forced in Settings") }
            if !profile.videoCodecs.contains(v.codec) { reasons.append("\(Codecs.videoName(v.codec)) isn't supported by this device") }
            if v.height > heightLimit {
                reasons.append(v.fps > 31 && heightLimit < profile.maxHeight ? "taller than \(heightLimit)p at \(Int(v.fps.rounded())) fps" : "taller than \(heightLimit)p")
            }
            if v.codec == "h264", profile.maxH264Level > 0, v.level > profile.maxH264Level {
                reasons.append(String(format: "H.264 level %.1f is above this device's %.1f", Double(v.level) / 10, Double(profile.maxH264Level) / 10))
            }
            if v.codec == "h264" && v.bitDepth > 8 { reasons.append("10-bit H.264 isn't widely supported") }
            if !["yuv420p", "yuvj420p", "yuv420p10le", "p010le"].contains(v.pixFmt) { reasons.append("pixel format \(v.pixFmt)") }
            if v.isHDR && !profile.supportsHDR { reasons.append("the device can't show HDR, tone-mapped to SDR") }
            // HLS players and TVs expect progressive video; copied as it is, it would show combing.
            if v.isInterlaced { reasons.append("interlaced, so it is deinterlaced") }
            // AVPlayer turns the picture itself; a Chromecast shows it sideways.
            if v.rotation != 0 && profile.family == .chromecast { reasons.append("rotated \(v.rotation)°") }
            if let burn { reasons.append("drawing in \(burn.label) subtitles") }

            if reasons.isEmpty {
                videoAction = .copy
                notes.append("Video: \(v.summary), sent untouched")
            } else {
                let height = min(v.height > 0 ? v.height : 1080, heightLimit)
                let kbps = settings.videoBitrateMbps * 1000 * (height > 1080 ? 2 : 1)
                videoAction = .transcode(maxHeight: height, bitrateKbps: kbps, hardware: settings.hardware)
                let engine = settings.hardware ? "on the GPU" : "in software"
                notes.append("Video: \(v.summary) converted to H.264 \(height)p \(engine) (\(reasons.joined(separator: "; ")))")
                if v.needsDolbyVisionTag { notes.append("Dolby Vision profile 5 can't be converted accurately, so colours may look wrong") }
            }
        }

        // Audio
        let audio = info.audio.first { $0.index == audioIndex } ?? info.audio.first(where: \.isDefault) ?? info.audio.first
        var audioAction: StreamPlan.AudioAction = .none
        if let a = audio {
            var reasons: [String] = []
            if !profile.audioCodecs.contains(a.codec) { reasons.append("\(a.codecName) isn't supported") }
            if a.channels > profile.maxCopyChannels { reasons.append("\(Codecs.channelName(a.channels)) needs mixing down") }
            if options.volumeBoost { reasons.append("volume booster") }
            if options.downmix && a.channels > 2 { reasons.append("stereo downmix") }

            if reasons.isEmpty {
                audioAction = .copy
                notes.append("Audio: \(a.label), sent untouched")
            } else {
                let stereoCodec: StreamPlan.AudioCodec = profile.family == .chromecast && settings.castAudio == .opus ? .opus : .aac
                let stereoRate = stereoCodec == .opus ? 160 : 192
                let choice: (StreamPlan.AudioCodec, Int, Int)
                if options.downmix || a.channels <= 2 {
                    choice = (stereoCodec, min(max(a.channels, 1), 2), stereoRate)
                } else if profile.family == .apple {
                    switch settings.appleSurround {
                    case .eac3: choice = (.eac3, min(a.channels, 6), 640)
                    case .flac: choice = (.flac, min(a.channels, 8), 0)
                    case .stereo: choice = (stereoCodec, 2, stereoRate)
                    }
                } else if settings.castPassthrough {
                    choice = (.eac3, min(a.channels, 6), 640)
                } else {
                    choice = (stereoCodec, 2, stereoRate)
                }
                audioAction = .encode(choice.0, channels: choice.1, bitrateKbps: choice.2)
                let target = "\(Codecs.audioName(choice.0.rawValue)) \(Codecs.channelName(choice.1))"
                notes.append("Audio: \(a.label) converted to \(target) (\(reasons.joined(separator: "; ")))")
            }
            if options.avSyncOffset != 0 {
                notes.append(String(format: "Audio delay: %+.2f s", options.avSyncOffset))
            }
        }

        if let text {
            notes.append(text.isPicture ? "Subtitles: \(text.label), converted to text with OCR" : "Subtitles: \(text.label), sent as a text track")
        }
        if let burn { notes.append("Subtitles: \(burn.label), drawn into the picture") }

        // Container: direct play only when the device can read the original file end to end.
        let ext = file.pathExtension.lowercased()
        var direct = !settings.forceTranscode && profile.directExtensions.contains(ext)
            && burn == nil && options.avSyncOffset == 0 && !(profile.audioOnly && info.video != nil)
        if case .transcode = videoAction { direct = false }
        if case .encode = audioAction { direct = false }
        if let a = audio, a.index != info.audio.first?.index { direct = false } // devices always play the first track
        if profile.family == .apple && text != nil { direct = false }          // AVPlayer can't side-load subtitles
        if profile.family == .apple, let v = info.video, v.codec == "hevc", !["hvc1", "dvh1"].contains(v.codecTag) { direct = false }
        if info.video?.isInterlaced == true { direct = false }

        let plan = StreamPlan(mode: direct ? .direct : .hls, video: info.video, videoAction: videoAction,
                              audio: audio, audioAction: audioAction, textSubtitle: text, burnSubtitle: burn,
                              options: options, notes: notes, sourceBitRate: info.bitRate, sourceStartTime: info.startTime)
        let headline: String
        if direct {
            headline = "Direct play: the device reads the original file"
        } else if plan.isRemuxOnly {
            headline = "Repackaged for streaming, no quality loss"
        } else {
            headline = "Converting while playing"
        }
        var result = plan
        result.notes.insert(headline, at: 0)
        return result
    }
}
