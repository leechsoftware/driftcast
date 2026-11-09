import Foundation

enum CastError: LocalizedError {
    case timeout
    case notConnected
    case launchFailed
    case loadFailed(String)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "The Chromecast didn't respond in time. Check that it is on and on the same network, and that Driftcast is allowed to find devices on the local network (System Settings > Privacy & Security > Local Network)."
        case .notConnected: return "Not connected to the Chromecast."
        case .launchFailed: return "The Chromecast couldn't start its media player."
        case .loadFailed(let s): return "The Chromecast couldn't play this stream (\(s))."
        case .connection(let s): return "Lost connection to the Chromecast: \(s)"
        }
    }
}

/// Drives a Chromecast's Default Media Receiver over the Cast v2 protocol.
///
/// Sequence: CONNECT to receiver-0, LAUNCH app CC1AD845, read its transportId from
/// RECEIVER_STATUS, CONNECT to the transport, then LOAD / PLAY / PAUSE / SEEK on the media
/// namespace. A PING every 5 s keeps the session alive.
@MainActor
final class CastTarget: PlaybackTarget {
    static let defaultReceiverAppID = "CC1AD845"

    private enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    let device: CastDeviceInfo
    var onStatus: ((TargetStatus) -> Void)?

    private var channel: CastChannel?
    private var transportID: String?
    private var appSessionID: String?
    private var mediaSessionID: Int?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var heartbeatTimer: Timer?
    private var pollTimer: Timer?
    private var lastHeard = Date()
    private var localHost: String?
    private var reconnecting = false

    init(device: CastDeviceInfo) {
        self.device = device
    }

    // MARK: Connection

    func prepare() async throws -> String {
        try await ensureConnected()
        return localHost ?? NetworkUtil.primaryIPv4() ?? "127.0.0.1"
    }

    private func ensureConnected() async throws {
        if channel == nil { try await openChannel() }
        if transportID == nil { try await launchReceiver() }
    }

