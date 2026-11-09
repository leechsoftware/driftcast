import CryptoKit
import Foundation

/// Looks up posters, plot, director, cast and ratings for the videos in the library.
///
/// Films come from Wikipedia (poster, plot) and Wikidata (director, writers, cast, genres,
/// running time, IMDb link), shows and episodes from TVmaze; none needs an account or key.
/// With an OMDb key (`OMDbClient`), OMDb is asked first, which adds IMDb, Rotten Tomatoes and
/// Metacritic ratings. Everything is cached on disk, the services are asked no faster than
/// they allow, and nothing is looked up when "Look up posters and details online" is off.
actor MetadataLookup {
    static let shared = MetadataLookup()

    private struct Entry: Codable {
        var details: MovieDetails?
        var fetched: Date
    }

    enum Fetched {
        case data(Data)
        case notFound
        case failed
    }

    private enum Outcome {
        case found(MovieDetails)
        case none
        case failed
    }

    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var artworkMemory: [URL: Data] = [:]
    private var artworkOrder: [URL] = []
    private var nextAllowed: [String: Date] = [:]
    private var overrides: [String: MediaTitle] = [:]
    private var overridesLoaded = false

    static var isEnabled: Bool { Prefs.bool(Prefs.onlineDetails) }

    /// A title that found nothing is asked about again after this long.
    private static let retryAfter: TimeInterval = 3 * 86_400

    /// Smallest gap between requests to one service.
    private static let spacing: [String: TimeInterval] = [
        "en.wikipedia.org": 0.35,
        "www.wikidata.org": 0.35,
        "api.tvmaze.com": 0.6,
        "www.omdbapi.com": 0.3,
    ]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    private static func directory(_ name: String, in base: FileManager.SearchPathDirectory) -> URL {
        let dir = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var cacheDirectory: URL { directory("Metadata", in: .cachesDirectory) }
    private static var artworkDirectory: URL { directory("Artwork", in: .cachesDirectory) }
    private static var overridesFile: URL { directory("", in: .applicationSupportDirectory).appendingPathComponent("title-overrides.json") }

    private static func hash(_ s: String) -> String {
        String(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    static func key(_ t: MediaTitle) -> String {
        "\(TitleMatch.normalize(t.title))|\(t.year ?? 0)|\(t.season ?? 0)|\(t.episode ?? 0)"
    }

    // MARK: Titles

    /// What the file is about: the title the person corrected by hand, else what the file name says.
    func title(for url: URL) -> MediaTitle {
        loadOverrides()
        return overrides[url.path] ?? MediaTitle.parse(fileName: url.deletingPathExtension().lastPathComponent)
    }

    /// Remembers a corrected title for a file (nil goes back to the file name).
    func setTitle(_ title: MediaTitle?, for url: URL) {
        loadOverrides()
        overrides[url.path] = title
        if let data = try? JSONEncoder().encode(overrides) { try? data.write(to: Self.overridesFile, options: .atomic) }
    }

    private func loadOverrides() {
        guard !overridesLoaded else { return }
        overridesLoaded = true
        if let data = try? Data(contentsOf: Self.overridesFile),
           let stored = try? JSONDecoder().decode([String: MediaTitle].self, from: data) {
            overrides = stored
        }
    }

    // MARK: Details

    /// Details already on disk or in memory, without going online.
    func cached(for url: URL) -> MovieDetails? {
        entry(for: Self.key(title(for: url)))?.details
    }

    func details(for url: URL) async -> MovieDetails? {
        await details(for: title(for: url))
    }

    /// Details for a title, from the cache or the services. `refresh` asks again even when an
    /// answer is cached.
    func details(for title: MediaTitle, refresh: Bool = false) async -> MovieDetails? {
        let key = Self.key(title)
        if !refresh, let e = entry(for: key) {
            if e.details != nil || Date().timeIntervalSince(e.fetched) < Self.retryAfter { return e.details }
        }
        guard Self.isEnabled else { return nil }
        if let running = inFlight[key] {
            if case .found(let d) = await running.value { return d }
            return nil
        }
        let task = Task { await self.lookup(title) }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        switch outcome {
        case .found(let d):
            store(Entry(details: d, fetched: Date()), for: key)
            return d
        case .none:
            store(Entry(details: nil, fetched: Date()), for: key)
            return nil
        case .failed:
            return nil
        }
    }

    private func entry(for key: String) -> Entry? {
        if let e = memory[key] { return e }
        let file = Self.cacheDirectory.appendingPathComponent(Self.hash(key) + ".json")
        guard let data = try? Data(contentsOf: file), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        memory[key] = e
        return e
    }

    private func store(_ entry: Entry, for key: String) {
        memory[key] = entry
        let file = Self.cacheDirectory.appendingPathComponent(Self.hash(key) + ".json")
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file, options: .atomic) }
    }

    private func lookup(_ t: MediaTitle) async -> Outcome {
        var failed = false
        if !OMDbClient.activeKey.isEmpty {
            switch await omdb(t) {
            case .found(let d): return .found(d)
            case .failed: failed = true
            case .none: break
            }
        }
        if t.isEpisode {
            switch await tvmaze(t) {
            case .found(let d): return .found(d)
            case .failed: return .failed
            case .none: return failed ? .failed : .none
            }
        }
        var fromWikipedia: MovieDetails?
        switch await wikipedia(t) {
        case .found(let d):
            // A show found on Wikipedia is better served by TVmaze (rating, episodes), with
            // Wikipedia's people kept if TVmaze has none.
            if d.showTitle == nil { return .found(d) }
            fromWikipedia = d
        case .failed: failed = true
        case .none: break
        }
        // A title without episode markers can still be a show ("Planet Earth").
        switch await tvmaze(t) {
        case .found(var d):
            if let w = fromWikipedia {
                if d.cast.isEmpty { d.cast = w.cast }
                if d.directors.isEmpty { d.directors = w.directors }
                if d.writers.isEmpty { d.writers = w.writers }
            }
            return .found(d)
        case .failed: return fromWikipedia.map { .found($0) } ?? .failed
        case .none: return fromWikipedia.map { .found($0) } ?? (failed ? .failed : .none)
        }
    }

    // MARK: Services

    private func omdb(_ t: MediaTitle) async -> Outcome {
        let key = OMDbClient.activeKey
        if t.isEpisode {
            guard let showURL = OMDbClient.url(title: t.title, year: nil, type: "series", key: key) else { return .none }
            guard case .data(let showData) = await fetch(showURL) else { return .failed }
            guard var show = OMDbClient.parse(showData, wanted: t) else { return .none }
            if let episodeURL = OMDbClient.episodeURL(title: show.title, season: t.season ?? 1, episode: t.episode ?? 1, key: key),
               case .data(let episodeData) = await fetch(episodeURL) {
                show = OMDbClient.parseEpisode(episodeData, into: show)
            }
            show.season = show.season ?? t.season
            show.episode = show.episode ?? t.episode
            return .found(show)
        }
        guard let url = OMDbClient.url(title: t.title, year: t.year, type: "movie", key: key) else { return .none }
        switch await fetch(url) {
        case .data(let data):
            if let d = OMDbClient.parse(data, wanted: t) { return .found(d) }
            return .none
        case .notFound: return .none
        case .failed: return .failed
        }
    }

    /// Wikipedia's article for the film (poster, plot), then its Wikidata entry (people,
    /// genres, running time, IMDb link). Four small requests, all cached afterwards.
    private func wikipedia(_ t: MediaTitle) async -> Outcome {
        guard let searchURL = Wikipedia.searchURL(t) else { return .none }
        let page: String
        switch await fetch(searchURL) {
        case .failed: return .failed
        case .notFound: return .none
        case .data(let data):
            guard let found = Wikipedia.pickPage(data, wanted: t) else { return .none }
            page = found
        }
        guard let summaryURL = Wikipedia.summaryURL(pageTitle: page) else { return .none }
        var details: MovieDetails
        var qid: String?
        switch await fetch(summaryURL) {
        case .failed: return .failed
        case .notFound: return .none
        case .data(let data):
            guard let parsed = Wikipedia.parseSummary(data, wanted: t) else { return .none }
            details = parsed.details
            qid = parsed.qid
        }
        if let qid, let entityURL = Wikidata.entityURL(qid), case .data(let entityData) = await fetch(entityURL) {
            let claims = Wikidata.parseEntity(entityData, qid: qid)
            var labels: [String: String] = [:]
            let ids = claims.labelIDs
            if !ids.isEmpty, let labelsURL = Wikidata.labelsURL(ids), case .data(let labelData) = await fetch(labelsURL) {
                labels = Wikidata.parseLabels(labelData)
            }
            details = Wikidata.apply(claims, labels: labels, to: details)
        }
        return .found(details)
    }

    private func tvmaze(_ t: MediaTitle) async -> Outcome {
        guard let url = TVmaze.showURL(t.title) else { return .none }
        switch await fetch(url) {
        case .failed: return .failed
        case .notFound: return .none
        case .data(let data):
            guard let (show, id) = TVmaze.parseShow(data, wanted: t) else { return .none }
            guard let episode = t.episode, let episodeURL = TVmaze.episodeURL(showID: id, season: t.season ?? 1, episode: episode) else {
                return .found(show)
            }
            if case .data(let episodeData) = await fetch(episodeURL) {
                return .found(TVmaze.parseEpisode(episodeData, into: show))
            }
            var withNumbers = show
            withNumbers.season = t.season
            withNumbers.episode = episode
            return .found(withNumbers)
        }
    }

    /// One request, paced per service. 404 means "nothing there", any other trouble "failed".
    private func fetch(_ url: URL, accept: String = "application/json") async -> Fetched {
        let host = url.host ?? ""
        let gap = Self.spacing[host] ?? 0.5
        let now = Date()
        let slot = max(now, (nextAllowed[host] ?? .distantPast))
        nextAllowed[host] = slot.addingTimeInterval(gap)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        var request = URLRequest(url: url)
        request.setValue("Driftcast/\(AppVersion.installed) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        if http.statusCode == 404 { return .notFound }
        guard (200...299).contains(http.statusCode) else { return .failed }
        return .data(data)
    }

    // MARK: Artwork

    /// The image at `url`, from the cache or downloaded (unless `allowNetwork` is false).
    func artwork(_ url: URL, allowNetwork: Bool = true) async -> Data? {
        if let d = artworkMemory[url] { return d }
        let file = Self.artworkDirectory.appendingPathComponent(Self.hash(url.absoluteString) + ".img")
        if let d = try? Data(contentsOf: file) {
            remember(d, for: url)
            return d
        }
        guard allowNetwork, Self.isEnabled, case .data(let d) = await fetch(url, accept: "image/*"), !d.isEmpty else { return nil }
        try? d.write(to: file, options: .atomic)
        remember(d, for: url)
        return d
    }

    private func remember(_ data: Data, for url: URL) {
        artworkMemory[url] = data
        artworkOrder.append(url)
        if artworkOrder.count > 60 { artworkMemory[artworkOrder.removeFirst()] = nil }
    }

    // MARK: With a deadline

    /// `details(for:)` that gives up waiting after `seconds`, for a video that is about to play.
    /// The lookup itself carries on and lands in the cache for the playlist row and next time.
    nonisolated func details(for url: URL, within seconds: Double) async -> MovieDetails? {
        await Deadline.first(within: seconds) { await self.details(for: url) }
    }

    /// `artwork(_:)` that gives up waiting after `seconds`; the download carries on regardless.
    nonisolated func artwork(_ url: URL, within seconds: Double) async -> Data? {
        await Deadline.first(within: seconds) { await self.artwork(url) }
    }
}

/// Runs work that must not be cancelled (its result is cached for later) but that a caller
/// will only wait so long for.
enum Deadline {
    static func first<T: Sendable>(within seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task {
                let value = await operation()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Lets exactly one of two racing tasks deliver the answer.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// Decides whether a search result is the title the file name describes.
enum TitleMatch {
    /// Lower case, no accents or punctuation, no leading article.
    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        var words = t.split(separator: " ").map(String.init)
        if let first = words.first, ["the", "a", "an"].contains(first), words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// 0 for no match; higher is better. A year that is known on both sides must agree
    /// (give or take one, for festival releases).
    static func score(candidate: String, year: Int?, wanted: MediaTitle) -> Int {
        let a = normalize(candidate), b = normalize(wanted.title)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var score: Int
        if a == b {
            score = 3
        } else if a.hasPrefix(b + " ") || b.hasPrefix(a + " ") || a.contains(" " + b) || a.contains(b + " ") {
            score = 1
        } else {
            return 0
        }
        if let y = year, let w = wanted.year {
            if abs(y - w) <= 1 { score += 2 } else { return 0 }
        }
        return score
    }
}

/// Wikipedia: the article about a film gives its poster and lead paragraph, and names the
/// Wikidata entry that holds the facts. No key is needed; the text is CC BY-SA, so the details
/// panel links back to the article.
enum Wikipedia {
    static func searchURL(_ t: MediaTitle) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        let words = t.year.map { "\(t.title) \($0) film" } ?? "\(t.title) film"
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: words), URLQueryItem(name: "srlimit", value: "8"),
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "utf8", value: "1"),
        ]
        return components?.url
    }

    static func summaryURL(pageTitle: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let encoded = pageTitle.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
    }

    /// "Heat (1995 film)" -> ("Heat", 1995, true).
    static func split(_ pageTitle: String) -> (base: String, year: Int?, suffix: String) {
        guard let open = pageTitle.lastIndex(of: "("), pageTitle.hasSuffix(")") else { return (pageTitle, nil, "") }
        let base = String(pageTitle[..<open]).trimmingCharacters(in: .whitespaces)
        let suffix = String(pageTitle[pageTitle.index(after: open)...].dropLast()).lowercased()
        let year = suffix.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression).flatMap { Int(suffix[$0]) }
        return (base, year, suffix)
    }

    private static let notFilms = ["disambiguation", "soundtrack", "novel", "song", "album", "video game", "character", "band", "comics", "play", "musical", "book", "magazine", "company"]

    /// The search result that is the wanted title, as a page title, or nil.
    static func pickPage(_ data: Data, wanted: MediaTitle) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = (root["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return nil }
        var best: (String, Int)?
        for r in results {
            guard let title = r["title"] as? String else { continue }
            let parts = split(title)
            if notFilms.contains(where: { parts.suffix.contains($0) }) { continue }
            // Article titles are canonical, so only the same title counts: "Heat 2" or "In the
            // Heat of the Night" must not stand in for "Heat".
            var score = TitleMatch.score(candidate: parts.base, year: parts.year, wanted: wanted)
            guard score >= 3 else { continue }
            if parts.suffix.contains("film") || parts.suffix.contains("series") || parts.suffix.contains("miniseries") { score += 1 }
            if score > (best?.1 ?? 0) { best = (title, score) }
        }
        return best?.0
    }

    private static let filmWords = ["film", "movie", "television", "tv series", "miniseries", "documentary", "anime", "series", "special"]

    /// The article's summary as details, when it is about a film or show that fits the title.
    static func parseSummary(_ data: Data, wanted: MediaTitle) -> (details: MovieDetails, qid: String?)? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (r["type"] as? String) == "standard", let pageTitle = r["title"] as? String else { return nil }
        let description = (r["description"] as? String ?? "").lowercased()
        let extract = r["extract"] as? String ?? ""
        guard filmWords.contains(where: { description.contains($0) }) || extract.lowercased().prefix(200).contains(" film") else { return nil }
        let parts = split(pageTitle)
        func year(in text: String) -> Int? {
            text.range(of: #"\b(19[2-9]\d|20\d\d)\b"#, options: .regularExpression).flatMap { Int(text[$0]) }
        }
        let foundYear = parts.year ?? year(in: description) ?? year(in: String(extract.prefix(300)))
        guard TitleMatch.score(candidate: parts.base, year: foundYear, wanted: wanted) > 0 else { return nil }
        var d = MovieDetails(title: parts.base, source: "Wikipedia")
        d.year = foundYear
        d.synopsis = extract.isEmpty ? nil : extract
        let original = r["originalimage"] as? [String: Any]
        let thumbnail = r["thumbnail"] as? [String: Any]
        let image = ((original?["width"] as? Int ?? 0) <= 1200 ? original : nil) ?? thumbnail
        d.posterURL = (image?["source"] as? String).flatMap(URL.init)
        d.link = ((r["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"].flatMap { $0 as? String }.flatMap(URL.init)
        if description.contains("series") || description.contains("television") { d.showTitle = parts.base }
        // "1995 crime drama film by Michael Mann": the director, until Wikidata says more.
        if let by = description.range(of: " by ") {
            let name = String(description[by.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !name.contains(" and "), d.showTitle == nil {
                d.directors = [name.capitalized]
            }
        }
        return (d, r["wikibase_item"] as? String)
    }
}

/// Wikidata: the structured facts behind a Wikipedia article.
enum Wikidata {
    struct Claims {
        var directors: [String] = []
        var writers: [String] = []
        var cast: [String] = []
        var genres: [String] = []
        var certificate: String?
        var durationMinutes: Int?
        var year: Int?
        var imdbID: String?
        var isSeries = false
        var ratings: [MovieDetails.Rating] = []

        /// Every entity whose English label is needed.
        var labelIDs: [String] {
            var ids = directors + writers + cast + genres
            if let certificate { ids.append(certificate) }
            return Array(NSOrderedSet(array: ids)) as? [String] ?? ids
        }
    }

    static func entityURL(_ qid: String) -> URL? {
        URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json")
    }

    static func labelsURL(_ ids: [String]) -> URL? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbgetentities"), URLQueryItem(name: "ids", value: ids.prefix(50).joined(separator: "|")),
            // Names that are the same in every language now live under "mul", not "en".
            URLQueryItem(name: "props", value: "labels"), URLQueryItem(name: "languages", value: "en|mul"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    static func parseEntity(_ data: Data, qid: String) -> Claims {
        var c = Claims()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entity = (root["entities"] as? [String: Any])?[qid] as? [String: Any],
              let claims = entity["claims"] as? [String: Any] else { return c }
        func statements(_ property: String) -> [[String: Any]] { claims[property] as? [[String: Any]] ?? [] }
        func value(_ statement: [String: Any]) -> Any? {
            ((statement["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
        }
        func items(_ property: String) -> [String] {
            statements(property).compactMap { (value($0) as? [String: Any])?["id"] as? String }
        }
        // Cast in billing order where Wikidata records it (series ordinal), else as listed.
        let castStatements = statements("P161")
        func ordinal(_ statement: [String: Any]) -> Int {
            let q = ((statement["qualifiers"] as? [String: Any])?["P1545"] as? [[String: Any]])?.first
            return Int(((q?["datavalue"] as? [String: Any])?["value"] as? String) ?? "") ?? Int.max
        }
        c.cast = castStatements.sorted { ordinal($0) < ordinal($1) }.compactMap { (value($0) as? [String: Any])?["id"] as? String }.prefix(8).map { $0 }
        c.directors = items("P57")
        c.writers = Array(items("P58").prefix(4))
        c.genres = Array(items("P136").prefix(4))
        c.certificate = items("P1657").first
        c.isSeries = items("P31").contains { ["Q5398426", "Q1259759", "Q15416", "Q117467246"].contains($0) }
        c.durationMinutes = statements("P2047").compactMap { statement -> Int? in
            guard let v = value(statement) as? [String: Any], let amount = v["amount"] as? String else { return nil }
            let unit = v["unit"] as? String ?? ""
            guard let n = Double(amount) else { return nil }
            return unit.hasSuffix("Q7727") ? Int(n.rounded()) : (unit.hasSuffix("Q11574") ? Int((n / 60).rounded()) : nil)
        }.first
        c.year = statements("P577").compactMap { statement -> Int? in
            guard let v = value(statement) as? [String: Any], let time = v["time"] as? String else { return nil }
            return Int(time.dropFirst().prefix(4))
        }.min()
        c.imdbID = statements("P345").compactMap { value($0) as? String }.first
        // Review scores (P444) and who gave them (P447). Rotten Tomatoes records both its
        // percentage and an average mark; the percentage is the one people know.
        let reviewers = ["Q37312": "IMDb", "Q105584": "Rotten Tomatoes", "Q150248": "Metacritic"]
        var scores: [String: String] = [:]
        for statement in statements("P444") {
            guard (statement["rank"] as? String) != "deprecated", let score = value(statement) as? String,
                  let qualifier = ((statement["qualifiers"] as? [String: Any])?["P447"] as? [[String: Any]])?.first,
                  let id = ((qualifier["datavalue"] as? [String: Any])?["value"] as? [String: Any])?["id"] as? String,
                  let name = reviewers[id] else { continue }
            if let existing = scores[name] {
                let better = (score.hasSuffix("%") && !existing.hasSuffix("%")) || (statement["rank"] as? String) == "preferred"
                if better { scores[name] = score }
            } else {
                scores[name] = score
            }
        }
        c.ratings = ["IMDb", "Rotten Tomatoes", "Metacritic"].compactMap { name in scores[name].map { MovieDetails.Rating(source: name, value: $0) } }
        return c
    }

    static func parseLabels(_ data: Data) -> [String: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entities = root["entities"] as? [String: Any] else { return [:] }
        var labels: [String: String] = [:]
        for (id, entity) in entities {
            guard let byLanguage = (entity as? [String: Any])?["labels"] as? [String: Any] else { continue }
            let preferred = (byLanguage["en"] ?? byLanguage["mul"] ?? byLanguage.values.first) as? [String: Any]
            if let label = preferred?["value"] as? String { labels[id] = label }
        }
        return labels
    }

    static func apply(_ c: Claims, labels: [String: String], to details: MovieDetails) -> MovieDetails {
        var d = details
        func names(_ ids: [String]) -> [String] { ids.compactMap { labels[$0] } }
        // The director read from the article's description stands when Wikidata has no name.
        let directors = names(c.directors)
        if !directors.isEmpty { d.directors = directors }
        d.writers = names(c.writers)
        d.cast = names(c.cast)
        if !c.genres.isEmpty { d.genres = names(c.genres).map { $0.replacingOccurrences(of: " film", with: "").capitalized } }
        if let certificate = c.certificate, let label = labels[certificate] { d.certificate = label }
        if let minutes = c.durationMinutes, minutes > 0 { d.runtimeMinutes = minutes }
        if d.year == nil { d.year = c.year }
        if let imdb = c.imdbID { d.link = URL(string: "https://www.imdb.com/title/\(imdb)/") }
        if c.isSeries, d.showTitle == nil { d.showTitle = d.title }
        if d.ratings.isEmpty { d.ratings = c.ratings }
        return d
    }
}

/// TVmaze: shows and episodes with poster, rating, network, genres and synopses. No key is
/// needed; TVmaze asks only for a link back, which the details view shows.
enum TVmaze {
    static func showURL(_ name: String) -> URL? {
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")
        components?.queryItems = [URLQueryItem(name: "q", value: name)]
        return components?.url
    }

    static func episodeURL(showID: Int, season: Int, episode: Int) -> URL? {
        URL(string: "https://api.tvmaze.com/shows/\(showID)/episodebynumber?season=\(season)&number=\(episode)")
    }

    static func parseShow(_ data: Data, wanted: MediaTitle) -> (MovieDetails, Int)? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = r["id"] as? Int, let name = r["name"] as? String else { return nil }
        let year = (r["premiered"] as? String).flatMap { Int($0.prefix(4)) }
        // A show's episodes carry no year in their names, so the premiere year is not held
        // against them.
        guard TitleMatch.score(candidate: name, year: wanted.isEpisode ? nil : year, wanted: wanted) > 0 else { return nil }
        var d = MovieDetails(title: name, source: "TVmaze")
        d.showTitle = name
        d.year = year
        d.genres = r["genres"] as? [String] ?? []
        if let average = (r["rating"] as? [String: Any])?["average"] as? Double {
            d.ratings = [MovieDetails.Rating(source: "TVmaze", value: String(format: "%.1f/10", average))]
        }
        d.network = ((r["network"] as? [String: Any]) ?? (r["webChannel"] as? [String: Any]))?["name"] as? String
        d.synopsis = (r["summary"] as? String).map(stripHTML)
        d.posterURL = imageURL(r["image"])
        d.link = (r["url"] as? String).flatMap(URL.init)
        d.runtimeMinutes = (r["averageRuntime"] as? Int) ?? (r["runtime"] as? Int)
        return (d, id)
    }

    static func parseEpisode(_ data: Data, into show: MovieDetails) -> MovieDetails {
        var d = show
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return d }
        d.season = r["season"] as? Int
        d.episode = r["number"] as? Int
        d.episodeTitle = r["name"] as? String
        d.airDate = r["airdate"] as? String
        d.episodeSynopsis = (r["summary"] as? String).map(stripHTML)
        d.episodeImageURL = imageURL(r["image"])
        if let runtime = r["runtime"] as? Int { d.runtimeMinutes = runtime }
        return d
    }

    private static func imageURL(_ value: Any?) -> URL? {
        guard let image = value as? [String: Any] else { return nil }
        return ((image["original"] as? String) ?? (image["medium"] as? String)).flatMap(URL.init)
    }

    /// TVmaze summaries are HTML paragraphs.
    static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"</p>\s*<p>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// OMDb (omdbapi.com): IMDb, Rotten Tomatoes and Metacritic ratings, writers and cast. Needs a
/// free key; the app can ship one in `builtInKey`, and a person can enter their own in Settings.
enum OMDbClient {
    /// Driftcast's own key, shipped with the app. Empty until one is registered.
    static let builtInKey = ""
    static let keyPage = URL(string: "https://www.omdbapi.com/apikey.aspx")!

    static var activeKey: String {
        let own = Prefs.string(Prefs.omdbKey).trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? builtInKey : own
    }

    static func url(title: String, year: Int?, type: String?, key: String) -> URL? {
        var items = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "t", value: title), URLQueryItem(name: "plot", value: "full")]
        if let year { items.append(URLQueryItem(name: "y", value: "\(year)")) }
        if let type { items.append(URLQueryItem(name: "type", value: type)) }
        var components = URLComponents(string: "https://www.omdbapi.com/")
        components?.queryItems = items
        return components?.url
    }

    static func episodeURL(title: String, season: Int, episode: Int, key: String) -> URL? {
        var components = URLComponents(string: "https://www.omdbapi.com/")
        components?.queryItems = [
            URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "t", value: title),
            URLQueryItem(name: "Season", value: "\(season)"), URLQueryItem(name: "Episode", value: "\(episode)"),
            URLQueryItem(name: "plot", value: "full"),
        ]
        return components?.url
    }

    /// OMDb writes "N/A" for anything it doesn't know.
    private static func clean(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s != "N/A" else { return nil }
        return s
    }

    private static func list(_ value: Any?) -> [String] {
        clean(value).map(People.split) ?? []
    }

    static func parse(_ data: Data, wanted: MediaTitle) -> MovieDetails? {
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (r["Response"] as? String) == "True", let title = clean(r["Title"]) else { return nil }
        let year = clean(r["Year"]).flatMap { Int($0.prefix(4)) }
        guard TitleMatch.score(candidate: title, year: wanted.isEpisode ? nil : year, wanted: wanted) > 0 else { return nil }
        var d = MovieDetails(title: title, source: "OMDb")
        d.year = year
        d.certificate = clean(r["Rated"]).flatMap { ["Not Rated", "Unrated"].contains($0) ? nil : $0 }
        d.runtimeMinutes = clean(r["Runtime"]).flatMap { Int($0.replacingOccurrences(of: " min", with: "")) }
        d.genres = list(r["Genre"])
        d.directors = list(r["Director"])
        d.writers = list(r["Writer"]).map { $0.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression) }
        d.cast = list(r["Actors"])
        d.synopsis = clean(r["Plot"])
        d.posterURL = clean(r["Poster"]).flatMap(URL.init)
        d.ratings = (r["Ratings"] as? [[String: Any]])?.compactMap { entry in
            guard let source = entry["Source"] as? String, let value = entry["Value"] as? String else { return nil }
            return MovieDetails.Rating(source: source == "Internet Movie Database" ? "IMDb" : source, value: value)
        } ?? []
        if let id = clean(r["imdbID"]) { d.link = URL(string: "https://www.imdb.com/title/\(id)/") }
        if (r["Type"] as? String) == "series" { d.showTitle = title }
        return d
    }

    static func parseEpisode(_ data: Data, into show: MovieDetails) -> MovieDetails {
        var d = show
        guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (r["Response"] as? String) == "True" else { return d }
        d.episodeTitle = clean(r["Title"])
        d.episodeSynopsis = clean(r["Plot"])
        d.airDate = clean(r["Released"])
        d.season = clean(r["Season"]).flatMap { Int($0) }
        d.episode = clean(r["Episode"]).flatMap { Int($0) }
        if let rating = clean(r["imdbRating"]) { d.ratings.append(MovieDetails.Rating(source: "IMDb (episode)", value: "\(rating)/10")) }
        if d.posterURL == nil { d.posterURL = clean(r["Poster"]).flatMap(URL.init) }
        return d
    }
}

enum People {
    /// "Michael Mann, Jon Voight" -> ["Michael Mann", "Jon Voight"].
    static func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
