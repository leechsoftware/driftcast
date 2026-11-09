import CryptoKit
import Foundation

/// Where every HLS segment starts, decided before conversion begins so the whole playlist can
/// be handed to the device up front.
///
/// Converted video: a fixed 4-second grid (ffmpeg forces a keyframe at each multiple of 4).
/// Copied video: one segment per source keyframe, which is exactly where ffmpeg's HLS muxer
/// splits when `hls_time` is 0. Audio-only streams use the fixed grid.
struct SegmentGrid: Sendable {
    static let fixedLength = 4.0

    var starts: [Double]
    var duration: Double

    var count: Int { starts.count }

    func start(of i: Int) -> Double { starts[i] }

    func duration(of i: Int) -> Double {
        let end = i + 1 < count ? starts[i + 1] : duration
        return max(0.001, end - starts[i])
    }

    /// Segment that contains `time`.
    func index(at time: Double) -> Int {
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Segment whose start is nearest `time` (used to see where a restarted job landed).
    func nearestIndex(to time: Double) -> Int {
        let i = index(at: time)
        if i + 1 < count, abs(starts[i + 1] - time) < abs(starts[i] - time) { return i + 1 }
        return i
    }

    var targetDuration: Int {
        max(1, Int(((0..<count).map { duration(of: $0) }.max() ?? Self.fixedLength).rounded(.up)))
    }

    static func fixed(duration: Double) -> SegmentGrid {
        let n = max(1, Int((duration / fixedLength).rounded(.up)))
        return SegmentGrid(starts: (0..<n).map { Double($0) * fixedLength }, duration: duration)
    }

    static func keyframes(_ times: [Double], duration: Double) -> SegmentGrid {
        var starts = times.sorted()
        if starts.isEmpty || starts[0] > 0.5 { starts.insert(0, at: 0) }
        starts = starts.filter { $0 < duration }
        return SegmentGrid(starts: starts, duration: duration)
    }
}

/// Reads keyframe times with ffprobe (packets only, no decoding) and caches them.
actor KeyframeIndex {
    static let shared = KeyframeIndex()
    private var memory: [String: [Double]] = [:]

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/Keyframes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func keyframes(for url: URL, streamIndex: Int) async throws -> [Double] {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("\(url.path)|\(mtime)|\(streamIndex)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let m = memory[key] { return m }
        let file = Self.directory.appendingPathComponent(String(key.prefix(32)) + ".json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([Double].self, from: data) {
            memory[key] = cached
            return cached
        }
        guard let exe = FFmpeg.ffprobe else { throw FFmpegError.notFound }
        let data = try await FFmpeg.run(exe, ["-v", "error", "-select_streams", "\(streamIndex)", "-show_entries",
                                             "packet=pts_time,dts_time,flags", "-of", "csv=p=0", url.path])
        var times: [Double] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, f[2].contains("K") else { continue }
            if let t = Double(f[0]) ?? Double(f[1]) { times.append(t) }
        }
        times.sort()
        memory[key] = times
        if let out = try? JSONEncoder().encode(times) { try? out.write(to: file) }
        return times
    }
}
