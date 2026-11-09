import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            VideoSettings().tabItem { Label("Video", systemImage: "film") }.tag("video")
            AudioSettings().tabItem { Label("Audio", systemImage: "speaker.wave.3") }.tag("audio")
            SubtitleSettings().tabItem { Label("Subtitles", systemImage: "captions.bubble") }.tag("subtitles")
        }
        .frame(width: 520)
        // The Licence tab is gone; a remembered selection of it would show an empty pane.
        .onAppear { if tab == "licence" { tab = "general" } }
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.resumePlayback) private var resume = true
    @AppStorage(Prefs.autoPlayNext) private var autoNext = true
    @AppStorage(Prefs.ffmpegDirectory) private var ffmpegDir = ""
    @AppStorage(Prefs.autoUpdateCheck) private var autoUpdate = true
    @AppStorage(Prefs.onlineDetails) private var onlineDetails = true
    @AppStorage(Prefs.omdbKey) private var omdbKey = ""
    @AppStorage(Prefs.titleCard) private var titleCard = true
    @ObservedObject private var updater = Updater.shared
    @State private var version: String?

    var body: some View {
        Form {
            Section {
                Toggle("Resume videos where you left off", isOn: $resume)
                Toggle("Play the next video in the playlist automatically", isOn: $autoNext)
            }
            Section {
                Toggle("Look up posters and details online", isOn: $onlineDetails)
                TextField("OMDb API key (optional)", text: $omdbKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!onlineDetails)
                Link("Get a free OMDb key", destination: OMDbClient.keyPage)
                Toggle("Show the poster and details for 5 seconds when a video starts", isOn: $titleCard)
            } header: {
                Text("Film and show details")
            } footer: {
                Text("Posters, plot, director, cast, age ratings and review scores come from Wikipedia, Wikidata and TVmaze; only the title read from the file name is sent. "
                     + (OMDbClient.builtInKey.isEmpty
                        ? "A free OMDb key adds IMDb, Rotten Tomatoes and Metacritic ratings for films Wikidata hasn't scored, and for episodes. "
                        : "Driftcast includes an OMDb key for ratings Wikidata lacks; add your own only if you want a higher daily limit. ")
                     + "The poster card is placed at the start of the stream for this Mac and AirPlay and shown on a Chromecast's own screen; turn it off if a TV has trouble starting a video.")
            }
            if Updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $autoUpdate)
                    LabeledContent {
                        Button("Check Now") { Updater.shared.checkNow() }
                            .disabled(updater.status == .checking)
                    } label: {
                        Text(Updater.lastCheckText(updater.lastCheck))
                        Text(updateWords)
                    }
                }
            }
            Section("ffmpeg") {
                LabeledContent("Using") {
                    Text(FFmpeg.ffmpeg?.deletingLastPathComponent().path ?? "Not found")
                        .foregroundStyle(FFmpeg.ffmpeg == nil ? .red : .secondary)
                        .textSelection(.enabled)
                }
                if let version { Text(version).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Choose Folder…") { choose() }
                    if !ffmpegDir.isEmpty { Button("Use Default") { ffmpegDir = ""; refresh() } }
                }
                Text("Driftcast uses its built-in copy of ffmpeg to read and convert video. Leave this empty unless you want to use a different ffmpeg; then pick a folder that contains ffmpeg and ffprobe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: Updater.isAvailable ? 690 : 580)
        .task { refresh() }
    }

    private var updateWords: String {
        switch updater.status {
        case .unknown: "Driftcast \(AppVersion.installed)"
        case .checking: "Checking for updates…"
        case .upToDate: "Driftcast \(AppVersion.installed) is the newest version"
        case .available(let release): "Version \(release.version) is available"
        case .failed: "The last check couldn't reach GitHub"
        }
    }

    private func refresh() {
        Task { version = await FFmpeg.versionString() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder containing ffmpeg and ffprobe."
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegDir = url.path
            refresh()
        }
    }
}

