import Foundation

/// One ffmpeg run writing segments from a grid position onwards. Files are named by job
/// (`j3-00012.m4s`) because ffmpeg may start a little before the requested time when copying
/// video; `landing` says which planned segment its first file really is.
final class TranscodeJob: @unchecked Sendable {
    let number: Int
    let startSegment: Int
    let directory: URL
    let arguments: [String]
    private let process = Process()
    private let lock = NSLock()
    private var errorTail = ""
    private var launched = false
    private var launchFailure: String?
    private var _landing: Int?
    private var paused = false
    private var discardedBelow = 0
    private(set) var tracks: [MP4Boxes.Track] = []
    var lastRequest = Date()
    /// The furthest segment the device has asked this job for (decides how far ahead it may run).
    var lastRequestedSegment: Int

    init(number: Int, startSegment: Int, arguments: [String], directory: URL) {
        self.number = number
        self.startSegment = startSegment
        self.arguments = arguments
        self.directory = directory
        lastRequestedSegment = startSegment
    }

    var prefix: String { "j\(number)-" }
    var initURL: URL { directory.appendingPathComponent(prefix + "init.mp4") }
    var playlistURL: URL { directory.appendingPathComponent(prefix + "playlist.m3u8") }
    func fileURL(forFileIndex i: Int) -> URL { directory.appendingPathComponent(prefix + String(format: "%05d.m4s", i)) }

    func start() throws {
        do {
            try launch()
        } catch {
            // Remembered so that waiting callers see a failure now instead of a timeout later.
            lock.lock(); launchFailure = error.localizedDescription; lock.unlock()
            throw error
        }
    }

