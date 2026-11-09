import Foundation

/// Client for the OpenSubtitles.com REST API (v1). The API key identifies the app, not the
/// person using it: put Driftcast's own key in `builtInKey` and nobody has to enter one. A key
/// typed into Settings takes precedence. Keys come from https://www.opensubtitles.com/consumers.
struct OpenSubtitlesClient {
    /// Driftcast's own API key, shipped with the app. Empty until one is registered.
    static let builtInKey = ""
    static let keyPage = URL(string: "https://www.opensubtitles.com/consumers")!

    /// The key searches will use: the one from Settings, else the built-in one.
    static var activeKey: String {
        let own = Prefs.string(Prefs.openSubtitlesKey).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? builtInKey : own
    }
    static var hasKey: Bool { !activeKey.isEmpty }

    struct Result: Identifiable, Hashable {
        var id: Int { fileID }
        var fileID: Int
        var release: String
        var fileName: String
        var language: String
        var downloads: Int
        var hearingImpaired: Bool
        var hashMatch: Bool
        var title: String
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noKey: return "Searching online needs a free OpenSubtitles API key."
            case .http(let code, let msg): return "OpenSubtitles returned \(code)\(msg.isEmpty ? "" : ": \(msg)")"
            case .badResponse: return "OpenSubtitles sent a response Driftcast couldn't read."
            }
        }

        /// OpenSubtitles answers 401 or 403 when the key itself is wrong.
        var isKeyRefused: Bool {
            switch self {
            case .noKey: return true
            case .http(let code, _): return code == 401 || code == 403
            case .badResponse: return false
            }
        }
    }

    var apiKey: String
    private let base = URL(string: "https://api.opensubtitles.com/api/v1")!

    static func fromSettings() throws -> OpenSubtitlesClient {
        let key = activeKey
        guard !key.isEmpty else { throw Failure.noKey }
        return OpenSubtitlesClient(apiKey: key)
    }

    private func makeRequest(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        r.setValue("Driftcast v\(AppVersion.installed)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            throw Failure.http(code, (json?["message"] as? String) ?? (json?["errors"] as? [String])?.first ?? "")
        }
        guard let json else { throw Failure.badResponse }
        return json
    }

    /// Searches by file hash (exact release match) and by title, narrowed to one episode of a
    /// show when the season and episode are known. The API wants parameters sorted and
    /// lower-cased or it answers with a redirect.
    func search(query: String, languages: String, movieHash: String?, season: Int? = nil, episode: Int? = nil) async throws -> [Result] {
        var items: [URLQueryItem] = []
        if !languages.isEmpty { items.append(URLQueryItem(name: "languages", value: languages.lowercased())) }
        if let movieHash { items.append(URLQueryItem(name: "moviehash", value: movieHash)) }
        if !query.isEmpty { items.append(URLQueryItem(name: "query", value: query.lowercased())) }
        if let season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
        if let episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        items.sort { $0.name < $1.name }
        var comps = URLComponents(url: base.appendingPathComponent("subtitles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        // The API redirects %20 to +, so go straight there.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "%20", with: "+")
        let json = try await perform(makeRequest(comps.url!))
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { entry in
            guard let attrs = entry["attributes"] as? [String: Any],
                  let file = (attrs["files"] as? [[String: Any]])?.first,
                  let fileID = file["file_id"] as? Int else { return nil }
            let feature = attrs["feature_details"] as? [String: Any] ?? [:]
            var title = feature["title"] as? String ?? feature["movie_name"] as? String ?? ""
            if let year = feature["year"] as? Int { title += " (\(year))" }
            return Result(fileID: fileID,
                          release: attrs["release"] as? String ?? "",
                          fileName: file["file_name"] as? String ?? "",
                          language: attrs["language"] as? String ?? "",
                          downloads: attrs["download_count"] as? Int ?? 0,
                          hearingImpaired: attrs["hearing_impaired"] as? Bool ?? false,
                          hashMatch: attrs["moviehash_match"] as? Bool ?? false,
                          title: title)
        }
        .sorted { ($0.hashMatch ? 1 : 0, $0.downloads) > ($1.hashMatch ? 1 : 0, $1.downloads) }
    }

    /// Downloads a subtitle as SRT into Application Support and returns the file.
    func download(_ result: Result, for video: URL) async throws -> URL {
        let body = try JSONSerialization.data(withJSONObject: ["file_id": result.fileID, "sub_format": "srt"])
        let json = try await perform(makeRequest(base.appendingPathComponent("download"), method: "POST", body: body))
        guard let link = (json["link"] as? String).flatMap(URL.init(string:)) else { throw Failure.badResponse }
        let (data, _) = try await URLSession.shared.data(from: link)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/Subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(video.deletingPathExtension().lastPathComponent).\(result.language).\(result.fileID).srt"
        let file = dir.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    /// OpenSubtitles hash: file size plus the 64-bit little-endian word sums of the first and
    /// last 64 KiB, wrapping on overflow.
    static func movieHash(for url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size >= 65536 else { return nil }
        var hash = size
        func sum(at offset: UInt64) -> Bool {
            guard (try? fh.seek(toOffset: offset)) != nil, let data = try? fh.read(upToCount: 65536), data.count == 65536 else { return false }
            data.withUnsafeBytes { raw in
                for i in 0..<8192 { hash &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) }
            }
            return true
        }
        guard sum(at: 0), sum(at: size - 65536) else { return nil }
        return String(format: "%016llx", hash)
    }
}
