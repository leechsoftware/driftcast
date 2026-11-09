import SwiftUI

struct SubtitleSearchView: View {
    let item: MediaItem
    @EnvironmentObject private var player: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.openSubtitlesKey) private var apiKey = ""
    @AppStorage(Prefs.subtitleLanguage) private var language = "en"
    @State private var query = ""
    @State private var results: [OpenSubtitlesClient.Result] = []
    @State private var selection: OpenSubtitlesClient.Result.ID?
    @State private var busy = false
    @State private var message: String?
    /// True while the dialog is asking for a key. Set when it opens and when OpenSubtitles turns
    /// a key down, and cleared only by Continue, so the box doesn't vanish halfway through typing.
    @State private var needsKey = false
    @State private var keyProblem: String?
    @State private var keyHelp = false

    private var typedKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Find Subtitles Online").font(.title3.weight(.semibold))
                if !needsKey {
                    Text("Pick one and Use: it downloads and comes on.").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !needsKey { search() } }
                Picker("Language", selection: $language) {
                    ForEach(Lang.common, id: \.self) { code in
                        Text(Lang.name(code) ?? code).tag(code)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                if !needsKey {
                    Button("Search") { search() }.disabled(busy)
                }
            }
            if needsKey { keyPanel } else { resultsTable }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Only once there is something to use; a button that can't do anything yet is just confusing.
                if !needsKey, !results.isEmpty {
                    Button("Use") { download() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || busy)
                        .help("Downloads the selected subtitle and turns it on")
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 460)
        .task {
            // "Movie.Name.2019.1080p.BluRay.x264-GRP" -> "Movie Name 2019", or the title the
            // person corrected in the details panel.
            query = await MetadataLookup.shared.title(for: item.url).searchQuery
            needsKey = !OpenSubtitlesClient.hasKey
            if !needsKey { search() }
        }
    }

    /// Takes the place of the results while there is no key: OpenSubtitles answers nothing
    /// without one, so this is the one thing to do here, and it is all in one place.
    private var keyPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "key")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Add your free OpenSubtitles key to search")
                .font(.headline)
            Text("OpenSubtitles only answers apps that send a key. It's free, and you only need to do this once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                TextField("Paste your API key here", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                    .onSubmit { continueWithKey() }
                Button("Continue") { continueWithKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!typedKey)
            }
            if let keyProblem {
                Text(keyProblem).font(.callout).foregroundStyle(.orange)
            }
            Button("How to get a free key…") { keyHelp = true }
                .buttonStyle(.link)
                .popover(isPresented: $keyHelp, arrowEdge: .bottom) {
                    OpenSubtitlesKeyHelp { continueWithKey() }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var resultsTable: some View {
        Table(results, selection: $selection) {
            TableColumn("Release") { r in
                HStack(spacing: 4) {
                    if r.hashMatch {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            .help("Matches this exact file")
                    }
                    Text(r.release.isEmpty ? r.fileName : r.release).lineLimit(1)
                }
            }
            TableColumn("Language") { r in Text(Lang.name(r.language) ?? r.language) }
                .width(90)
            TableColumn("Downloads") { r in Text("\(r.downloads)").monospacedDigit() }
                .width(80)
            TableColumn("HI") { r in if r.hearingImpaired { Image(systemName: "ear") } }
                .width(28)
        }
        .contextMenu(forSelectionType: OpenSubtitlesClient.Result.ID.self) { _ in } primaryAction: { _ in download() }
        .frame(minHeight: 260)
    }

    private func continueWithKey() {
        guard typedKey else { return }
        needsKey = false
        keyProblem = nil
        search()
    }

    private func search() {
        let q = query, lang = language
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let client = try OpenSubtitlesClient.fromSettings()
                let title = await MetadataLookup.shared.title(for: item.url)
                let hash = await Task.detached { OpenSubtitlesClient.movieHash(for: item.url) }.value
                var found = try await client.search(query: q, languages: lang, movieHash: hash, season: title.season, episode: title.episode)
                if found.isEmpty, hash != nil {
                    found = try await client.search(query: q, languages: lang, movieHash: nil, season: title.season, episode: title.episode)
                }
                results = found
                selection = found.first?.id
                message = found.isEmpty ? "No subtitles found." : "\(found.count) found. Double-click one, or select it and click Use."
            } catch let failure as OpenSubtitlesClient.Failure where failure.isKeyRefused {
                // Back to the box, saying why, rather than an error down here with nowhere to act on it.
                results = []
                needsKey = true
                keyProblem = "OpenSubtitles didn't accept that key. Check it and try again."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func download() {
        guard let id = selection, let result = results.first(where: { $0.id == id }) else { return }
        busy = true
        message = "Downloading…"
        Task {
            defer { busy = false }
            do {
                let client = try OpenSubtitlesClient.fromSettings()
                let file = try await client.download(result, for: item.url)
                player.addSubtitleFile(file, to: item)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
