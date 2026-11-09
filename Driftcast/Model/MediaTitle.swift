import Foundation

/// What a file name says about the film or episode in it: "Heat.1995.1080p.BluRay.x264" is
/// Heat from 1995, "Sopranos.S1.E11.dolby" is Sopranos, season 1, episode 11. Used to search
/// film databases and OpenSubtitles.
struct MediaTitle: Equatable, Hashable, Sendable, Codable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?

    var isEpisode: Bool { episode != nil }

    /// The words to search a database with ("Heat 1995", "Sopranos").
    var searchQuery: String { year.map { "\(title) \($0)" } ?? title }

    /// "Season 1, Episode 11" / "Episode 11".
    var episodeLabel: String? {
        guard let episode else { return nil }
        if let season { return "Season \(season), Episode \(episode)" }
        return "Episode \(episode)"
    }

    private static let episodeMarkers: [NSRegularExpression] = [
        #"\bS(\d{1,2})\s*[-x]?\s*E(\d{1,3})\b"#,
        #"\b(\d{1,2})x(\d{2,3})\b"#,
        #"\bSeason\s*(\d{1,2})\b.*?\b(?:Episode|Ep|E)\s*(\d{1,3})\b"#,
        #"\b(?:Episode|Ep)\s*#?(\d{1,4})\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let yearPattern = try! NSRegularExpression(pattern: #"\b(19[2-9]\d|20\d\d)\b"#)

    /// Words that end a film's title in release names. Compared as whole words.
    static let releaseTags: Set<String> = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "bluray", "blu-ray", "bdrip", "brrip",
        "bdremux", "remux", "web-dl", "webdl", "webrip", "hdtv", "hdrip", "dvdrip", "dvdscr", "x264", "x265",
        "h264", "h265", "h.264", "h.265", "hevc", "avc", "av1", "xvid", "divx", "hdr", "hdr10", "hdr10+", "dolby",
        "atmos", "aac", "aac2", "ac3", "dd5", "ddp", "ddp5", "dts", "dts-hd", "truehd", "eac3", "flac", "multi",
        "proper", "repack", "internal", "limited", "extended", "unrated", "remastered", "amzn", "nf", "hmax",
        "dsnp", "atvp", "10bit", "8bit", "hybrid", "criterion", "sdr", "dv",
    ]

    static func parse(fileName: String) -> MediaTitle {
        let s = SeriesName.normalize(fileName)
        let whole = NSRange(s.startIndex..., in: s)

        for marker in episodeMarkers {
            guard let m = marker.firstMatch(in: s, range: whole), m.range.location > 0,
                  let range = Range(m.range, in: s) else { continue }
            func number(_ i: Int) -> Int? { Range(m.range(at: i), in: s).flatMap { Int(s[$0]) } }
            let season = m.numberOfRanges == 3 ? number(1) : nil
            let episode = m.numberOfRanges == 3 ? number(2) : number(1)
            let head = String(s[..<range.lowerBound])
            let title = tidy(cutAtReleaseTag(head)) ?? tidy(head) ?? head
            return MediaTitle(title: title, year: nil, season: season, episode: episode)
        }

        // A film: the title ends at the year, else at the first release tag. A year at the very
        // start ("2001 A Space Odyssey 1968") is part of the title.
        if let m = yearPattern.matches(in: s, range: whole).first(where: { $0.range.location > 0 }),
           let range = Range(m.range, in: s), let year = Int(s[range]) {
            let head = String(s[..<range.lowerBound])
            if let title = tidy(cutAtReleaseTag(head)) ?? tidy(head) {
                return MediaTitle(title: title, year: year)
            }
        }
        return MediaTitle(title: tidy(cutAtReleaseTag(s)) ?? tidy(s) ?? s)
    }

    /// The words before the first release tag ("Heat 1080p BluRay" -> "Heat").
    static func cutAtReleaseTag(_ text: String) -> String {
        var kept: [Substring] = []
        for word in text.split(separator: " ") {
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[](){}-"))
            if releaseTags.contains(bare), !kept.isEmpty { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    private static func tidy(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,([{#"))
        t = t.split(separator: " ").joined(separator: " ")
        guard t.contains(where: \.isLetter) || t.contains(where: \.isNumber) else { return nil }
        return t == t.lowercased() ? t.capitalized : t
    }
}
