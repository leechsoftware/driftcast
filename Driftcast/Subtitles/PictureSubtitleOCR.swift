import CryptoKit
import Foundation

/// The vendored macSubtitleOCR sources print diagnostics to this stream.
nonisolated(unsafe) var stderr = FileHandleOutputStream(.standardError)

/// Turns PGS and VobSub picture subtitles into text with the Vision framework, using the
/// parsers and recogniser from macSubtitleOCR (MIT, see OCR/LICENSE-macSubtitleOCR.txt).
///
/// Results are cached as SRT files keyed by the media file and track, so a film is read once.
actor PictureSubtitleOCR {
    static let shared = PictureSubtitleOCR()

    private var inFlight: [String: Task<[SubtitleCue], Error>] = [:]

    enum Failure: LocalizedError {
        case unsupported
        case trackNotFound
        case nothingRecognised

        var errorDescription: String? {
            switch self {
            case .unsupported: return "These subtitles can't be converted to text."
            case .trackNotFound: return "The subtitle track couldn't be read from the file."
            case .nothingRecognised: return "No text was recognised in the subtitles."
            }
        }
    }

    /// PGS and VobSub inside MKV, or as .sup / .idx files. Other containers keep burning in.
    nonisolated static func supports(_ choice: SubtitleChoice, media: URL) -> Bool {
        switch choice {
        case .embedded(let s):
            guard ["mkv", "mks", "mk3d"].contains(media.pathExtension.lowercased()) else { return false }
            return s.codec == "hdmv_pgs_subtitle" || s.codec == "dvd_subtitle"
        case .external(let url):
            return ["sup", "idx", "sub"].contains(url.pathExtension.lowercased())
        }
    }

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/OCR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(for choice: SubtitleChoice, media: URL) -> URL {
        let source: URL
        if case .external(let u) = choice { source = u } else { source = media }
        let mtime = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(source.path)|\(mtime)|\(choice.id)".utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(String(digest.prefix(32)) + ".srt")
    }

    /// Cues for the subtitle, running OCR if there is no cached result yet.
    func cues(for choice: SubtitleChoice, media: URL, info: MediaInfo, preferredLanguage: String) async throws -> [SubtitleCue] {
        guard Self.supports(choice, media: media) else { throw Failure.unsupported }
        let file = Self.cacheFile(for: choice, media: media)
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let cues = WebVTT.parse(text)
            if !cues.isEmpty { return cues }
        }
        if let task = inFlight[choice.id] { return try await task.value }
        let task = Task<[SubtitleCue], Error> {
            let srt = try await Self.recognise(choice, media: media, info: info, preferredLanguage: preferredLanguage)
            try srt.write(to: file, atomically: true, encoding: .utf8)
            let cues = WebVTT.parse(srt)
            guard !cues.isEmpty else { throw Failure.nothingRecognised }
            return cues
        }
        inFlight[choice.id] = task
        defer { inFlight[choice.id] = nil }
        return try await task.value
    }

    private static func recognise(_ choice: SubtitleChoice, media: URL, info: MediaInfo, preferredLanguage: String) async throws -> String {
        let subtitles: [Subtitle]
        var trackLanguage: String? = choice.language

        switch choice {
        case .external(let url):
            let ext = url.pathExtension.lowercased()
            if ext == "sup" {
                subtitles = try PGS(url).subtitles
            } else {
                let base = url.deletingPathExtension()
                let vob = try VobSub(base.appendingPathExtension("sub"), base.appendingPathExtension("idx"))
                subtitles = vob.subtitles
                trackLanguage = vob.language ?? trackLanguage
            }
        case .embedded(let stream):
            // ffprobe stream order and Matroska track order both follow the file, so the n-th
            // picture-subtitle stream is the n-th PGS/VobSub track.
            let pictureStreams = info.subtitles.filter { $0.codec == "hdmv_pgs_subtitle" || $0.codec == "dvd_subtitle" }
            guard let position = pictureStreams.firstIndex(where: { $0.index == stream.index }) else { throw Failure.trackNotFound }
            let mkv = try MKVSubtitleExtractor(filePath: media.path)
            try mkv.parseTracks(for: ["S_HDMV/PGS", "S_VOBSUB"])
            guard position < mkv.tracks.count else { throw Failure.trackNotFound }
            let track = mkv.tracks[position]
            trackLanguage = track.language ?? trackLanguage
            if track.codecID == "S_HDMV/PGS" {
                subtitles = try track.trackData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in try PGS(buffer) }.subtitles
            } else {
                subtitles = try track.trackData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in try VobSub(buffer, track.idxData ?? "") }.subtitles
            }
        }
        guard !subtitles.isEmpty else { throw Failure.nothingRecognised }

        var languages = [Lang.normalize(trackLanguage), Lang.normalize(preferredLanguage), "en"].compactMap { $0 }
        languages = languages.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let processor = SubtitleProcessor(
            for: subtitles, from: 0,
            withOptions: false, false, languages.joined(separator: ","), nil, false, false, false, false,
            NSTemporaryDirectory(), max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
        let result = try await processor.process()
        let ordered = result.srt.filter { !($0.text ?? "").isEmpty }.sorted { $0.index < $1.index }
        guard !ordered.isEmpty else { throw Failure.nothingRecognised }
        // SRT fixes up missing/overlapping end times; render through it and read back.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("driftcast-ocr-\(UUID().uuidString).srt")
        SRT(subtitles: ordered).write(toFileAt: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try String(contentsOf: tmp, encoding: .utf8)
    }
}
