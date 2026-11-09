import AppKit
import Foundation

struct MediaItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    /// Subtitle files the user attached or downloaded (beyond ones found next to the video).
    var extraSubtitles: [URL] = []

    var title: String { url.deletingPathExtension().lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    init(url: URL) { self.url = url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        extraSubtitles = try c.decodeIfPresent([URL].self, forKey: .extraSubtitles) ?? []
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var items: [MediaItem] = []
}

struct WatchProgress: Codable, Hashable {
    var position: Double
    var duration: Double
    var updated: Date

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
}

/// Playlists plus last-position tracking, persisted as JSON in Application Support.
@MainActor
final class Library: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var selection: Playlist.ID? { didSet { if oldValue != selection { save() } } }
    @Published var progress: [String: WatchProgress] = [:]
    /// Files the user has finished, so rows can show a "watched" mark.
    @Published var watched: Set<String> = []

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "mpg", "mpeg",
        "vob", "ogv", "ogm", "3gp", "3g2", "divx", "asf", "rm", "rmvb", "f4v", "mxf", "dv", "y4m", "hevc",
        "h264", "mk3d", "trp", "tp", "wtv", "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus",
    ]

    private struct Stored: Codable {
        var playlists: [Playlist]
        var progress: [String: WatchProgress]
        var watched: [String]?
        var selection: UUID?
    }

    private var saveWork: DispatchWorkItem?

    init() {
        load()
        if playlists.isEmpty { playlists = [Playlist(name: "Playlist")] }
        if selection == nil || !playlists.contains(where: { $0.id == selection }) { selection = playlists.first?.id }
    }

    var selectedPlaylist: Playlist? { playlists.first { $0.id == selection } }

    // MARK: Persistence

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Driftcast", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // Kept aside rather than overwritten by the empty library this run starts with.
            let aside = Self.storeURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: Self.storeURL, to: aside)
            return
        }
        playlists = stored.playlists
        progress = stored.progress
        watched = Set(stored.watched ?? [])
        selection = stored.selection
    }

    /// Coalesces bursts of changes into one write.
    func save() {
        saveWork?.cancel()
        let snapshot = Stored(playlists: playlists, progress: progress, watched: Array(watched), selection: selection)
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.storeURL, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes immediately. Used when quitting, where the delayed write in `save()` would never
    /// run and the last resume position or playlist edit would be lost.
    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = Stored(playlists: playlists, progress: progress, watched: Array(watched), selection: selection)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.storeURL, options: .atomic) }
    }

    // MARK: Playlists

    @discardableResult
    func newPlaylist(named name: String? = nil) -> Playlist.ID {
        let base = name ?? "Playlist"
        var candidate = base
        var n = 2
        while playlists.contains(where: { $0.name == candidate }) { candidate = "\(base) \(n)"; n += 1 }
        let p = Playlist(name: candidate)
        playlists.append(p)
        selection = p.id
        save()
        return p.id
    }

    func rename(_ id: Playlist.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = trimmed
        save()
    }

    func deletePlaylist(_ id: Playlist.ID) {
        guard playlists.count > 1 else { return }
        playlists.removeAll { $0.id == id }
        if selection == id { selection = playlists.first?.id }
        save()
    }

    // MARK: Items

    /// Expands folders recursively and keeps only media files, sorted the way Finder sorts.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var found: [URL] = []
                for case let f as URL in e where videoExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                out += found
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    /// Adds videos to a playlist. Two or more files from the same show (see `SeriesName`) go
    /// into a playlist named after the show instead, which is created if needed and selected.
    @discardableResult
    func add(_ urls: [URL], to playlistID: Playlist.ID? = nil) -> [MediaItem] {
        guard let id = playlistID ?? selection, playlists.contains(where: { $0.id == id }) else { return [] }
        let files = Self.expand(urls)
        let (series, rest) = SeriesName.group(files.map { $0.deletingPathExtension().lastPathComponent })
        var added: [MediaItem] = []
        var firstSeriesPlaylist: Playlist.ID?

        for (n, group) in series.enumerated() {
            let index: Int
            if let existing = playlists.firstIndex(where: { $0.name.compare(group.title, options: .caseInsensitive) == .orderedSame }) {
                index = existing
            } else if n == 0, series.count == 1, rest.isEmpty,
                      let target = playlists.firstIndex(where: { $0.id == id }),
                      playlists[target].items.isEmpty, Self.isDefaultName(playlists[target].name) {
                // An untouched empty playlist becomes the show's playlist rather than being left behind.
                playlists[target].name = group.title
                index = target
            } else {
                playlists.append(Playlist(name: group.title))
                index = playlists.count - 1
            }
            let present = Set(playlists[index].items.map(\.url))
            let episodes = group.members.map { files[$0] }
                .filter { !present.contains($0) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { MediaItem(url: $0) }
            playlists[index].items += episodes
            added += episodes
            if firstSeriesPlaylist == nil { firstSeriesPlaylist = playlists[index].id }
        }

        if !rest.isEmpty, let target = playlists.firstIndex(where: { $0.id == id }) {
            // A video that is already in the playlist (opened again from Finder, say) is not
            // listed twice.
            let present = Set(playlists[target].items.map(\.url))
            let items = rest.map { files[$0] }.filter { !present.contains($0) }.map { MediaItem(url: $0) }
            playlists[target].items += items
            added += items
        }
        if let firstSeriesPlaylist { selection = firstSeriesPlaylist }
        save()
        return added
    }

    private static func isDefaultName(_ name: String) -> Bool {
        name.range(of: #"^Playlist( \d+)?$"#, options: .regularExpression) != nil
    }

    func remove(_ itemIDs: Set<MediaItem.ID>, from playlistID: Playlist.ID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].items.removeAll { itemIDs.contains($0.id) }
        save()
    }

    /// Moves video files to the Trash, the one thing in Driftcast that touches a file on disk,
    /// and only ever from the right-click menu after the person has confirmed. A trashed file
    /// leaves every playlist it was in, along with its position and watched mark. Files that
    /// couldn't be trashed stay listed and are returned with the reason.
    @discardableResult
    func deleteFiles(_ urls: [URL], trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> [(URL, Error)] {
        var failed: [(URL, Error)] = []
        var gone: Set<String> = []
        for url in urls {
            do {
                try trash(url)
                gone.insert(url.path)
            } catch {
                failed.append((url, error))
            }
        }
        guard !gone.isEmpty else { return failed }
        for i in playlists.indices {
            playlists[i].items.removeAll { gone.contains($0.url.path) }
        }
        for path in gone {
            progress.removeValue(forKey: path)
            watched.remove(path)
        }
        save()
        return failed
    }

    /// Moves videos to the end of another playlist.
    func moveItems(_ itemIDs: Set<MediaItem.ID>, from source: Playlist.ID, to destination: Playlist.ID) {
        guard source != destination,
              let s = playlists.firstIndex(where: { $0.id == source }),
              let d = playlists.firstIndex(where: { $0.id == destination }) else { return }
        let moving = playlists[s].items.filter { itemIDs.contains($0.id) }
        guard !moving.isEmpty else { return }
        playlists[s].items.removeAll { itemIDs.contains($0.id) }
        playlists[d].items += moving
        save()
    }

    func move(in playlistID: Playlist.ID, from source: IndexSet, to destination: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var items = playlists[i].items
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted(by: >) { items.remove(at: index) }
        let target = destination - source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: max(0, min(target, items.count)))
        playlists[i].items = items
        save()
    }

    func attachSubtitle(_ subtitle: URL, toFile file: URL) {
        for p in playlists.indices {
            for j in playlists[p].items.indices where playlists[p].items[j].url == file {
                if !playlists[p].items[j].extraSubtitles.contains(subtitle) { playlists[p].items[j].extraSubtitles.append(subtitle) }
            }
        }
        save()
    }

    func presentOpenPanel(into playlistID: Playlist.ID? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add"
        panel.message = "Choose videos or folders to add to the playlist."
        if panel.runModal() == .OK { add(panel.urls, to: playlistID) }
    }

    // MARK: Watch progress

    func resumePosition(for url: URL) -> Double? { progress[url.path]?.position }

    func updateProgress(for url: URL, position: Double, duration: Double) {
        guard duration > 0 else { return }
        // Credits count as finished; capped so short clips aren't "watched" as soon as they start.
        let tail = min(max(30, duration * 0.04), duration * 0.1)
        if duration - position < tail {
            markWatched(url)
        } else if position < 10 {
            return // keep any earlier resume point; "Play from Beginning" clears it explicitly
        } else {
            progress[url.path] = WatchProgress(position: position, duration: duration, updated: Date())
            watched.remove(url.path)
            save()
        }
    }

    func markWatched(_ url: URL) {
        progress.removeValue(forKey: url.path)
        watched.insert(url.path)
        save()
    }

    func clearProgress(_ url: URL) {
        progress.removeValue(forKey: url.path)
        watched.remove(url.path)
        save()
    }
}