    private func openChannel() async throws {
        let ch = CastChannel(endpoint: device.endpoint)
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ch.onEvent = { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .ready:
                        if once.claim() { cont.resume() }
                    case .failed(let reason):
                        if once.claim() { cont.resume(throwing: CastError.connection(reason)) } else { self?.channelLost(reason) }
                    }
                }
            }
            ch.onMessage = { [weak self] msg in
                Task { @MainActor in self?.handle(msg) }
            }
            ch.start()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if once.claim() { ch.close(); cont.resume(throwing: CastError.timeout) }
            }
        }
        channel = ch
        localHost = ch.localIPv4
        lastHeard = Date()
        ch.send(namespace: NS.connection, destination: "receiver-0", payload: ["type": "CONNECT", "origin": [String: Any]()])
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
    }

    private func heartbeat() {
        guard let channel else { return }
        if Date().timeIntervalSince(lastHeard) > 25 { channelLost("no heartbeat"); return }
        channel.send(namespace: NS.heartbeat, destination: "receiver-0", payload: ["type": "PING"])
    }

    private func launchReceiver() async throws {
        // Join the media receiver if it's already running (after a reconnect, or from an
        // earlier session); otherwise launch it.
        var status = try await request(NS.receiver, "receiver-0", ["type": "GET_STATUS"])
        var found = applyReceiverStatus(status)
        if !found {
            status = try await request(NS.receiver, "receiver-0", ["type": "LAUNCH", "appId": Self.defaultReceiverAppID], timeout: 20)
            found = applyReceiverStatus(status)
        }
        var tries = 0
        while !found && tries < 12 {
            try await Task.sleep(nanoseconds: 500_000_000)
            status = try await request(NS.receiver, "receiver-0", ["type": "GET_STATUS"])
            found = applyReceiverStatus(status)
            tries += 1
        }
        guard let transportID else { throw CastError.launchFailed }
        channel?.send(namespace: NS.connection, destination: transportID, payload: ["type": "CONNECT", "origin": [String: Any]()])
    }

    /// Picks our app out of RECEIVER_STATUS. Returns false if it isn't running.
    @discardableResult
    private func applyReceiverStatus(_ msg: [String: Any]) -> Bool {
        let status = msg["status"] as? [String: Any] ?? [:]
        if let vol = status["volume"] as? [String: Any], let level = vol["level"] as? Double { volumeLevel = level }
        let apps = status["applications"] as? [[String: Any]] ?? []
        guard let app = apps.first(where: { ($0["appId"] as? String) == Self.defaultReceiverAppID }),
              let t = app["transportId"] as? String else { return false }
        transportID = t
        appSessionID = app["sessionId"] as? String
        return true
    }

    private(set) var volumeLevel: Double?

    private func request(_ ns: String, _ destination: String, _ payload: [String: Any], timeout: Double = 10) async throws -> [String: Any] {
        guard let channel else { throw CastError.notConnected }
        let id = nextRequestID
        nextRequestID += 1
        var p = payload
        p["requestId"] = id
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            channel.send(namespace: ns, destination: destination, payload: p)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = self?.pending.removeValue(forKey: id) { c.resume(throwing: CastError.timeout) }
            }
        }
    }

    /// Fire-and-forget command (the device still wants a requestId).
    private func command(_ ns: String, _ destination: String, _ payload: [String: Any]) {
        var p = payload
        p["requestId"] = nextRequestID
        nextRequestID += 1
        channel?.send(namespace: ns, destination: destination, payload: p)
    }

    private func channelLost(_ reason: String) {
        let wasActive = channel != nil
        let hadSession = transportID != nil
        reset()
        guard wasActive else { return }
        let failure = CastError.connection(reason).localizedDescription
        guard hadSession, !reconnecting else {
            onStatus?(TargetStatus(state: .idle, error: failure))
            return
        }
        // Wi-Fi blips are common; try to get back for a few seconds before giving up.
        reconnecting = true
        Task { @MainActor [weak self] in
            defer { self?.reconnecting = false }
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                guard let self else { return }
                do {
                    try await self.ensureConnected()
                    self.onStatus?(TargetStatus(state: .idle, reconnected: true))
                    return
                } catch {
                    continue
                }
            }
            self?.onStatus?(TargetStatus(state: .idle, error: failure))
        }
    }

    private func reset() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        pollTimer?.invalidate(); pollTimer = nil
        channel?.close()
        channel = nil
        transportID = nil
        appSessionID = nil
        mediaSessionID = nil
        let waiting = pending
        pending = [:]
        for (_, c) in waiting { c.resume(throwing: CastError.notConnected) }
    }

    // MARK: Incoming

    private func handle(_ msg: CastProto.Message) {
        lastHeard = Date()
        guard let payload = msg.payload, let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""

        if msg.namespace == NS.heartbeat {
            if type == "PING" { channel?.send(namespace: NS.heartbeat, destination: msg.source, payload: ["type": "PONG"]) }
            return
        }
        if msg.namespace == NS.connection, type == "CLOSE" {
            if msg.source == transportID { receiverAppClosed() }
            return
        }
        if let rid = json["requestId"] as? Int, rid != 0, let cont = pending.removeValue(forKey: rid) {
            cont.resume(returning: json)
        }
        switch type {
        case "RECEIVER_STATUS":
            let had = transportID != nil
            let status = json["status"] as? [String: Any] ?? [:]
            if let vol = status["volume"] as? [String: Any], let level = vol["level"] as? Double {
                volumeLevel = level
                onStatus?(TargetStatus(state: currentState, time: nil, volume: level))
            }
            if had, !applyReceiverStatus(json) {
                receiverAppClosed()
            }
        case "MEDIA_STATUS":
            applyMediaStatus(json)
        default:
            break
        }
    }

    private var currentState: TargetStatus.State = .idle

    private func applyMediaStatus(_ json: [String: Any]) {
        guard let entries = json["status"] as? [[String: Any]], let s = entries.first else { return }
        if let id = s["mediaSessionId"] as? Int { mediaSessionID = id }
        var status = TargetStatus()
        switch s["playerState"] as? String {
        case "PLAYING": status.state = .playing
        case "PAUSED": status.state = holdUntil.map { $0 > Date() } == true ? .buffering : .paused
        case "BUFFERING", "LOADING": status.state = .buffering
        default: status.state = .idle
        }
        currentState = status.state
        status.time = s["currentTime"] as? Double
        if status.state == .idle {
            switch s["idleReason"] as? String {
            case "FINISHED": status.finished = true
            case "ERROR":
                let code = (s["extendedStatus"] as? [String: Any])?["detailedErrorCode"] ?? ""
                status.error = "The Chromecast stopped with a playback error \(code)".trimmingCharacters(in: .whitespaces)
            default: break
            }
        }
        if let vol = s["volume"] as? [String: Any], let level = vol["level"] as? Double { status.volume = level }
        onStatus?(status)
    }

    private func receiverAppClosed() {
        pollTimer?.invalidate(); pollTimer = nil
        transportID = nil
        mediaSessionID = nil
        onStatus?(TargetStatus(state: .idle, error: "Playback on \(device.name) was stopped from another device."))
    }

    // MARK: Control

    func load(_ r: LoadRequest) async throws {
        try await ensureConnected()
        guard let transportID else { throw CastError.notConnected }
        mediaSessionID = nil

        // What the TV shows while loading and paused: a film's title, year and director, or an
        // episode's show, number and name, with the poster.
        var metadata: [String: Any]
        if let d = r.details, d.isEpisode {
            metadata = ["metadataType": 2, "seriesTitle": d.showTitle ?? d.title, "title": d.episodeTitle ?? r.title]
            if let season = d.season { metadata["season"] = season }
            if let episode = d.episode { metadata["episode"] = episode }
            if let date = d.airDate, date.count == 10 { metadata["originalAirdate"] = date }
        } else if let d = r.details {
            metadata = ["metadataType": 1, "title": d.title]
            var subtitle: [String] = []
            if let year = d.year { subtitle.append(String(year)) }
            if let director = d.directors.first { subtitle.append("Directed by \(director)") }
            if !subtitle.isEmpty { metadata["subtitle"] = subtitle.joined(separator: " · ") }
            if let studio = d.network { metadata["studio"] = studio }
        } else {
            metadata = ["metadataType": 0, "title": r.title]
        }
        if let poster = r.posterURL { metadata["images"] = [["url": poster.absoluteString]] }
        var media: [String: Any] = [
            "contentId": r.url.absoluteString,
            "contentUrl": r.url.absoluteString,
            "contentType": r.contentType,
            "streamType": "BUFFERED",
            "metadata": metadata,
        ]
        if r.duration > 0 { media["duration"] = r.duration }
        if r.isHLS {
            media["hlsSegmentFormat"] = "fmp4"
            media["hlsVideoSegmentFormat"] = "fmp4"
        }
        // With a hold, the receiver stays on its poster-and-title screen (its paused state)
        // for a moment, then PLAY starts the video.
        var message: [String: Any] = ["type": "LOAD", "media": media, "autoplay": r.posterHoldSeconds <= 0, "currentTime": r.startTime]
        if let sub = r.subtitleURL {
            media["tracks"] = [[
                "trackId": 1, "type": "TEXT", "subtype": "SUBTITLES",
                "trackContentId": sub.absoluteString, "trackContentType": "text/vtt",
                "name": r.subtitleName ?? "Subtitles", "language": r.subtitleLanguage ?? "en",
            ]]
            let scale = Prefs.double(Prefs.subtitleScale)
            media["textTrackStyle"] = [
                "foregroundColor": "#FFFFFFFF", "backgroundColor": "#00000000",
                "edgeType": "OUTLINE", "edgeColor": "#000000FF",
                "fontScale": scale > 0 ? scale : 1.0, "fontFamily": "Droid Sans",
            ]
            message["media"] = media
            message["activeTrackIds"] = [1]
        }

        let resp = try await request(NS.media, transportID, message, timeout: 45)
        let type = resp["type"] as? String ?? ""
        guard type == "MEDIA_STATUS" else {
            let detail = (resp["detailedErrorCode"] as? Int).map { "error \($0)" } ?? (resp["reason"] as? String) ?? type
            throw CastError.loadFailed(detail)
        }
        startPolling()
        if r.posterHoldSeconds > 0 {
            let until = Date().addingTimeInterval(r.posterHoldSeconds)
            holdUntil = until
            let session = mediaSessionID
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(r.posterHoldSeconds * 1_000_000_000))
                guard let self, self.holdUntil == until, self.mediaSessionID == session else { return }
                self.holdUntil = nil
                self.play()
            }
        }
    }

    /// While the poster is being shown on purpose, the receiver's "paused" is really "starting".
    private var holdUntil: Date?

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let t = self.transportID else { return }
                var p: [String: Any] = ["type": "GET_STATUS"]
                if let id = self.mediaSessionID { p["mediaSessionId"] = id }
                self.command(NS.media, t, p)
            }
        }
    }

    private func mediaCommand(_ type: String, _ extra: [String: Any] = [:]) {
        guard let t = transportID, let id = mediaSessionID else { return }
        var p = extra
        p["type"] = type
        p["mediaSessionId"] = id
        command(NS.media, t, p)
    }

    func play() { mediaCommand("PLAY") }
    func pause() { mediaCommand("PAUSE") }
    func seek(to seconds: Double) { mediaCommand("SEEK", ["currentTime": max(0, seconds)]) }

    func stop() {
        mediaCommand("STOP")
        pollTimer?.invalidate(); pollTimer = nil
        mediaSessionID = nil
    }

    func setVolume(_ level: Double) {
        guard channel != nil else { return }
        command(NS.receiver, "receiver-0", ["type": "SET_VOLUME", "volume": ["level": min(1, max(0, level))]])
    }

    /// Stops the receiver app on the TV and closes the connection.
    func disconnect() {
        if let sid = appSessionID { command(NS.receiver, "receiver-0", ["type": "STOP", "sessionId": sid]) }
        if let t = transportID { channel?.send(namespace: NS.connection, destination: t, payload: ["type": "CLOSE"]) }
        reset()
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