    private func launch() throws {
        guard let exe = FFmpeg.ffmpeg else { throw FFmpegError.notFound }
        process.executableURL = exe
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.appendError(String(decoding: data, as: UTF8.self))
        }
        try process.run()
        launched = true
    }

    private func appendError(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        errorTail = String((errorTail + s).suffix(2000))
    }

    var lastError: String {
        lock.lock(); defer { lock.unlock() }
        if let launchFailure { return launchFailure }
        return errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var failedToLaunch: Bool {
        lock.lock(); defer { lock.unlock() }
        return launchFailure != nil
    }

    var isRunning: Bool { launched && process.isRunning }
    var hasExited: Bool { failedToLaunch || (launched && !process.isRunning) }

    func stop() {
        lock.lock()
        let wasPaused = paused
        paused = false
        lock.unlock()
        guard isRunning else { return }
        if wasPaused { process.resume() }   // a stopped process wouldn't act on the signal
        process.terminate()
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// Freezes or thaws ffmpeg (see `StreamSession.pace`).
    func setPaused(_ wanted: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard wanted != paused, launched, process.isRunning else { return }
        paused = wanted
        if wanted { process.suspend() } else { process.resume() }
    }

    /// Deletes the files before `fileIndex`, which the device has already played.
    func discardFiles(below fileIndex: Int) {
        lock.lock()
        let from = discardedBelow
        if fileIndex > from { discardedBelow = fileIndex }
        lock.unlock()
        guard fileIndex > from else { return }
        for i in from..<fileIndex { try? FileManager.default.removeItem(at: fileURL(forFileIndex: i)) }
    }

    private var firstKeptFile: Int {
        lock.lock(); defer { lock.unlock() }
        return discardedBelow
    }

    func waitUntilExit() async {
        while isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func playlistText() -> String? { try? String(contentsOf: playlistURL, encoding: .utf8) }

    /// Segments ffmpeg has finished writing (the playlist lists only complete files).
    func producedCount() -> Int {
        playlistText()?.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }.count ?? 0
    }

    var isComplete: Bool { playlistText()?.contains("#EXT-X-ENDLIST") == true }

    /// Planned index of this job's first file, read from the init segment's edit list.
    func landing(in grid: SegmentGrid) -> Int? {
        lock.lock(); defer { lock.unlock() }
        if let l = _landing { return l }
        guard let data = try? Data(contentsOf: initURL), !data.isEmpty else { return nil }
        let parsed = MP4Boxes.tracks(inInit: data)
        guard !parsed.isEmpty else { return nil }
        tracks = parsed
        let start = parsed.map(\.presentationOffset).max() ?? 0
        let l = grid.nearestIndex(to: start)
        _landing = l
        return l
    }

    /// The file for planned segment `n`, if this job has produced it.
    func fileURL(forSegment n: Int, in grid: SegmentGrid) -> URL? {
        guard let l = landing(in: grid), n >= l, n - l < producedCount(), n - l >= firstKeptFile else { return nil }
        return fileURL(forFileIndex: n - l)
    }

    /// Whether waiting on this job for segment `n` is better than starting another one.
    func willReach(_ n: Int, in grid: SegmentGrid, lookahead: Int) -> Bool {
        guard isRunning || isComplete else { return false }
        let first = landing(in: grid) ?? startSegment
        return n >= first + firstKeptFile && n <= first + producedCount() + lookahead
    }
}

/// Everything the HTTP server needs to answer requests for one playback.
///
/// For converted files the device gets a complete VOD playlist built from `grid` before any
/// segment exists; ffmpeg jobs are started where the device actually reads, and restarted
/// elsewhere when it seeks far away. Segments from different jobs are stitched onto one
/// timeline by `MP4Boxes.rebase`.
final class StreamSession: @unchecked Sendable {
    let id: String
    let plan: StreamPlan
    let source: URL
    let duration: Double
    let grid: SegmentGrid?
    let cues: [SubtitleCue]?
    let subtitleName: String
    let subtitleLanguage: String
    /// JPEG shown by a Chromecast while it loads or pauses (served as poster.jpg).
    var poster: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _poster }
        set { lock.lock(); _poster = newValue; lock.unlock() }
    }
    private var _poster: Data?

    /// A title card stitched in front of the content on this Mac and AirPlay (see `TitleCard`):
    /// a few seconds of poster and title before planned segment `atSegment`, separated from the
    /// film by HLS discontinuities so its own codecs and picture size don't matter.
    struct Intro {
        var card: Data
        var size: CGSize
        var atSegment: Int
        var hardware: Bool
        var duration: Double = TitleCard.seconds
    }

    var intro: Intro? {
        get { lock.lock(); defer { lock.unlock() }; return _intro }
        set { lock.lock(); _intro = newValue; lock.unlock() }
    }
    private var _intro: Intro?
    private enum IntroState { case none, running, ready, failed }
    private var introState = IntroState.none

    private let directory: URL
    private let lock = NSLock()
    private var jobs: [TranscodeJob] = []
    private var jobCounter = 0
    private var canonicalInit: Data?
    private var canonicalTracks: [MP4Boxes.Track] = []
    private var route = StreamPlan.Route.gpu
    private var stopped = false

    static let lookahead = 15
    static let maxJobs = 2
    static let subtitleSegmentLength = 10.0
    /// How far ffmpeg may get ahead of what the device has asked for before it is frozen, and
    /// how much it has to fall back to before it carries on. Without this it runs flat out to
    /// the end of the film: heat and battery for video nobody may watch, and a copy of the
    /// whole film in the temporary folder, which a 60 GB remux won't fit in on many Macs.
    static let maxSecondsAhead = 300.0
    static let resumeSecondsAhead = 240.0
    /// Segments this far behind what the device last asked for are deleted. Going back further
    /// simply converts that part again.
    static let keepSecondsBehind = 300.0

    private static var sharedRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DriftcastStreams", isDirectory: true)
    }

    /// Each running copy of Driftcast keeps its streams in a folder named after its process,
    /// so a second copy starting up can't delete what the first one is serving to a TV.
    static var temporaryRoot: URL {
        sharedRoot.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    /// Removes this copy's leftovers and those of copies that are no longer running.
    static func cleanTemporaryFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: temporaryRoot)
        let entries = (try? fm.contentsOfDirectory(at: sharedRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries {
            if let pid = Int32(entry.lastPathComponent) {
                // kill(pid, 0) only asks whether the process exists.
                if kill(pid, 0) != 0 && errno == ESRCH {
                    // A copy that crashed can leave a frozen ffmpeg behind, working in that folder.
                    let sweep = Process()
                    sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                    sweep.arguments = ["-9", "-f", "DriftcastStreams/\(pid)/"]
                    if (try? sweep.run()) != nil { sweep.waitUntilExit() }
                    try? fm.removeItem(at: entry)
                }
            } else {
                // Folders from older versions, which had no per-process level.
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, Date().timeIntervalSince(modified) > 12 * 3600 { try? fm.removeItem(at: entry) }
            }
        }
    }

    init(plan: StreamPlan, source: URL, duration: Double, grid: SegmentGrid?, cues: [SubtitleCue]?) {
        id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        self.plan = plan
        self.source = source
        self.duration = duration
        self.grid = plan.mode == .hls ? grid : nil
        self.cues = cues
        subtitleName = plan.textSubtitle.map { Lang.name($0.language) ?? $0.label } ?? "Subtitles"
        subtitleLanguage = Lang.normalize(plan.textSubtitle?.language) ?? "und"
        directory = Self.temporaryRoot.appendingPathComponent(id, isDirectory: true)
    }

    var hasSubtitles: Bool { cues != nil }

    // MARK: Lifecycle

    /// Starts converting at `time` and returns once the first segment there exists.
    func start(at time: Double) async throws {
        guard let grid else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let intro { startIntro(intro) }
        let first = grid.index(at: time)
        startPacing(grid)
        while true {
            do {
                try await startJobs(at: first)
                break
            } catch where error is FFmpegError && stepDownRoute() {
                continue
            }
        }
        _ = try await segment(first)
        await finishIntro()
    }

    private func startJobs(at first: Int) async throws {
        let job = spawn(at: first)
        if first == 0 {
            try await waitForInit(of: job)
        } else {
            // The device gets one init for the whole stream: take it from a short run at the start.
            let initJob = makeJob(startSegment: 0, limitSeconds: 0.3)
            try initJob.start()
            try await waitForInit(of: initJob)
            await initJob.waitUntilExit()
        }
    }

    /// Moves a stream that ffmpeg couldn't start to the next route with less on the GPU. False
    /// when there is none left, or once anything has been sent (different encoders can't share
    /// one init segment).
    private func stepDownRoute() -> Bool {
        guard case .transcode(_, _, true) = plan.videoAction else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let next = StreamPlan.Route(rawValue: route.rawValue + 1), canonicalInit == nil, !stopped else { return false }
        route = next
        let failed = jobs
        jobs = []
        failed.forEach { $0.stop() }
        return true
    }

    // MARK: Pacing

    private func startPacing(_ grid: SegmentGrid) {
        Task.detached(priority: .utility) { [weak self] in
            while let wait = self?.pace(grid) {
                try? await Task.sleep(nanoseconds: wait)
            }
        }
    }

    /// Keeps each ffmpeg within reach of the device. Returns how long to wait before looking
    /// again (remuxing can run hundreds of times faster than the film plays, so not long while
    /// one is working), or nil once the session has ended.
    private func pace(_ grid: SegmentGrid) -> UInt64? {
        lock.lock()
        let running = jobs
        let ended = stopped
        lock.unlock()
        if ended { return nil }
        for job in running where job.isRunning {
            guard let landing = job.landing(in: grid) else { continue }
            let produced = job.producedCount()
            guard produced > 0 else { continue }
            let last = min(grid.count - 1, landing + produced - 1)
            let ahead = grid.start(of: last) - grid.start(of: min(grid.count - 1, job.lastRequestedSegment))
            if ahead > Self.maxSecondsAhead { job.setPaused(true) } else if ahead < Self.resumeSecondsAhead { job.setPaused(false) }
        }
        return running.contains { $0.isRunning && !$0.isPaused } ? 50_000_000 : 500_000_000
    }

    // MARK: Title card

    /// Encodes the card in the background while the first segments are produced.
    private func startIntro(_ intro: Intro) {
        lock.lock(); introState = .running; lock.unlock()
        let dir = directory
        let card = dir.appendingPathComponent("intro-card.jpg")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try intro.card.write(to: card)
                guard let exe = FFmpeg.ffmpeg else { throw FFmpegError.notFound }
                _ = try await FFmpeg.run(exe, TitleCard.ffmpegArguments(card: card, size: intro.size, hardware: intro.hardware, outputDirectory: dir))
                self?.setIntroState(.ready)
            } catch {
                self?.setIntroState(.failed)
            }
        }
    }

    private func setIntroState(_ state: IntroState) {
        lock.lock(); introState = state; lock.unlock()
    }

    /// Waits (briefly) for the card; without it the playlist simply starts with the film.
    private func finishIntro() async {
        guard intro != nil else { return }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            lock.lock(); let state = introState; lock.unlock()
            if state == .ready {
                // The clip's real length, as ffmpeg wrote it, so the timeline stays exact.
                if let text = try? String(contentsOf: directory.appendingPathComponent("intro.m3u8"), encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("#EXTINF:") }),
                   let value = Double(line.dropFirst(8).split(separator: ",").first ?? ""), value > 0.5 {
                    lock.lock(); _intro?.duration = value; lock.unlock()
                }
                return
            }
            if state == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        intro = nil
    }

    func introInit() -> Data? { try? Data(contentsOf: directory.appendingPathComponent("intro-init.mp4")) }
    func introSegment() -> Data? { try? Data(contentsOf: directory.appendingPathComponent("intro-0.m4s")) }

    // MARK: Timeline

    /// Where the device's clock is when the file is at `fileTime`: later by the card's length
    /// once the card has played.
    func deviceTime(forFileTime fileTime: Double) -> Double {
        guard let grid, let intro else { return fileTime }
        let at = grid.start(of: intro.atSegment)
        return fileTime < at ? fileTime : fileTime + intro.duration
    }

    /// The file position for a device clock reading; during the card it is where the film resumes.
    func fileTime(forDeviceTime deviceTime: Double) -> Double {
        guard let grid, let intro else { return deviceTime }
        let at = grid.start(of: intro.atSegment)
        if deviceTime < at { return deviceTime }
        if deviceTime < at + intro.duration { return at }
        return deviceTime - intro.duration
    }

    /// Where the device should start for a wanted file position: at the card when there is one.
    func deviceStartTime(forFileTime fileTime: Double) -> Double {
        guard let grid, let intro else { return fileTime }
        return grid.start(of: intro.atSegment)
    }

    var deviceDuration: Double { duration + (intro?.duration ?? 0) }

    private func waitForInit(of job: TranscodeJob) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: job.initURL), !data.isEmpty, data.count > 100 {
                let tracks = MP4Boxes.tracks(inInit: data)
                if !tracks.isEmpty {
                    setCanonical(data, tracks)
                    return
                }
            }
            if job.hasExited && job.producedCount() == 0 {
                let msg = job.lastError
                throw FFmpegError.failed(msg.isEmpty ? "The converter stopped unexpectedly." : "The converter failed: \(msg)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FFmpegError.failed("Timed out waiting for the converter to start.")
    }

    private func setCanonical(_ data: Data, _ tracks: [MP4Boxes.Track]) {
        lock.lock(); defer { lock.unlock() }
        canonicalInit = data
        canonicalTracks = tracks
    }

    private func forget(_ job: TranscodeJob) {
        lock.lock(); defer { lock.unlock() }
        jobs.removeAll { $0 === job }
    }

    func stop() {
        lock.lock()
        let running = jobs
        jobs = []
        stopped = true
        lock.unlock()
        running.forEach { $0.stop() }
        let dir = directory
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Jobs

    private func makeJob(startSegment: Int, limitSeconds: Double?) -> TranscodeJob {
        lock.lock()
        let number = jobCounter
        jobCounter += 1
        let route = self.route
        lock.unlock()
        let start = grid?.start(of: startSegment) ?? 0
        let args = plan.ffmpegArguments(input: source, startTime: start, limitSeconds: limitSeconds,
                                        outputDirectory: directory, filePrefix: "j\(number)-", route: route)
        return TranscodeJob(number: number, startSegment: startSegment, arguments: args, directory: directory)
    }

    @discardableResult
    private func spawn(at segment: Int) -> TranscodeJob {
        lock.lock()
        if jobs.count >= Self.maxJobs, let victim = jobs.min(by: { $0.lastRequest < $1.lastRequest }) {
            victim.stop()
            jobs.removeAll { $0 === victim }
        }
        lock.unlock()
        let job = makeJob(startSegment: segment, limitSeconds: nil)
        try? job.start()
        lock.lock(); jobs.append(job); lock.unlock()
        return job
    }

    private func jobFor(_ n: Int) -> TranscodeJob? {
        guard let grid else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let has = jobs.first(where: { $0.fileURL(forSegment: n, in: grid) != nil }) { return has }
        return jobs.first { $0.willReach(n, in: grid, lookahead: Self.lookahead) }
    }

    /// Segment `n`, rebased onto the stream's timeline. Waits for ffmpeg; starts a job if none
    /// will reach it soon.
    func segment(_ n: Int) async throws -> Data {
        guard let grid, n >= 0, n < grid.count else { throw FFmpegError.failed("No such segment") }
        var job = jobFor(n) ?? spawn(at: n)
        job.lastRequest = Date()
        job.lastRequestedSegment = n
        var restarts = 0
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            if let url = job.fileURL(forSegment: n, in: grid), let data = try? Data(contentsOf: url), !data.isEmpty {
                discardPlayed(job, before: n, in: grid)
                return rebase(data, from: job)
            }
            if job.hasExited {
                if job.producedCount() == 0 {
                    if stepDownRoute() {
                        job = spawn(at: n)
                        job.lastRequestedSegment = n
                        continue
                    }
                    let msg = job.lastError
                    throw FFmpegError.failed(msg.isEmpty ? "The converter stopped unexpectedly." : "The converter failed: \(msg)")
                }
                // Stopped without this segment: it landed after it, reached the end early, or
                // died part-way (the encoder is often lost when the Mac sleeps). Start again at n.
                if job.fileURL(forSegment: n, in: grid) == nil {
                    restarts += 1
                    if restarts > 3 {
                        let msg = job.lastError
                        throw FFmpegError.failed(msg.isEmpty ? "The converter stopped unexpectedly." : "The converter failed: \(msg)")
                    }
                    forget(job)
                    job = spawn(at: n)
                    job.lastRequestedSegment = n
                    continue
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            if let other = jobFor(n) {
                job = other
                job.lastRequestedSegment = max(job.lastRequestedSegment, n)
            }
        }
        throw FFmpegError.failed("Timed out waiting for the converter.")
    }

    /// Frees the disk behind the playhead.
    private func discardPlayed(_ job: TranscodeJob, before n: Int, in grid: SegmentGrid) {
        guard let landing = job.landing(in: grid) else { return }
        let keepFrom = grid.index(at: max(0, grid.start(of: n) - Self.keepSecondsBehind))
        job.discardFiles(below: keepFrom - landing)
    }

    private func rebase(_ data: Data, from job: TranscodeJob) -> Data {
        lock.lock()
        let canon = canonicalTracks
        lock.unlock()
        var offsets: [UInt32: Double] = [:]
        var timescales: [UInt32: UInt32] = [:]
        for track in job.tracks {
            guard let base = canon.first(where: { $0.id == track.id }) else { continue }
            offsets[track.id] = track.presentationOffset - base.presentationOffset
            timescales[track.id] = base.timescale
        }
        return MP4Boxes.rebase(segment: data, offsets: offsets, timescales: timescales)
    }

    func initSegment() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return canonicalInit
    }

    /// Part of the file the most recently used job has converted (for the timeline band).
    var producedRange: ClosedRange<Double>? {
        guard let grid else { return 0...duration }
        lock.lock()
        let job = jobs.max { $0.lastRequest < $1.lastRequest }
        lock.unlock()
        guard let job, let first = job.landing(in: grid) else { return nil }
        let count = job.producedCount()
        let last = min(grid.count, first + count)
        let end = last > first ? grid.start(of: last - 1) + grid.duration(of: last - 1) : grid.start(of: first)
        return grid.start(of: first)...end
    }

    // MARK: URL paths served by MediaServer

    var directPath: String { "/s/\(id)/media.\(source.pathExtension.lowercased())" }
    var streamPath: String { "/s/\(id)/stream.m3u8" }
    var masterPath: String { "/s/\(id)/master.m3u8" }
    var castPath: String { "/s/\(id)/cast.m3u8" }
    var subtitlePath: String { "/s/\(id)/subs.vtt" }
    var posterPath: String { "/s/\(id)/poster.jpg" }

    // MARK: Playlists

    /// Complete VOD media playlist, available before any segment exists. A title card, when
    /// there is one, sits before its segment between discontinuities with its own init.
    func mediaPlaylist() -> String? {
        guard let grid else { return nil }
        let intro = self.intro
        let target = max(grid.targetDuration, Int((intro?.duration ?? 0).rounded(.up)))
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        s += "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        if intro?.atSegment != 0 { s += "#EXT-X-MAP:URI=\"init.mp4\"\n" }
        for i in 0..<grid.count {
            if let intro, intro.atSegment == i {
                if i > 0 { s += "#EXT-X-DISCONTINUITY\n" }
                s += String(format: "#EXT-X-MAP:URI=\"intro-init.mp4\"\n#EXTINF:%.3f,\nintro-0.m4s\n", intro.duration)
                s += "#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init.mp4\"\n"
            }
            s += String(format: "#EXTINF:%.3f,\nseg%05d.m4s\n", grid.duration(of: i), i)
        }
        return s + "#EXT-X-ENDLIST\n"
    }

    /// Master playlist that adds a WebVTT subtitle rendition (used for AVPlayer / AirPlay).
    func masterPlaylist() -> String {
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        var inf = "BANDWIDTH=20000000"
        if let v = plan.video, plan.isTranscodingVideo == false, v.isHDR {
            inf += ",VIDEO-RANGE=" + (v.colorTransfer == "arib-std-b67" ? "HLG" : "PQ")
        } else if plan.video != nil {
            inf += ",VIDEO-RANGE=SDR"
        }
        if hasSubtitles {
            s += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(subtitleName)\",LANGUAGE=\"\(subtitleLanguage)\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"subs.m3u8\"\n"
            s += "#EXT-X-STREAM-INF:\(inf),SUBTITLES=\"subs\"\nstream.m3u8\n"
        } else {
            s += "#EXT-X-STREAM-INF:\(inf)\nstream.m3u8\n"
        }
        return s
    }

    /// Master playlist for a Chromecast: the one variant with the CODECS, RESOLUTION, FRAME-RATE
    /// and BANDWIDTH attributes the Cast player uses to set up its decoders. Subtitles are not
    /// listed here; they go to the Chromecast as a separate text track.
    func castPlaylist() -> String? {
        guard grid != nil else { return nil }
        lock.lock()
        let initData = canonicalInit
        lock.unlock()
        var codecs = initData.map { MP4Boxes.codecs(inInit: $0) } ?? []
        if codecs.isEmpty { codecs = fallbackCodecs }

        var inf = "BANDWIDTH=\(estimatedBandwidth)"
        if !codecs.isEmpty { inf += ",CODECS=\"\(codecs.joined(separator: ","))\"" }
        if let v = plan.video, v.width > 0, v.height > 0, !plan.isAudioOnly {
            var width = v.width, height = v.height
            if case .transcode(let maxHeight, _, _) = plan.videoAction, v.height > maxHeight {
                height = maxHeight
                width = max(2, v.width * maxHeight / v.height / 2 * 2)
            }
            inf += ",RESOLUTION=\(width)x\(height)"
            if v.fps > 0 { inf += String(format: ",FRAME-RATE=%.3f", v.fps) }
            if plan.isTranscodingVideo {
                inf += ",VIDEO-RANGE=SDR"
            } else if v.isHDR {
                inf += ",VIDEO-RANGE=" + (v.colorTransfer == "arib-std-b67" ? "HLG" : "PQ")
            } else {
                inf += ",VIDEO-RANGE=SDR"
            }
        }
        return "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:\(inf)\nstream.m3u8\n"
    }

    /// Codec strings guessed from the plan, for the moment before the init segment exists.
    private var fallbackCodecs: [String] {
        var list: [String] = []
        if let v = plan.video, !plan.isAudioOnly {
            switch plan.videoAction {
            case .transcode: list.append("avc1.640028")
            case .copy:
                switch v.codec {
                case "h264": list.append(String(format: "avc1.64%02X%02X", 0, max(30, v.level)))
                case "hevc": list.append(v.bitDepth > 8 ? "hvc1.2.4.L\(max(90, v.level)).B0" : "hvc1.1.6.L\(max(90, v.level)).B0")
                case "vp9": list.append(v.bitDepth > 8 ? "vp09.02.10.10" : "vp09.00.10.08")
                case "av1": list.append(v.bitDepth > 8 ? "av01.0.08M.10" : "av01.0.08M.08")
                case "vp8": list.append("vp8")
                default: break
                }
            case .none: break
            }
        }
        if let a = plan.audio {
            switch plan.audioAction {
            case .encode(let codec, _, _):
                switch codec {
                case .aac: list.append("mp4a.40.2")
                case .eac3: list.append("ec-3")
                case .flac: list.append("flac")
                case .opus: list.append("opus")
                }
            case .copy, .none:
                switch a.codec {
                case "aac": list.append(a.profile?.contains("HE") == true ? "mp4a.40.5" : "mp4a.40.2")
                case "ac3": list.append("ac-3")
                case "eac3": list.append("ec-3")
                case "flac": list.append("flac")
                case "opus": list.append("opus")
                case "mp3": list.append("mp4a.6B")
                case "alac": list.append("alac")
                default: break
                }
            }
        }
        return list
    }

    /// Bits per second the player should expect: the file's own rate when streams are copied,
    /// the encoder settings when they are converted, with headroom for container overhead.
    private var estimatedBandwidth: Int {
        var video = 0, audio = 0
        if plan.video != nil, !plan.isAudioOnly {
            switch plan.videoAction {
            case .transcode(_, let kbps, _): video = kbps * 1000
            case .copy: video = plan.sourceBitRate.map { max(1_000_000, $0 - 320_000) } ?? 8_000_000
            case .none: break
            }
        }
        if plan.audio != nil {
            switch plan.audioAction {
            case .encode(let codec, _, let kbps): audio = codec == .flac ? 1_500_000 : kbps * 1000
            case .copy, .none: audio = 640_000
            }
        }
        return max(200_000, Int(Double(video + audio) * 1.1))
    }

    /// File-time windows of the subtitle segments: 10-second chunks, split where the title card
    /// goes in, because every rendition must share the stream's discontinuities.
    private func subtitleWindows() -> [Range<Double>] {
        let len = Self.subtitleSegmentLength
        let total = max(1, duration)
        var bounds = Array(stride(from: 0.0, to: total, by: len))
        if let grid, let intro {
            let at = grid.start(of: intro.atSegment)
            if at > 0, at < total, !bounds.contains(where: { abs($0 - at) < 0.001 }) { bounds.append(at) }
        }
        bounds.sort()
        return zip(bounds, bounds.dropFirst() + [total]).map { $0..<$1 }
    }

    func subtitlePlaylist() -> String {
        let windows = subtitleWindows()
        let intro = self.intro
        let at = intro.flatMap { i in grid.map { $0.start(of: i.atSegment) } }
        let target = max(Int(Self.subtitleSegmentLength), Int((intro?.duration ?? 0).rounded(.up)))
        var s = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        var cardPlaced = at == nil
        for (i, window) in windows.enumerated() {
            if let intro, let at, !cardPlaced, window.lowerBound >= at - 0.001 {
                // An empty subtitle segment for the card, between the same discontinuities as the video.
                if i > 0 { s += "#EXT-X-DISCONTINUITY\n" }
                s += String(format: "#EXTINF:%.3f,\nsubs-card.vtt\n#EXT-X-DISCONTINUITY\n", intro.duration)
                cardPlaced = true
            }
            s += String(format: "#EXTINF:%.3f,\nsubs-%d.vtt\n", window.upperBound - window.lowerBound, i)
        }
        return s + "#EXT-X-ENDLIST\n"
    }

    /// Cue times stay in file time: after a discontinuity the player maps them onto the film's
    /// own timestamps, which are file time as well.
    func subtitleSegment(_ index: Int) -> String {
        let windows = subtitleWindows()
        guard index >= 0, index < windows.count else { return "WEBVTT\n\n" }
        return WebVTT.document(cues ?? [], shift: 0, window: windows[index], timestampMap: true)
    }

    /// The subtitle segment for the title card: no cues.
    func subtitleCard() -> String { "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n" }

    func subtitleDocument() -> String { WebVTT.document(cues ?? [], shift: 0) }
}
