import Foundation

/// Works out which files in a batch belong to one show, so they can go into a playlist named
/// after it ("Sopranos.S1.E11.dolby.mp4", "Sopranos.S1.E12.dolby.mp4" -> "Sopranos").
enum SeriesName {
    struct Group: Equatable {
        var title: String
        /// Positions in the list of names that was passed in.
        var members: [Int]
    }

    /// Where the show's name ends and the episode starts: S01E02, S1 E11, 1x02, Season 1,
    /// Episode 3, Ep 3, E03, Part 2, and the " - 03" used by fan releases.
    private static let markers: [NSRegularExpression] = [
        #"\bS\d{1,2}\s*[-x]?\s*E\d{1,3}\b"#,
        #"\b\d{1,2}x\d{2,3}\b"#,
        #"\bSeason\s*\d{1,2}\b"#,
        #"\b(?:Episode|Ep|E|Part|Pt|Chapter|Volume|Vol|Disc|CD)\s*#?\d{1,4}\b"#,
        #"\s[-–]\s*\d{1,4}\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// File name (no extension) with dots and underscores as spaces and release-group tags
    /// such as "[Group]" removed from the front.
    static func normalize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        while let r = s.range(of: #"^\s*[\[\(][^\]\)]*[\]\)]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.split(separator: " ").joined(separator: " ")
    }

    private static func tidy(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–:,([{#"))
        guard trimmed.count >= 2, trimmed.contains(where: \.isLetter) else { return nil }
        // All-lowercase file names read better capitalised as a playlist name.
        return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
    }

    /// The show's name when the file name carries an episode marker, otherwise nil.
    static func title(fromFileName name: String) -> String? {
        let s = normalize(name)
        let whole = NSRange(s.startIndex..., in: s)
        let first = markers.compactMap { $0.firstMatch(in: s, range: whole)?.range.location }.min()
        guard let first, let end = Range(NSRange(location: 0, length: first), in: s) else { return nil }
        return tidy(String(s[end]))
    }

    /// For names without episode markers ("Lecture 01", "Lecture 02"): what they all start
    /// with, if that is most of the name rather than a shared "The".
    static func commonTitle(_ names: [String]) -> String? {
        let cleaned = names.map(normalize)
        guard cleaned.count >= 2, Set(cleaned.map { $0.lowercased() }).count >= 2, var prefix = cleaned.first else { return nil }
        for name in cleaned.dropFirst() {
            prefix = String(zip(prefix, name).prefix { $0.0.lowercased() == $0.1.lowercased() }.map(\.0))
        }
        // Don't stop in the middle of a word or a number.
        let cutsWord = cleaned.contains { name in
            guard name.count > prefix.count, let last = prefix.last else { return false }
            let next = name[name.index(name.startIndex, offsetBy: prefix.count)]
            return last.isLetter && next.isLetter
        }
        if cutsWord { prefix = prefix.split(separator: " ").dropLast().joined(separator: " ") }
        while let last = prefix.last, last.isNumber || " -–:,([{#".contains(last) { prefix.removeLast() }
        let shortest = cleaned.map(\.count).min() ?? 0
        guard prefix.count >= 4, prefix.count * 2 >= shortest else { return nil }
        return tidy(prefix)
    }

    /// Splits a batch of file names into shows (two or more files each) and everything else.
    static func group(_ names: [String]) -> (series: [Group], rest: [Int]) {
        var order: [String] = []
        var byKey: [String: Group] = [:]
        var unmarked: [Int] = []
        for (i, name) in names.enumerated() {
            guard let title = title(fromFileName: name) else { unmarked.append(i); continue }
            let key = title.lowercased()
            if byKey[key] == nil { order.append(key); byKey[key] = Group(title: title, members: []) }
            byKey[key]?.members.append(i)
        }
        var series: [Group] = []
        var rest: [Int] = []
        for key in order {
            guard let g = byKey[key] else { continue }
            if g.members.count >= 2 { series.append(g) } else { rest += g.members }
        }
        if let title = commonTitle(unmarked.map { names[$0] }) {
            series.append(Group(title: title, members: unmarked))
        } else {
            rest += unmarked
        }
        return (series, rest.sorted())
    }
}
