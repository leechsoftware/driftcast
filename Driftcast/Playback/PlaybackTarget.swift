import Foundation

struct LoadRequest {
    var url: URL
    var contentType: String
    var isHLS: Bool
    var title: String
    var startTime: Double
    var duration: Double
    var subtitleURL: URL?
    var subtitleName: String?
    var subtitleLanguage: String?
    /// Artwork a Chromecast shows while loading or paused.
    var posterURL: URL?
    /// Film or episode details for the device's own display (title, year, episode number).
    var details: MovieDetails?
    /// Seconds a Chromecast should sit on its poster screen before playing (0 = start at once).
    var posterHoldSeconds: Double = 0
}

struct TargetStatus {
    enum State { case idle, buffering, playing, paused }
    var state: State = .idle
    /// Seconds into the loaded stream (not necessarily the file; see StreamSession.offset).
    var time: Double?
    var finished = false
    var error: String?
    var volume: Double?
    /// The device connection dropped and was re-established; the stream must be loaded again.
    var reconnected = false
}

/// A device that plays a URL: AVPlayer (this Mac / AirPlay) or a Chromecast.
@MainActor
protocol PlaybackTarget: AnyObject {
    var onStatus: ((TargetStatus) -> Void)? { get set }
    /// Connects if needed; returns the LAN address the device should fetch media from.
    func prepare() async throws -> String
    func load(_ request: LoadRequest) async throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
    func setVolume(_ level: Double)
    /// Subtitles are drawn at `scale` times the normal size from now on (see `SubtitleSize`).
    func setSubtitleScale(_ scale: Double)
    func disconnect()
}
