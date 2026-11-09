import Foundation

/// Where new versions of Driftcast are published.
enum UpdateConfig {
    /// The GitHub repository whose releases are the app's updates, as "owner/name".
    /// With no repository the app never checks and shows no update controls.
    static let repository = "leechsoftware/driftcast"

    /// How often a running copy looks again, after the check at launch.
    static let checkInterval: TimeInterval = 8 * 3_600

    /// The repository if it is a plausible "owner/name", otherwise nil.
    static var repositoryPath: String? { validated(repository) }
    static var isConfigured: Bool { repositoryPath != nil }

    static func validated(_ repository: String) -> String? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        return repository
    }
}

/// A published version: what the update dialog offers.
struct AppRelease: Equatable, Sendable {
    var version: String
    /// The release's page on GitHub.
    var page: URL
    /// The app's zip or disk image attached to the release, when there is one.
    var download: URL?
}

enum AppVersion {
    static var installed: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// "v1.2.0" -> [1, 2, 0]. Anything after the leading digits and dots ("-beta") is ignored.
    static func components(_ text: String) -> [Int] {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if let first = s.first, first == "v" || first == "V" { s = s.dropFirst() }
        let numeric = s.prefix { $0.isNumber || $0 == "." }
        return numeric.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// The tag's version as shown to people: "v1.2" -> "1.2".
    static func display(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespaces)
        if let first = t.first, first == "v" || first == "V", t.dropFirst().first?.isNumber == true {
            return String(t.dropFirst())
        }
        return t
    }

    /// Compares number by number, so 1.10 is newer than 1.9 and 1.2 equals 1.2.0.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = components(candidate), b = components(installed)
        guard !a.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The newest release of a GitHub repository, from GitHub's public API. No account or key is
/// needed; the limit is 60 requests an hour per network address, and the app asks once at
/// launch and then every eight hours.
enum GitHubReleases {
    enum Outcome: Equatable {
        case release(AppRelease)
        /// The repository has published no release yet.
        case none
        /// No connection, a rate limit, or an answer that couldn't be read.
        case failed
    }

    static func latestURL(repository: String) -> URL? {
        guard let path = UpdateConfig.validated(repository) else { return nil }
        return URL(string: "https://api.github.com/repos/\(path)/releases/latest")
    }

    static func latest(repository: String) async -> Outcome {
        guard let url = latestURL(repository: repository) else { return .failed }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Driftcast/\(AppVersion.installed)", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        do {
            let (data, response) = try await URLSession(configuration: config).data(for: request)
            return parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .failed
        }
    }

    /// The reading half of `latest`, separate so it can be tested against canned answers.
    static func parse(data: Data, status: Int) -> Outcome {
        if status == 404 { return .none }
        guard (200...299).contains(status),
              let decoded = try? JSONDecoder().decode(Release.self, from: data),
              decoded.draft != true, decoded.prerelease != true,
              let tag = decoded.tag_name, !AppVersion.components(tag).isEmpty,
              let page = secureURL(decoded.html_url) else { return .failed }
        let assets = decoded.assets ?? []
        let file = assets.first { $0.name?.lowercased().hasSuffix(".zip") == true }
            ?? assets.first { $0.name?.lowercased().hasSuffix(".dmg") == true }
        return .release(AppRelease(version: AppVersion.display(tag), page: page,
                                   download: secureURL(file?.browser_download_url)))
    }

    /// Only https links to GitHub are opened on the user's behalf.
    private static func secureURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), host == "github.com" || host.hasSuffix(".github.com") else { return nil }
        return url
    }

    private struct Release: Decodable {
        var tag_name: String?
        var html_url: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]?

        struct Asset: Decodable {
            var name: String?
            var browser_download_url: String?
        }
    }
}