private struct VideoSettings: View {
    @AppStorage(Prefs.hardwareEncoding) private var hardware = true
    @AppStorage(Prefs.videoBitrate) private var bitrate = 12
    @AppStorage(Prefs.maxResolution) private var maxResolution = 2160
    @AppStorage(Prefs.forceTranscode) private var force = false
    @AppStorage(Prefs.castHEVC) private var castHEVC = EncoderSettings.CastHEVC.auto.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Convert on the GPU (VideoToolbox)", isOn: $hardware)
                Picker("Conversion quality", selection: $bitrate) {
                    Text("Low (6 Mbps)").tag(6)
                    Text("Medium (12 Mbps)").tag(12)
                    Text("High (20 Mbps)").tag(20)
                    Text("Very high (30 Mbps)").tag(30)
                }
                Picker("Maximum resolution", selection: $maxResolution) {
                    Text("4K").tag(2160)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                }
                Toggle("Always convert video", isOn: $force)
            } footer: {
                Text("Video the device can play is passed through untouched. Only incompatible video is converted to H.264, decoded, scaled and encoded on the GPU wherever the Mac can. 4K streams use twice the bit rate.")
            }
            Section {
                Picker("HEVC on Chromecast", selection: $castHEVC) {
                    Text("Automatic").tag(EncoderSettings.CastHEVC.auto.rawValue)
                    Text("Always").tag(EncoderSettings.CastHEVC.on.rawValue)
                    Text("Never").tag(EncoderSettings.CastHEVC.off.rawValue)
                }
            } footer: {
                Text("Automatic assumes Chromecast Ultra, Chromecast with Google TV and TVs with Chromecast built in can play HEVC and HDR.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

private struct AudioSettings: View {
    @AppStorage(Prefs.appleSurround) private var appleSurround = EncoderSettings.AppleSurround.eac3.rawValue
    @AppStorage(Prefs.castAudioCodec) private var castAudio = EncoderSettings.CastAudio.aac.rawValue
    @AppStorage(Prefs.castPassthrough) private var passthrough = false
    @AppStorage(Prefs.audioLanguage) private var language = "en"

    var body: some View {
        Form {
            Section {
                LanguagePicker(title: "Preferred audio language", selection: $language)
            }
            Section {
                Picker("Surround sound conversion", selection: $appleSurround) {
                    Text("Dolby Digital Plus 5.1").tag(EncoderSettings.AppleSurround.eac3.rawValue)
                    Text("Lossless FLAC (tvOS 14 or later)").tag(EncoderSettings.AppleSurround.flac.rawValue)
                    Text("Stereo AAC").tag(EncoderSettings.AppleSurround.stereo.rawValue)
                }
            } header: {
                Text("Apple TV and AirPlay")
            } footer: {
                Text("Dolby Digital, Dolby Digital Plus (including Atmos) and FLAC are passed through. DTS and TrueHD are converted using this setting.")
            }
            Section {
                Picker("Stereo codec", selection: $castAudio) {
                    Text("AAC").tag(EncoderSettings.CastAudio.aac.rawValue)
                    Text("Opus").tag(EncoderSettings.CastAudio.opus.rawValue)
                }
                Toggle("Pass through Dolby surround", isOn: $passthrough)
            } header: {
                Text("Chromecast")
            } footer: {
                Text("Turn on pass-through only if your Chromecast is connected to a receiver or TV that decodes Dolby Digital.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
    }
}

private struct SubtitleSettings: View {
    @AppStorage(Prefs.subtitleLanguage) private var language = "en"
    @AppStorage(Prefs.subtitleAuto) private var auto = SubtitleAuto.never.rawValue
    @AppStorage(Prefs.autoSearchSubtitles) private var autoSearch = false
    @AppStorage(Prefs.hideSubtitleNotices) private var hideNotices = false
    @AppStorage(Prefs.subtitleScale) private var scale = 1.0
    @AppStorage(Prefs.openSubtitlesKey) private var apiKey = ""
    @AppStorage(Prefs.ocrSubtitles) private var ocr = true
    @State private var keyHelp = false

    private var hasKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !OpenSubtitlesClient.builtInKey.isEmpty
    }

    var body: some View {
        Form {
            Section {
                LanguagePicker(title: "Closed caption language", selection: $language)
                Toggle("Always turn on closed captions", isOn: Binding(
                    get: { auto == SubtitleAuto.always.rawValue },
                    set: { auto = $0 ? SubtitleAuto.always.rawValue : SubtitleAuto.never.rawValue }))
                Toggle("Turn them on when the audio is in another language", isOn: Binding(
                    get: { auto == SubtitleAuto.foreign.rawValue },
                    set: { auto = $0 ? SubtitleAuto.foreign.rawValue : SubtitleAuto.never.rawValue }))
                    .disabled(auto == SubtitleAuto.always.rawValue)
                Toggle("Search OpenSubtitles when the video has none in this language", isOn: $autoSearch)
                    .disabled(auto == SubtitleAuto.never.rawValue || !hasKey)
            } footer: {
                Text(hasKey
                     ? "Nothing comes on by itself unless one of these is ticked. When the video has no captions in this language, OpenSubtitles can be asked for them as the video starts; that takes a few seconds and the best match is kept with the video."
                     : "Nothing comes on by itself unless one of these is ticked. Asking OpenSubtitles for missing ones needs the API key below.")
            }
            Section {
                Toggle("Convert picture subtitles (PGS, VobSub) to text", isOn: $ocr)
                LabeledContent("Chromecast text size") {
                    HStack {
                        Slider(value: $scale, in: 0.6...2.0, step: 0.1)
                        Text("\(Int(scale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Picture subtitles are read with text recognition the first time they're used, which takes a minute for a film; with this off they are drawn into the video instead.")
            }
            Section {
                Toggle("I don't care about subtitles", isOn: $hideNotices)
            } footer: {
                Text("Hides the closed-caption notices: the bar under the video window and the Closed Captions section of the details panel. The Subtitles menu and the playback bar's button still work.")
            }
            Section {
                TextField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button("How to get a free key…") { keyHelp = true }
                    .popover(isPresented: $keyHelp, arrowEdge: .bottom) { OpenSubtitlesKeyHelp() }
            } header: {
                Text("OpenSubtitles")
            } footer: {
                Text(OpenSubtitlesClient.builtInKey.isEmpty
                     ? "Searching for subtitles online needs a free key from OpenSubtitles. Subtitles that are already in the video, or in a file next to it, work without one."
                     : "Driftcast includes a key, so this can stay empty. Add your own only if you have an OpenSubtitles account with a higher download limit.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 660)   // four sections and their footers; the window sizes to this
    }
}

private struct LanguagePicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Lang.common, id: \.self) { code in
                Text(Lang.name(code) ?? code).tag(code)
            }
            if !Lang.common.contains(selection), !selection.isEmpty {
                Text(Lang.name(selection) ?? selection).tag(selection)
            }
        }
    }
}
