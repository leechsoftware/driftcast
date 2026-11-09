import CryptoKit
import Foundation

/// Grabs single frames with ffmpeg: posters for playlist rows and previews while scrubbing.
/// Works for every container ffmpeg reads (AVFoundation can't open MKV, AVI, ...).
actor Thumbnailer {
    static let shared = Thumbnailer()

    private var memory: [String: Data] = [:]
    private var order: [String] = []
    private let limiter = AsyncLimiter(3)

    private static var posterDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/Posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// JPEG data for the frame nearest `time`, scaled to `width` pixels wide.
    func frame(_ url: URL, at time: Double, width: Int = 320) async -> Data? {
        let key = "\(url.path)#\(Int(time / 2))#\(width)"
        if let d = memory[key] { return d }
        guard let exe = FFmpeg.ffmpeg else { return nil }
        await limiter.acquire()
        let position = String(format: "%.2f", max(0, time))
        let rest = ["-i", url.path, "-frames:v", "1", "-an", "-sn", "-vf", "scale=\(width):-2",
                    "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "5", "pipe:1"]
        let common = ["-hide_banner", "-nostdin", "-loglevel", "error"]
        // The nearest keyframe is close enough for a thumbnail and needs one decoded frame, not
        // the hundred or so back to it, which matters a great deal for 4K HEVC on an older Mac.
        var data = try? await FFmpeg.run(exe, common + ["-noaccurate_seek", "-skip_frame", "nokey", "-ss", position] + rest)
        // Close to the end of a file there may be no keyframe left to land on.
        if data?.isEmpty != false { data = try? await FFmpeg.run(exe, common + ["-ss", position] + rest) }
        await limiter.release()
        guard let data, !data.isEmpty else { return nil }
        memory[key] = data
        order.append(key)
        if order.count > 300 { memory[order.removeFirst()] = nil }
        return data
    }

    /// A poster frame about 10% in, cached on disk keyed by path and modification date.
    func poster(for url: URL, duration: Double) async -> Data? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(mtime)".utf8)).map { String(format: "%02x", $0) }.joined()
        let file = Self.posterDirectory.appendingPathComponent(String(digest.prefix(32)) + ".jpg")
        if let d = try? Data(contentsOf: file) { return d }
        let t = duration > 0 ? min(duration * 0.1, 300) : 5
        guard let d = await frame(url, at: t, width: 320) else { return nil }
        try? d.write(to: file)
        return d
    }
}
