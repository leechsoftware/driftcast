import AppKit
import MediaPlayer
import SwiftUI

enum PlaybackOutput: Hashable {
    case local
    case cast(CastDeviceInfo)
}

/// The values that change several times a second, kept apart so that only the timeline
/// redraws for them and not every view that looks at the player.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    /// File-time range the device can seek within without restarting the converter.
    @Published var seekableRange: ClosedRange<Double> = 0...0
}

/// The app's single source of truth for what's playing and where.
///
/// Positions shown in the UI are always file positions. A converted (HLS) stream may start
/// part-way into the file after a seek past what's been converted, so device time is offset
/// by `StreamSession.offset`.
@MainActor
final class PlaybackController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case buffering
        case playing
        case paused
        case failed(String)
    }

    let library: Library
    let localTarget = AVPlayerTarget()

    let clock = PlaybackClock()
    var position: Double {
        get { clock.position }
        set { clock.position = newValue }
    }
    private var seekableRange: ClosedRange<Double> {
        get { clock.seekableRange }
        set { if clock.seekableRange != newValue { clock.seekableRange = newValue } }
    }

    @Published private(set) var output: PlaybackOutput = .local
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var nowPlaying: MediaItem?
    @Published private(set) var info: MediaInfo?
    @Published private(set) var plan: StreamPlan?
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Double = 1
    @Published private(set) var audioIndex: Int?
    @Published private(set) var subtitleChoices: [SubtitleChoice] = []
    @Published private(set) var subtitle: SubtitleChoice?
    @Published private(set) var options = PlaybackOptions()
    @Published private(set) var isAirPlaying = false
    /// Set when an AirPlay TV has connected but never asks this Mac for the video.
    @Published private(set) var airPlayProblem: String?
    /// The poster or a frame of what's playing, behind the watermark while casting.
    @Published private(set) var artwork: NSImage?
    /// Incremented when local playback starts so the UI opens the video window.
    @Published private(set) var videoWindowRequest = 0
    var isScrubbing = false
    /// Set by the Subtitles menu or the bar's subtitle button to open the online search sheet.
    @Published var showSubtitleSearch = false
    /// The video whose Media Info sheet should be open (File menu and right-click menu).
    @Published var infoItem: MediaItem?
    @Published private(set) var queue: [MediaItem] = []
    @Published private(set) var queueIndex = 0

    private var castTarget: CastTarget?
    private var session: StreamSession?
    private var loadToken = 0
    private var lastProgressSave = Date.distantPast
    private var lastVolumeChange = Date.distantPast
    private var housekeeping: Timer?
    /// When the AirPlay device should have started fetching the current stream.
    private var airPlayExpectedSince: Date?
    private var syncWork: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var settingsWork: Task<Void, Never>?
    private var plannedSettings: EncoderSettings?
    /// The subtitle the next video starts with when the details panel picked one before pressing Play.
    private var startSubtitle: SubtitleStart = .automatic
    /// Videos OpenSubtitles has already been asked about in this run (found or not).
    private var autoSearched: Set<URL> = []

    /// How a video's first subtitle is chosen: the language rules in Settings, none, or a track
    /// the user picked before playback started.
    enum SubtitleStart: Sendable {
        case automatic
        case off
        case use(SubtitleChoice)
    }

    init(library: Library) {
        self.library = library
        localTarget.onStatus = { [weak self] s in self?.handle(s, from: .local) }
        localTarget.onExternalChange = { [weak self] active in
            self?.isAirPlaying = active
            self?.airPlayExpectedSince = active ? Date() : nil
            self?.airPlayProblem = nil
        }
        setupRemoteCommands()
        housekeeping = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    /// Conversion settings changed in Settings: re-plan the current stream (debounced, since
    /// SwiftUI writes each keystroke of a text field).
    private func settingsChanged() {
        guard let planned = plannedSettings, EncoderSettings.current() != planned else { return }
        settingsWork?.cancel()
        settingsWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.nowPlaying != nil else { return }
            self.reload()
        }
    }

    /// Keeps the Mac awake while a stream is being served to a device.
    private func setStreaming(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Streaming video to a device")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private var target: PlaybackTarget {
        if case .cast = output, let c = castTarget { return c }
        return localTarget
    }

    var isPlaying: Bool { phase == .playing || phase == .buffering }
    var isBusy: Bool { if case .preparing = phase { return true }; return phase == .buffering }

    var outputName: String {
        switch output {
        case .local: return isAirPlaying ? "AirPlay" : "This Mac"
        case .cast(let d): return d.name
        }
    }

    /// The device a video is being sent to, when it isn't playing on this Mac.
    var remoteDeviceName: String? {
        guard nowPlaying != nil else { return nil }
        switch output {
        case .cast(let d): return d.name
        case .local: return isAirPlaying ? "AirPlay TV" : nil
        }
    }

    var outputSymbol: String {
        switch output {
        case .local: return isAirPlaying ? "airplayvideo" : "laptopcomputer"
        case .cast(let d): return d.symbol
        }
    }

    var statusText: String {
        switch phase {
        case .idle: return nowPlaying == nil ? "Not playing" : "Stopped"
        case .preparing(let s): return s
        case .buffering: return airPlayProblem == nil ? "Buffering on \(outputName)…" : "The TV can't reach this Mac"
        case .playing: return airPlayProblem == nil ? "Playing on \(outputName)" : "The TV can't reach this Mac"
        case .paused: return "Paused on \(outputName)"
        case .failed(let s): return s
        }
    }

    // MARK: Output selection

    func selectOutput(_ newOutput: PlaybackOutput) {
        guard newOutput != output else { return }
        let resumeItem = nowPlaying
        let resumeAt = position
        loadToken += 1
        target.stop()
        teardownSession()
        if case .cast = output {
            castTarget?.disconnect()
            castTarget = nil
        }
        output = newOutput
        if case .cast(let device) = newOutput {
            let t = CastTarget(device: device)
            t.onStatus = { [weak self] s in self?.handle(s, from: newOutput) }
            castTarget = t
        }
        if let item = resumeItem {
            start(item, at: resumeAt, fresh: false)
        } else {
            phase = .idle
        }
    }

    /// Ends the Chromecast session (closes the player on the TV) and returns to this Mac.
    func disconnectCast() {
        stop()
        selectOutput(.local)
    }

    // MARK: Starting playback

    func play(_ item: MediaItem, queue items: [MediaItem], fromBeginning: Bool = false, subtitle: SubtitleStart = .automatic) {
        queue = items
        queueIndex = items.firstIndex { $0.id == item.id } ?? 0
        if fromBeginning { library.clearProgress(item.url) }
        startSubtitle = subtitle
        infoItem = item
        start(item, at: fromBeginning ? 0 : resumePoint(for: item), fresh: true)
    }

    private func resumePoint(for item: MediaItem) -> Double {
        guard Prefs.bool(Prefs.resumePlayback) else { return 0 }
        return library.resumePosition(for: item.url) ?? 0
    }

    private func start(_ item: MediaItem, at time: Double, fresh: Bool) {
        saveProgress(force: true)
        // The details panel follows playback unless another video was picked out in the list.
        if infoItem == nil || infoItem?.id == nowPlaying?.id { infoItem = item }
        loadToken += 1
        let token = loadToken
        Task { await prepareAndLoad(item, at: time, fresh: fresh, token: token) }
    }

    private func prepareAndLoad(_ item: MediaItem, at time: Double, fresh: Bool, token: Int) async {
        teardownSession()
        nowPlaying = item
        position = time
        seekableRange = time...time
        phase = .preparing("Opening \(item.title)…")
        var created: StreamSession?

        func stale() -> Bool {
            guard token != loadToken else { return false }
            if let created, created !== session {
                MediaServer.shared.unregister(created)
                created.stop()
            }
            return true
        }

        do {
            guard FFmpeg.isAvailable else { throw FFmpegError.notFound }
            guard item.exists else { throw FFmpegError.failed("\(item.url.lastPathComponent) couldn't be found. It may have been moved or deleted.") }
            let info = try await MediaProbe.shared.probe(item.url)
            if stale() { return }
            self.info = info
            duration = info.duration
            if fresh {
                subtitleChoices = SubtitleChoice.available(for: item, info: info)
                audioIndex = Self.preferredAudio(info)?.index
                let audio = info.audio.first { $0.index == audioIndex }
                let automatic = Self.preferredSubtitle(subtitleChoices, audio: audio)
                var searchOnline = false
                switch startSubtitle {
                case .automatic:
                    subtitle = automatic
                    // A forced track may have come on; the search still looks for a full one.
                    searchOnline = !autoSearched.contains(item.url)
                        && Self.shouldSearchOnline(choices: subtitleChoices, audio: audio)
                case .off: subtitle = nil
                case .use(let choice): subtitle = subtitleChoices.contains(choice) ? choice : automatic
                }
                startSubtitle = .automatic   // one video only; the next starts by the rules again
                if searchOnline {
                    // Once per video per run, so a search that finds nothing isn't repeated on every replay.
                    autoSearched.insert(item.url)
                    let language = Prefs.string(Prefs.subtitleLanguage)
                    phase = .preparing("Looking for \(Lang.name(language) ?? language) subtitles…")
                    let found = await Self.findSubtitleOnline(for: item, language: language, within: 12)
                    if stale() { return }
                    if let found {
                        library.attachSubtitle(found, toFile: item.url)
                        nowPlaying?.extraSubtitles.append(found)
                        if infoItem?.url == item.url { infoItem?.extraSubtitles.append(found) }
                        let choice = SubtitleChoice.external(found)
                        if !subtitleChoices.contains(choice) { subtitleChoices.append(choice) }
                        subtitle = choice
                    }
                }
            }

            let settings = EncoderSettings.current()
            plannedSettings = settings
            let profile: DeviceProfile
            switch output {
            case .local: profile = .apple()
            case .cast(let d): profile = .chromecast(model: d.model, capabilities: d.capabilities, settings: settings)
            }
            // Picture subtitles become text through OCR when possible (cached after the first run).
            var cues: [SubtitleCue]?
            if let sub = subtitle, sub.isPicture, Prefs.bool(Prefs.ocrSubtitles), PictureSubtitleOCR.supports(sub, media: item.url) {
                phase = .preparing("Reading subtitles with OCR… (first time only)")
                cues = try? await PictureSubtitleOCR.shared.cues(for: sub, media: item.url, info: info,
                                                                  preferredLanguage: Prefs.string(Prefs.subtitleLanguage))
                if stale() { return }
            }
            var plan = StreamPlanner.plan(info: info, file: item.url, profile: profile, settings: settings,
                                          audioIndex: audioIndex, subtitle: subtitle, subtitleIsText: cues != nil,
                                          options: options)
            // The title card lives inside an HLS stream, so a file that could be played as it
            // is gets repackaged (copied, not converted) when the card is on.
            let cardWanted = Prefs.bool(Prefs.titleCard) && info.video != nil
            let isLocal = output == .local
            if cardWanted, isLocal, plan.mode == .direct {
                plan.mode = .hls
                if !plan.notes.isEmpty { plan.notes[0] = "Repackaged for streaming, no quality loss" }
            }
            self.plan = plan

            if case .cast(let d) = output { phase = .preparing("Connecting to \(d.name)…") }
            let host = try await target.prepare()
            if stale() { return }

            if let text = plan.textSubtitle, cues == nil {
                phase = .preparing("Loading subtitles…")
                cues = try? await SubtitleLoader.shared.cues(for: text, media: item.url)
                if stale() { return }
            }

            var grid: SegmentGrid?
            if plan.mode == .hls {
                if let v = info.video, plan.isCopyingVideo {
                    phase = .preparing("Indexing keyframes…")
                    let keyframes = try await KeyframeIndex.shared.keyframes(for: item.url, streamIndex: v.index)
                    if stale() { return }
                    grid = .keyframes(keyframes.map { $0 - info.startTime }, duration: info.duration)
                } else {
                    grid = .fixed(duration: info.duration)
                }
            }
            let session = StreamSession(plan: plan, source: item.url, duration: info.duration, grid: grid, cues: cues)
            created = session
            MediaServer.shared.register(session)
            setStreaming(true)

            // Film details and artwork for the card and the Chromecast's screen. They are cached
            // in most cases; a video played the moment it was added waits a few seconds for the
            // lookup its playlist row started, rather than showing a frame instead of the poster.
            var details = await MetadataLookup.shared.cached(for: item.url)
            if details == nil, MetadataLookup.isEnabled, cardWanted || !isLocal {
                phase = .preparing("Looking up details…")
                details = await MetadataLookup.shared.details(for: item.url, within: 6)
                if stale() { return }
            }
            var artwork: Data?
            if let url = details?.posterURL { artwork = await MetadataLookup.shared.artwork(url, within: 4) }
            if artwork == nil { artwork = await Thumbnailer.shared.poster(for: item.url, duration: info.duration) }
            if stale() { return }
            self.artwork = artwork.flatMap { NSImage(data: $0) }

            if cardWanted, isLocal, let grid, let size = plan.outputVideoSize, let v = info.video,
               !(v.isHDR && !plan.isTranscodingVideo),   // an SDR card before HDR would make the TV switch modes twice
               let card = TitleCard.render(poster: artwork, title: item.title, details: details, size: size) {
                session.intro = StreamSession.Intro(card: card, size: size, atSegment: grid.index(at: time), hardware: settings.hardware)
            }

            if plan.mode == .hls {
                phase = .preparing(plan.isTranscodingVideo ? "Starting conversion…" : "Preparing stream…")
                try await session.start(at: time)
                if stale() { return }
            }
            self.session = session

            let path: String
            if plan.mode == .direct {
                path = session.directPath
            } else if isLocal {
                // AVPlayer takes the subtitles as an HLS rendition in the master playlist.
                path = cues != nil ? session.masterPath : session.streamPath
            } else {
                // The Cast player needs the codec attributes; subtitles go as a separate track.
                path = session.castPath
            }
            let url = await MediaServer.shared.url(path: path, host: host)
            var subtitleURL: URL?
            if cues != nil {
                subtitleURL = isLocal ? url : await MediaServer.shared.url(path: session.subtitlePath, host: host)
            }
            // The Chromecast's own screen: the film's poster and name.
            var posterURL: URL?
            if !isLocal, let artwork {
                session.poster = artwork
                posterURL = await MediaServer.shared.url(path: session.posterPath, host: host)
            }
            if stale() { return }
            let request = LoadRequest(
                url: url,
                contentType: plan.mode == .direct ? MediaServer.contentType(forExtension: item.url.pathExtension) : "application/x-mpegURL",
                isHLS: plan.mode == .hls,
                title: item.title,
                startTime: session.deviceStartTime(forFileTime: time),
                duration: info.duration,
                subtitleURL: subtitleURL,
                subtitleName: session.subtitleName,
                subtitleLanguage: session.subtitleLanguage,
                posterURL: posterURL,
                details: details,
                posterHoldSeconds: cardWanted && !isLocal ? TitleCard.seconds : 0)

            phase = .preparing("Starting playback on \(outputName)…")
            if isLocal && isAirPlaying { airPlayExpectedSince = Date(); airPlayProblem = nil }
            try await target.load(request)
            if stale() { return }
            phase = .buffering
            // Also while casting: the window then carries the "connected to" watermark.
            videoWindowRequest += 1
            updateNowPlayingInfo()
        } catch {
            if token != loadToken || error is CancellationError { return }
            if let created { MediaServer.shared.unregister(created); created.stop() }
            if session === created { session = nil }
            phase = .failed(error.localizedDescription)
        }
    }

    private func teardownSession() {
        if let s = session {
            MediaServer.shared.unregister(s)
            s.stop()
        }
        session = nil
        setStreaming(false)
    }

    // MARK: Status from the device

    private func handle(_ s: TargetStatus, from source: PlaybackOutput) {
        guard source == output else { return }
        if let v = s.volume, v != volume, Date().timeIntervalSince(lastVolumeChange) > 1.5 { volume = v }
        if s.reconnected {
            if case .preparing = phase { return }
            if let item = nowPlaying { start(item, at: position, fresh: false) }
            return
        }
        guard let session, nowPlaying != nil else { return }
        if case .preparing = phase { return }
        if let e = s.error {
            phase = .failed(e)
            return
        }
        if s.finished {
            itemFinished()
            return
        }
        _ = session
        if let t = s.time, !isScrubbing {
            position = min(max(0, session.fileTime(forDeviceTime: t)), max(duration, 0))
        }
        // The device reports twice a second; only tell the views when something changed.
        let reported: Phase?
        switch s.state {
        case .playing: reported = .playing
        case .paused: reported = .paused
        case .buffering: reported = .buffering
        case .idle: reported = nil
        }
        if let reported, reported != phase { phase = reported }
        saveProgress(force: false)
    }

    /// With AirPlay the TV downloads the video from this Mac itself. If it has connected but
    /// nothing has asked for the stream, something between them is blocking it (a firewall, a
    /// VPN, or different networks), and the TV just sits on its AirPlay screen.
    private func checkAirPlayReachability() {
        guard output == .local, isAirPlaying, isPlaying, let since = airPlayExpectedSince else {
            if airPlayProblem != nil { airPlayProblem = nil }
            return
        }
        if let last = MediaServer.shared.lastDeviceRequest, last >= since {
            if airPlayProblem != nil { airPlayProblem = nil }
        } else if airPlayProblem == nil, Date().timeIntervalSince(since) > 15 {
            airPlayProblem = "The TV connected but can't load the video from this Mac. Check that both are on the same Wi-Fi network, turn off any VPN on this Mac, and allow Driftcast under System Settings > Network > Firewall > Options."
        }
    }

    private func tick() {
        checkAirPlayReachability()
        guard let session else { return }
        seekableRange = session.producedRange ?? 0...0
        if isPlaying { updateNowPlayingInfo() }
    }

    private func itemFinished() {
        guard let item = nowPlaying else { return }
        position = duration
        library.markWatched(item.url)
        lastProgressSave = Date()
        if Prefs.bool(Prefs.autoPlayNext), queueIndex + 1 < queue.count {
            queueIndex += 1
            let next = queue[queueIndex]
            start(next, at: resumePoint(for: next), fresh: true)
        } else {
            finishStop()
        }
    }

    private func saveProgress(force: Bool) {
        guard let item = nowPlaying, duration > 0 else { return }
        guard force || Date().timeIntervalSince(lastProgressSave) > 5 else { return }
        switch phase {
        case .playing, .paused, .buffering: break
        default: if !force { return }
        }
        lastProgressSave = Date()
        library.updateProgress(for: item.url, position: position, duration: duration)
    }

    // MARK: Transport

    func togglePause() {
        switch phase {
        case .playing, .buffering:
            target.pause()
            phase = .paused
        case .paused:
            target.play()
            phase = .playing
        case .idle, .failed:
            if let item = nowPlaying {
                start(item, at: position, fresh: false)
            } else if let playlist = library.selectedPlaylist, let first = playlist.items.first {
                play(first, queue: playlist.items)
            }
        case .preparing:
            break
        }
        updateNowPlayingInfo()
    }

    func stop() {
        saveProgress(force: true)
        finishStop()
    }

    private func finishStop() {
        loadToken += 1
        target.stop()
        teardownSession()
        nowPlaying = nil
        info = nil
        plan = nil
        artwork = nil
        phase = .idle
        position = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func seek(to time: Double) {
        guard let item = nowPlaying else { return }
        let t = min(max(0, time), max(0, duration - 1))
        position = t
        guard session != nil else {
            start(item, at: t, fresh: false)
            return
        }
        // The device has the whole playlist; the server starts converting wherever it reads.
        target.seek(to: session?.deviceTime(forFileTime: t) ?? t)
        updateNowPlayingInfo()
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    func next() {
        guard queueIndex + 1 < queue.count else { return }
        queueIndex += 1
        let item = queue[queueIndex]
        start(item, at: resumePoint(for: item), fresh: true)
    }

    func previous() {
        if position > 8 || queueIndex == 0 {
            seek(to: 0)
            return
        }
        queueIndex -= 1
        start(queue[queueIndex], at: 0, fresh: true)
    }

    var hasNext: Bool { queueIndex + 1 < queue.count }
    var hasPrevious: Bool { nowPlaying != nil }

    func setVolume(_ level: Double) {
        volume = min(1, max(0, level))
        lastVolumeChange = Date()
        target.setVolume(volume)
    }

    func nudgeVolume(_ delta: Double) { setVolume(volume + delta) }

    // MARK: Tracks and audio options (each restarts the stream at the current position)

    func selectAudio(_ index: Int) {
        guard index != audioIndex else { return }
        audioIndex = index
        reload()
    }

    func selectSubtitle(_ choice: SubtitleChoice?) {
        guard choice != subtitle else { return }
        subtitle = choice
        reload()
    }

    /// Attaches a subtitle file to a video (the playing one unless another is given) and, when
    /// that video is the one playing, turns it on.
    func addSubtitleFile(_ url: URL, to item: MediaItem? = nil) {
        guard let item = item ?? nowPlaying else { return }
        library.attachSubtitle(url, toFile: item.url)
        if infoItem?.url == item.url, infoItem?.extraSubtitles.contains(url) == false { infoItem?.extraSubtitles.append(url) }
        guard nowPlaying?.url == item.url else { return }
        if nowPlaying?.extraSubtitles.contains(url) == false { nowPlaying?.extraSubtitles.append(url) }
        let choice = SubtitleChoice.external(url)
        if !subtitleChoices.contains(choice) { subtitleChoices.append(choice) }
        selectSubtitle(choice)
    }

    /// Asks for a subtitle file for a video (the playing one unless another is given).
    func chooseSubtitleFile(for item: MediaItem? = nil) {
        guard let item = item ?? nowPlaying else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a subtitle file (SRT, ASS, VTT, SUP or IDX)."
        panel.directoryURL = item.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { addSubtitleFile(url, to: item) }
    }

    func setVolumeBoost(_ on: Bool) {
        guard options.volumeBoost != on else { return }
        options.volumeBoost = on
        reload()
    }

    func setDownmix(_ on: Bool) {
        guard options.downmix != on else { return }
        options.downmix = on
        reload()
    }

    /// Debounced so stepping the control several times restarts the stream only once.
    func setAVSync(_ seconds: Double) {
        let v = (seconds * 100).rounded() / 100
        guard v != options.avSyncOffset else { return }
        options.avSyncOffset = v
        syncWork?.cancel()
        syncWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func reload() {
        guard let item = nowPlaying else { return }
        start(item, at: position, fresh: false)
    }

    /// Re-plans the current item (for example after changing conversion settings).
    func restartCurrent() { reload() }

    /// Moves the audio delay by `delta` seconds (menu items), within the same ±2 s range as the slider.
    func nudgeAVSync(_ delta: Double) {
        setAVSync(min(2, max(-2, options.avSyncOffset + delta)))
    }

    /// Opens the playing video's folder in the Finder with the file selected.
    func revealInFinder() {
        guard let item = nowPlaying else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func shutdown() {
        saveProgress(force: true)
        target.stop()
        teardownSession()
        castTarget?.disconnect()
    }

    // MARK: Track defaults

    static func preferredAudio(_ info: MediaInfo) -> MediaInfo.Audio? {
        let pref = Prefs.string(Prefs.audioLanguage)
        if !pref.isEmpty {
            let matching = info.audio.filter { Lang.matches($0.language, pref) }
            if let a = matching.first(where: \.isDefault) ?? matching.first { return a }
        }
        return info.audio.first(where: \.isDefault) ?? info.audio.first
    }

    /// Whether Settings want subtitles on for this audio track: always, or only when the audio
    /// isn't in the preferred subtitle language.
    nonisolated static func subtitlesWanted(audio: MediaInfo.Audio?) -> Bool {
        let pref = Prefs.string(Prefs.subtitleLanguage)
        guard !pref.isEmpty else { return false }
        switch SubtitleAuto.current {
        case .never: return false
        case .foreign: return !Lang.matches(audio?.language, pref)
        case .always: return true
        }
    }

    nonisolated static func preferredSubtitle(_ choices: [SubtitleChoice], audio: MediaInfo.Audio?) -> SubtitleChoice? {
        // Nothing comes on by itself unless Settings ask for captions (the user's wish: "Turn On", not "Turn Off").
        guard subtitlesWanted(audio: audio) else { return nil }
        let pref = Prefs.string(Prefs.subtitleLanguage)
        let full = choices.filter { Lang.matches($0.language, pref) && !$0.isForced }
        if let c = full.first(where: { !$0.isPicture }) ?? full.first { return c }
        // Failing a full track, a forced one (signs and foreign lines) in the language is better than nothing.
        return choices.first { $0.isForced && ($0.language == nil || Lang.matches($0.language, pref)) }
    }

    /// True when the rule wants subtitles, the video has none in the language, and Settings
    /// allow OpenSubtitles to be asked for them (which needs a key).
    nonisolated static func shouldSearchOnline(choices: [SubtitleChoice], audio: MediaInfo.Audio?) -> Bool {
        guard Prefs.bool(Prefs.autoSearchSubtitles), OpenSubtitlesClient.hasKey, subtitlesWanted(audio: audio) else { return false }
        let pref = Prefs.string(Prefs.subtitleLanguage)
        return !choices.contains { Lang.matches($0.language, pref) && !$0.isForced }
    }

    /// Asks OpenSubtitles for the video's subtitles in `language` (the file's fingerprint first,
    /// then its title, with the season and episode for a show) and downloads the best match.
    /// Nil when nothing fits, the key is missing, or it takes longer than `seconds`.
    nonisolated static func findSubtitleOnline(for item: MediaItem, language: String, within seconds: Double) async -> URL? {
        await Deadline.first(within: seconds) {
            guard let client = try? OpenSubtitlesClient.fromSettings() else { return nil }
            let title = await MetadataLookup.shared.title(for: item.url)
            let hash = OpenSubtitlesClient.movieHash(for: item.url)
            do {
                var found = try await client.search(query: title.searchQuery, languages: language, movieHash: hash,
                                                    season: title.season, episode: title.episode)
                if found.isEmpty, hash != nil {
                    found = try await client.search(query: title.searchQuery, languages: language, movieHash: nil,
                                                    season: title.season, episode: title.episode)
                }
                guard let best = found.first else { return nil }
                return try await client.download(best, for: item.url)
            } catch {
                return nil
            }
        }
    }

    // MARK: Media keys and Now Playing

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.phase == .paused { self?.togglePause() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePause() } }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(10) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(-10) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let item = nowPlaying else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        MPNowPlayingInfoCenter.default().playbackState = phase == .paused ? .paused : (isPlaying ? .playing : .stopped)
    }
}
