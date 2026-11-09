import SwiftUI

/// The details panel beside the playlist: poster, plot, people and ratings for the selected
/// (or playing) video, then what is in the file and how it would be sent to the current device.
struct DetailsView: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: Library
    @AppStorage(Prefs.onlineDetails) private var onlineDetails = true
    @AppStorage(Prefs.showDetails) private var showDetails = false
    @AppStorage(Prefs.hideSubtitleNotices) private var hideNotices = false
    /// Where the panel is scrolled, for the floating arrow.
    @State private var scroll = ScrollPosition()
    /// The language captions should be in (Settings > Subtitles); the crossed-out mark reports its absence.
    @AppStorage(Prefs.subtitleLanguage) private var captionLanguage = ""
    /// The OpenSubtitles sheet and the key steps, opened from the captions line or the section.
    @State private var searching = false
    @State private var keyHelp = false
    @State private var details: MovieDetails?
    @State private var poster: NSImage?
    @State private var still: NSImage?
    @State private var info: MediaInfo?
    @State private var infoError: String?
    @State private var looking = false
    @State private var parsed: MediaTitle?
    @State private var correcting = false
    @State private var correctionTitle = ""
    @State private var correctionYear = ""

    private var item: MediaItem? { player.infoItem ?? player.nowPlaying }

    /// The library's copy of the panel's video, which carries subtitle files attached later.
    private func current(_ item: MediaItem) -> MediaItem {
        library.playlists.lazy.flatMap(\.items).first { $0.url == item.url } ?? item
    }

    /// The captions the video has: the player's list while it plays (files added during
    /// playback show up), else what the file and its neighbours hold.
    private var captionChoices: [SubtitleChoice] {
        guard let item else { return [] }
        if player.nowPlaying?.url == item.url { return player.subtitleChoices }
        guard let info else { return [] }
        return SubtitleChoice.available(for: current(item), info: info)
    }
    private var captionsProbing: Bool { info == nil && infoError == nil && player.nowPlaying?.url != item?.url }
    /// Nothing at all in the Settings language (a forced track in it counts as something).
    private var captionsMissing: Bool {
        !captionsProbing && !captionLanguage.isEmpty && !SubtitleChoice.hasAny(captionChoices, in: captionLanguage)
    }
    private var hasKey: Bool { OpenSubtitlesClient.hasKey }

    var body: some View {
        VStack(spacing: 0) {
            // A header with the control that folds the panel away (the toolbar button and
            // View > Show Details do the same).
            HStack {
                Text("Details").font(.headline)
                Spacer()
                Button {
                    showDetails = false
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Details (⌥⌘I)")
                .accessibilityLabel("Hide Details")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let item {
            ScrollViewReader { proxy in
                ScrollView {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 14) {
                                artwork
                                heading(item)
                                if !hideNotices { captionsLine(proxy) }
                                if let details {
                                    if !details.ratings.isEmpty { ratingsRow(details) }
                                    facts(details)
                                    if details.isEpisode { episodeBlock(details) }
                                    if let synopsis = details.synopsis, !synopsis.isEmpty {
                                        Text(synopsis)
                                            .font(.callout)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                    attribution(details)
                                } else if looking {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Looking up details…").font(.callout).foregroundStyle(.secondary)
                                    }
                                } else if !onlineDetails {
                                    Text("Online details are off in Settings > General.")
                                        .font(.callout).foregroundStyle(.secondary)
                                } else {
                                    Text("No details were found for this title.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                correctionButton
                                Divider()
                                FileInfoSection(item: item, info: info, error: infoError)
                                actions(item)
                                if !hideNotices {
                                    SubtitleSection(item: current(item), choices: captionChoices, probing: captionsProbing,
                                                    missingLanguage: captionsMissing ? captionLanguage : nil,
                                                    searching: $searching, keyHelp: $keyHelp)
                                        .id("captions")
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("top")
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .background(ScrollObserver { scroll = $0 })
                }
                .overlay(alignment: .bottom) { scrollArrow(proxy) }
            }
            .sheet(isPresented: $searching) { SubtitleSearchView(item: current(item)) }
            .task(id: item.url) { await load(item) }
            .onChange(of: onlineDetails) { on in if on { Task { await load(item) } } }
        } else {
            EmptyStateView(title: "No Video Selected", systemImage: "info.circle",
                           message: "Select a video to see its poster, plot, ratings and what's in the file.")
        }
    }

    // MARK: Pieces

    /// A floating arrow at the foot of the panel when the details run past the window: one
    /// click scrolls smoothly to the end, and from there back to the top. The window itself
    /// never has to grow.
    @ViewBuilder private func scrollArrow(_ proxy: ScrollViewProxy) -> some View {
        if scroll.overflows {
            let atBottom = scroll.atEnd
            Button {
                withAnimation(.easeInOut(duration: 0.8)) {
                    if atBottom { proxy.scrollTo("top", anchor: .top) } else { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            } label: {
                Image(systemName: atBottom ? "chevron.up" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            .help(atBottom ? "Back to the top" : "Scroll down through the details")
            .accessibilityLabel(atBottom ? "Scroll to top" : "Scroll to bottom")
        }
    }

    /// One line under the title about closed captions, in the section's tint: which languages
    /// the video has, or just "No English captions" with the crossed-out mark when none is in
    /// the Settings language. "Show" (or the line itself) scrolls to the captions section.
    private func captionsLine(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            if captionsProbing {
                ProgressView().controlSize(.mini).frame(width: 20, height: 20)
            } else {
                CaptionsIcon(missing: captionsMissing, filled: !captionChoices.isEmpty)
            }
            Text(captionsText)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)   // the text wraps; the button keeps its own width
            Spacer(minLength: 8)
            Button("Show") { scrollToCaptions(proxy) }
                .fixedSize()
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { scrollToCaptions(proxy) }
        .help("Closed captions for this video; click to jump to the captions section")
    }

    private var captionsText: String {
        if captionsProbing { return "Checking closed captions…" }
        let summary = SubtitleChoice.languageSummary(captionChoices)
        if captionChoices.isEmpty { return "No closed captions in this video" }
        // Just the fact; the section below lists what the video does have.
        if captionsMissing { return "No \(Lang.name(captionLanguage) ?? captionLanguage) captions" }
        return "Closed Captions: \(summary)"
    }

    private func scrollToCaptions(_ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.6)) { proxy.scrollTo("captions", anchor: .top) }
    }

    @ViewBuilder private var artwork: some View {
        if let poster {
            Image(nsImage: poster)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 300)   // a portrait poster must leave the title and plot in view
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4, y: 2)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: "film").font(.system(size: 36)).foregroundStyle(.secondary)
            }
            .frame(height: 150)
        }
    }

    private func heading(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(details?.isEpisode == true ? (details?.showTitle ?? details?.title ?? item.title) : (details?.title ?? parsed?.title ?? item.title))
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let details, let label = details.episodeLabel {
                Text(details.episodeTitle.map { "\(label): \($0)" } ?? label)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let line = [
                details?.year.map(String.init) ?? parsed?.year.map(String.init),
                details?.runtimeText ?? info.flatMap { $0.duration > 0 ? formatTime($0.duration) : nil },
                details?.certificate,
                details?.network,
            ].compactMap { $0 }
            if !line.isEmpty {
                Text(line.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let details, !details.genres.isEmpty {
                Text(details.genres.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ratingsRow(_ details: MovieDetails) -> some View {
        HStack(spacing: 10) {
            ForEach(details.ratings, id: \.source) { rating in
                VStack(spacing: 1) {
                    Text(rating.value).font(.callout.weight(.semibold)).monospacedDigit()
                    Text(rating.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func facts(_ details: MovieDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !details.directors.isEmpty { fact(details.directors.count == 1 ? "Director" : "Directors", details.directors.joined(separator: ", ")) }
            if !details.writers.isEmpty { fact(details.writers.count == 1 ? "Writer" : "Writers", details.writers.joined(separator: ", ")) }
            if !details.cast.isEmpty { fact("Starring", details.cast.joined(separator: ", ")) }
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.callout.weight(.medium)).frame(width: 64, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func episodeBlock(_ details: MovieDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let still {
                Image(nsImage: still)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let date = details.airDate { fact("Aired", date) }
            if let synopsis = details.episodeSynopsis, !synopsis.isEmpty {
                Text(synopsis).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if details.synopsis != nil {
                Text("About the show").font(.callout.weight(.medium)).padding(.top, 4)
            }
        }
    }

    private func attribution(_ details: MovieDetails) -> some View {
        HStack(spacing: 4) {
            Text(details.source == "Wikipedia" ? "Details from Wikipedia and Wikidata" : "Details from \(details.source)")
            if let link = details.link {
                Link(details.link?.host?.contains("imdb") == true ? "IMDb page" : "Open page", destination: link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var correctionButton: some View {
        if onlineDetails, let item {
            Button(details == nil ? "Search by Title…" : "Not this title? Search again…") {
                correctionTitle = details?.title ?? parsed?.title ?? item.title
                correctionYear = (details?.year ?? parsed?.year).map(String.init) ?? ""
                correcting = true
            }
            .controlSize(.small)
            .popover(isPresented: $correcting, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Search for the film or show by name").font(.headline)
                    TextField("Title", text: $correctionTitle).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await correct(item) } }
                    TextField("Year (optional)", text: $correctionYear).textFieldStyle(.roundedBorder).frame(width: 140)
                    if parsed?.isEpisode == true, let label = parsed?.episodeLabel {
                        Text("\(label) stays as read from the file name.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Use File Name") {
                            Task { await MetadataLookup.shared.setTitle(nil, for: item.url); correcting = false; await load(item) }
                        }
                        Spacer()
                        Button("Cancel") { correcting = false }
                        Button("Search") { Task { await correct(item) } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(correctionTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 320)
            }
        }
    }

    /// Show in Finder only; playing is the row's and the bar's job (the user asked for no Play here).
    private func actions(_ item: MediaItem) -> some View {
        HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Spacer()
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    // MARK: Loading

    private func load(_ item: MediaItem) async {
        details = nil; poster = nil; still = nil; info = nil; infoError = nil
        parsed = await MetadataLookup.shared.title(for: item.url)
        looking = onlineDetails
        async let probe: Void = loadInfo(item)
        if let cached = await MetadataLookup.shared.cached(for: item.url) {
            details = cached
            await loadImages(cached, item: item)
        }
        if details == nil, onlineDetails {
            let found = await MetadataLookup.shared.details(for: item.url)
            guard !Task.isCancelled else { return }
            details = found
            if let found { await loadImages(found, item: item) }
        }
        looking = false
        if poster == nil, let data = await Thumbnailer.shared.poster(for: item.url, duration: info?.duration ?? 0) {
            if !Task.isCancelled, poster == nil { poster = NSImage(data: data) }
        }
        await probe
    }

    private func loadInfo(_ item: MediaItem) async {
        do { info = try await MediaProbe.shared.probe(item.url) } catch { infoError = error.localizedDescription }
    }

    private func loadImages(_ details: MovieDetails, item: MediaItem) async {
        if let url = details.posterURL, let data = await MetadataLookup.shared.artwork(url), let image = NSImage(data: data) {
            poster = image
        }
        if let url = details.episodeImageURL, let data = await MetadataLookup.shared.artwork(url), let image = NSImage(data: data) {
            still = image
        }
    }

    private func correct(_ item: MediaItem) async {
        let title = correctionTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var corrected = MediaTitle(title: title, year: Int(correctionYear.trimmingCharacters(in: .whitespaces)))
        corrected.season = parsed?.season
        corrected.episode = parsed?.episode
        await MetadataLookup.shared.setTitle(corrected, for: item.url)
        correcting = false
        details = nil; poster = nil; still = nil
        parsed = corrected
        looking = true
        var found = await MetadataLookup.shared.details(for: corrected, refresh: true)
        if found == nil, corrected.year != nil {
            // The year box keeps the file name's year, which is often the part that was wrong.
            corrected.year = nil
            found = await MetadataLookup.shared.details(for: corrected, refresh: true)
            if found != nil {
                await MetadataLookup.shared.setTitle(corrected, for: item.url)
                parsed = corrected
            }
        }
        details = found
        if let found { await loadImages(found, item: item) }
        looking = false
    }
}

/// Streams in a file and how each would be sent to the current output.
struct FileInfoSection: View {
    let item: MediaItem
    let info: MediaInfo?
    let error: String?
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File").font(.headline)
            Text(item.url.lastPathComponent)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(2)
            Text(item.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            if let info {
                row("Duration", formatTime(info.duration))
                row("Container", info.formatName)
                if let br = info.bitRate { row("Bit rate", String(format: "%.1f Mbps", Double(br) / 1_000_000)) }
                if let v = info.video { row("Video", videoLine(v)) }
                row(info.audio.count == 1 ? "Audio" : "Audio tracks", info.audio.isEmpty ? "None" : info.audio.map(\.label).joined(separator: "\n"))
                // Subtitles have their own section at the foot of the panel.
                Text("On \(player.outputName)").font(.callout.weight(.medium)).padding(.top, 4)
                ForEach(planNotes(info), id: \.self) { note in
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if !item.exists {
                Text("The file couldn't be found. It may have been moved or deleted.").font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
            Text(value).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    /// "HEVC Main 10, 3840 x 2160, 23.976 fps, HDR10".
    private func videoLine(_ v: MediaInfo.Video) -> String {
        var video = "\(Codecs.videoName(v.codec))\(v.profile.map { " \($0)" } ?? ""), \(v.width) x \(v.height)"
        if v.fps > 0 { video += String(format: ", %.5g fps", v.fps) }
        if let hdr = v.hdrName { video += ", \(hdr)" } else if v.bitDepth > 8 { video += ", \(v.bitDepth)-bit" }
        return video
    }

    private func planNotes(_ info: MediaInfo) -> [String] {
        let settings = EncoderSettings.current()
        let profile: DeviceProfile
        switch player.output {
        case .local: profile = .apple()
        case .cast(let d): profile = .chromecast(model: d.model, capabilities: d.capabilities, settings: settings)
        }
        let audio = PlaybackController.preferredAudio(info)
        let subs = SubtitleChoice.available(for: item, info: info)
        let sub = PlaybackController.preferredSubtitle(subs, audio: audio)
        return StreamPlanner.plan(info: info, file: item.url, profile: profile, settings: settings,
                                  audioIndex: audio?.index, subtitle: sub,
                                  subtitleIsText: sub.map { $0.isPicture && Prefs.bool(Prefs.ocrSubtitles) && PictureSubtitleOCR.supports($0, media: item.url) } ?? false,
                                  options: player.options).notes
    }
}

/// The foot of the panel, in its own tint so it stands out: which closed captions the video
/// has (with the crossed-out mark when none is in the Settings language), a menu to pick one
/// and a button to turn it on (or start the video with it), then "Find Subtitles Online…" —
/// one step: search, pick, it downloads and comes on — beside "Add Subtitle File…".
struct SubtitleSection: View {
    /// The library's copy of the video, which carries subtitle files attached later.
    let item: MediaItem
    let choices: [SubtitleChoice]
    /// True while the file is still being read; a file that can't be read shows "None" rather than a spinner.
    let probing: Bool
    /// The Settings language when the video has no full captions in it.
    let missingLanguage: String?
    @Binding var searching: Bool
    @Binding var keyHelp: Bool
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var library: Library
    @AppStorage(Prefs.openSubtitlesKey) private var apiKey = ""
    /// The menu's choice once the user has changed it; until then it mirrors what is on.
    @State private var pick: SubtitleChoice?
    @State private var userPicked = false

    private var current: MediaItem { item }
    private var isPlaying: Bool { player.nowPlaying?.url == item.url }
    /// What is on now, or for a video that isn't playing, what would come on when it is.
    private var active: SubtitleChoice? {
        if isPlaying { return player.subtitle }
        return PlaybackController.preferredSubtitle(choices, audio: player.nowPlaying?.url == item.url ? player.info?.audio.first : nil)
    }
    private var shown: SubtitleChoice? { userPicked ? pick : active }
    private var hasKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !OpenSubtitlesClient.builtInKey.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let checking = probing && !isPlaying
            HStack(spacing: 8) {
                if checking {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                } else {
                    // Crossed out only when the video has no captions at all.
                    CaptionsIcon(missing: choices.isEmpty, filled: true)
                }
                Text("Closed Captions").font(.headline)
            }
            if !checking {
                if choices.isEmpty {
                    Text("None in this video. Find them online or add a subtitle file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(SubtitleChoice.languageSummary(choices))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let missingLanguage {
                        HStack(spacing: 6) {
                            NoCaptionsIcon(size: 14)
                            Text("None in \(Lang.name(missingLanguage) ?? missingLanguage), your subtitle language.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // A choice only when there is something to choose.
                    HStack(spacing: 8) {
                        trackMenu
                        Button(buttonTitle) { apply() }
                            .help(isPlaying
                                  ? (player.subtitle == nil ? "Turns the chosen captions on" : "Turns the captions off")
                                  : "Plays this video with the chosen captions")
                            .fixedSize()
                    }
                    .controlSize(.small)
                }
            }
            // Ways to get captions, only when the video has none (the track menu offers them otherwise).
            if !checking, choices.isEmpty {
                HStack(spacing: 8) {
                    Button("Find Subtitles Online…") { findOnline() }
                        .buttonStyle(.borderedProminent)
                        .help("Searches OpenSubtitles for this video; pick a result and it downloads and comes on")
                    Button("Add Subtitle File…") { player.chooseSubtitleFile(for: current) }
                    Spacer()
                }
                .controlSize(.small)
                if !hasKey {
                    HStack(spacing: 4) {
                        Text("Finding subtitles online needs a free OpenSubtitles key.")
                        Button("How to get one…") { keyHelp = true }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .popover(isPresented: $keyHelp, arrowEdge: .bottom) {
            // Once a key is entered the search opens by itself.
            OpenSubtitlesKeyHelp {
                if OpenSubtitlesClient.hasKey {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { searching = true }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        .onChange(of: item.url) { _ in userPicked = false }
        .onChange(of: choices) { now in
            // A track that is no longer there (the video changed) can't stay picked.
            if userPicked, let pick, !now.contains(pick) { userPicked = false }
        }
    }

    private var trackMenu: some View {
        Menu {
            Button { choose(nil) } label: {
                if shown == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            if !choices.isEmpty { Divider() }
            ForEach(choices) { choice in
                Button { choose(choice) } label: {
                    if choice == shown { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
            }
            Divider()
            Button("Find Subtitles Online…") { findOnline() }
            Button("Add Subtitle File…") { player.chooseSubtitleFile(for: current) }
            if !hasKey {
                Button("How to Get a Free OpenSubtitles Key…") { keyHelp = true }
            }
        } label: {
            Text(shown?.label ?? "Off").lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Closed captions for this video")
    }

    private var buttonTitle: String {
        guard isPlaying else { return "Play" }
        return player.subtitle == nil ? "Turn On" : "Turn Off"
    }

    /// While the video plays a choice applies at once; otherwise it waits for Play.
    private func choose(_ choice: SubtitleChoice?) {
        pick = choice
        userPicked = true
        if isPlaying {
            player.selectSubtitle(choice)
            userPicked = false
        }
    }

    /// The track "Turn On" picks when nothing is on: the last choice, else a full track in the
    /// Settings language, else the first one.
    private var trackToTurnOn: SubtitleChoice? {
        if let pick, choices.contains(pick) { return pick }
        let language = Prefs.string(Prefs.subtitleLanguage)
        return choices.first { Lang.matches($0.language, language) && !$0.isForced } ?? choices.first
    }

    /// The search sheet, which asks for a key itself when there is none.
    private func findOnline() { searching = true }

    /// Toggles the playing video's captions, or starts this video with the chosen ones.
    private func apply() {
        if isPlaying {
            player.selectSubtitle(player.subtitle == nil ? trackToTurnOn : nil)
        } else {
            let queue = library.playlists.first { $0.items.contains { $0.url == item.url } }?.items ?? [current]
            let start: PlaybackController.SubtitleStart = userPicked ? (pick.map { .use($0) } ?? .off) : .automatic
            player.play(current, queue: queue, subtitle: start)
        }
        userPicked = false
    }
}

/// The steps to a free OpenSubtitles API key, with a box to paste it into. OpenSubtitles has
/// no API for creating accounts, so the account itself is made on their website; the key
/// works as soon as the consumer is saved (it is the account that needs confirming, by email).
struct OpenSubtitlesKeyHelp: View {
    /// Called after Done, so the caller can carry on (for example, open the search).
    var onDone: (() -> Void)? = nil
    @AppStorage(Prefs.openSubtitlesKey) private var apiKey = ""
    @Environment(\.dismiss) private var dismiss
    static let signUpPage = URL(string: "https://www.opensubtitles.com/en/users/sign_up")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get a free OpenSubtitles API key").font(.headline)
            step(1, "Create an account",
                 "Sign up at opensubtitles.com, then open the email they send and click its confirmation link; the account isn't active until you do.",
                 link: "Open the sign-up page", url: Self.signUpPage)
            step(2, "Open API Consumers",
                 "Sign in, then open the API Consumers page (the link below goes straight there) and click New Consumer.",
                 link: "Open the API Consumers page", url: OpenSubtitlesClient.keyPage)
            step(3, "Name it and save",
                 "Any name will do, such as Driftcast. Leave \"Allow anonymous downloads\" ticked so Driftcast can download without signing you in. The page then shows the key.")
            step(4, "Paste the key here", "It is also kept in Settings > Subtitles.")
            HStack {
                TextField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button("Done") { dismiss(); onDone?() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("A key on its own allows 5 downloads a day. Ticking \"Under development\" on the consumer raises that to 100 a day for as long as OpenSubtitles permits it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func step(_ number: Int, _ title: String, _ text: String, link: String? = nil, url: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let link, let url {
                    Link(link, destination: url).font(.callout)
                }
            }
        }
    }
}
