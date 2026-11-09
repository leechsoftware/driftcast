import AVFoundation
import Foundation
import os

/// Plays on this Mac, or on an Apple TV / AirPlay 2 TV when the user picks one in the AirPlay
/// menu. With AirPlay the TV fetches our HTTP URLs itself, so HEVC, HDR and Dolby audio reach
/// it untouched.
@MainActor
final class AVPlayerTarget: PlaybackTarget {
    let player = AVPlayer()
    var onStatus: ((TargetStatus) -> Void)?
    /// Called when AirPlay starts or stops (the UI shows the route name).
    var onExternalChange: ((Bool) -> Void)?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var externalObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var diagnostics: [NSObjectProtocol] = []
    private var waitingObservation: NSKeyValueObservation?
    private static let log = Logger(subsystem: "com.leechsoftware.driftcast", category: "player")

    init() {
        player.allowsExternalPlayback = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit() }
        }
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Self.log.info("AirPlay external playback \(active ? "started" : "stopped", privacy: .public)")
            DispatchQueue.main.async { self?.onExternalChange?(active) }
        }
        waitingObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
            Self.log.info("timeControlStatus \(player.timeControlStatus.rawValue), waiting reason \(reason, privacy: .public), external \(player.isExternalPlaybackActive)")
        }
        let center = NotificationCenter.default
        diagnostics.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: nil, queue: nil) { note in
            guard let event = (note.object as? AVPlayerItem)?.errorLog()?.events.last else { return }
            Self.log.error("item error log: \(event.errorStatusCode) \(event.errorDomain, privacy: .public) \(event.errorComment ?? "-", privacy: .public) uri \(event.uri ?? "-", privacy: .public)")
        })
        diagnostics.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: nil) { note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Self.log.error("failed to play to end: \(String(describing: error), privacy: .public)")
        })
        diagnostics.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: nil) { _ in
            Self.log.error("playback stalled")
        })
    }

    var isExternal: Bool { player.isExternalPlaybackActive }

    func prepare() async throws -> String {
        NetworkUtil.primaryIPv4() ?? "127.0.0.1"
    }

    /// How this Mac draws WebVTT subtitles: the system's style at `scale` times its size. An
    /// AirPlay TV draws them itself with its own settings, so there this has no effect.
    static func textStyleRules(scale: Double) -> [AVTextStyleRule] {
        guard let rule = AVTextStyleRule(textMarkupAttributes: [
            kCMTextMarkupAttribute_RelativeFontSize as String: SubtitleSize.normalized(scale) * 100,
        ]) else { return [] }
        return [rule]
    }

    func setSubtitleScale(_ scale: Double) {
        player.currentItem?.textStyleRules = Self.textStyleRules(scale: scale)
    }

    func load(_ r: LoadRequest) async throws {
        clearItem()
        let item = AVPlayerItem(url: r.url)
        item.textStyleRules = Self.textStyleRules(scale: SubtitleSize.current)
        Self.log.info("load \(r.url.absoluteString, privacy: .public) at \(r.startTime), external \(self.player.isExternalPlaybackActive)")
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Self.log.info("item status \(item.status.rawValue) \(String(describing: item.error), privacy: .public)")
            guard item.status == .failed else { return }
            let message = Self.describe(item)
            DispatchQueue.main.async { self?.onStatus?(TargetStatus(state: .idle, error: message)) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStatus?(TargetStatus(state: .idle, finished: true)) }
        }
        player.replaceCurrentItem(with: item)

        // Wait until AVPlayer has read enough to know whether it can play this.
        for _ in 0..<300 where item.status == .unknown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if item.status == .failed { throw NSError(domain: "Driftcast", code: 1, userInfo: [NSLocalizedDescriptionKey: Self.describe(item)]) }

        if r.startTime > 0.5 {
            await player.seek(to: CMTime(seconds: r.startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        if r.subtitleURL != nil, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            let option = group.options.first { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? group.options.first
            item.select(option, in: group)
        }
        player.play()
    }

    private nonisolated static func describe(_ item: AVPlayerItem) -> String {
        if let event = item.errorLog()?.events.last, let comment = event.errorComment { return comment }
        return item.error?.localizedDescription ?? "This Mac couldn't play the stream."
    }

    private func emit() {
        guard player.currentItem != nil else { return }
        var s = TargetStatus()
        switch player.timeControlStatus {
        case .playing: s.state = .playing
        case .paused: s.state = .paused
        case .waitingToPlayAtSpecifiedRate: s.state = .buffering
        @unknown default: s.state = .idle
        }
        let t = player.currentTime().seconds
        if t.isFinite { s.time = t }
        s.volume = Double(player.volume)
        onStatus?(s)
    }

    private func clearItem() {
        statusObservation = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        clearItem()
        player.replaceCurrentItem(with: nil)
    }

    func setVolume(_ level: Double) { player.volume = Float(min(1, max(0, level))) }

    func disconnect() { stop() }
}
