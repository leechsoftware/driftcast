import SwiftUI

@main
struct DriftcastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library: Library
    @StateObject private var discovery: CastDiscovery
    @StateObject private var player: PlaybackController

    init() {
        Prefs.register()
        StreamSession.cleanTemporaryFiles()
        MediaServer.shared.start()
        let library = Library()
        let player = PlaybackController(library: library)
        _library = StateObject(wrappedValue: library)
        _discovery = StateObject(wrappedValue: CastDiscovery())
        _player = StateObject(wrappedValue: player)
        AppDelegate.player = player
        AppDelegate.library = library
    }

    var body: some Scene {
        // A single main window: opening files from Finder adds them here instead of spawning windows.
        Window("Driftcast", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(discovery)
                .environmentObject(player)
                .onAppear { discovery.start(); Updater.shared.start() }
        }
        .defaultSize(width: 980, height: 620)
        .commands {
            AboutCommands()
            PlaybackCommands(player: player, library: library)
            OutputCommands(player: player, discovery: discovery)
            SubtitleCommands(player: player)
            HelpCommands()
        }

        Window("Video", id: "video") {
            VideoWindow()
                .environmentObject(player)
        }
        .defaultSize(width: 960, height: 540)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var player: PlaybackController?
    @MainActor static var library: Library?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { SubtitleSizeMenuItem.shared.install() }
        // The red close button on the main window quits Driftcast, as the user expects of a
        // single-window player. Other windows (Video, Settings) just close.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        // macOS may bring the Video window back from the last run; it is only wanted once a
        // video is playing on this Mac.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard Self.player?.nowPlaying == nil else { return }
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("video") == true {
                    window.close()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.player?.shutdown()   // records where the current video was stopped
            Self.library?.saveNow()
        }
        try? FileManager.default.removeItem(at: StreamSession.temporaryRoot)
    }

    /// Files opened from Finder ("Open With", dropping on the Dock icon) are added and played.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let library = Self.library, let player = Self.player else { return }
            let added = library.add(urls)
            guard let playlist = library.selectedPlaylist else { return }
            // A video that was already listed plays from its existing row.
            let first = added.first ?? playlist.items.first { item in
                urls.contains { item.url == $0 || item.url.path.hasPrefix($0.path + "/") }
            }
            if let first { player.play(first, queue: playlist.items) }
        }
    }
}

struct PlaybackCommands: Commands {
    @ObservedObject var player: PlaybackController
    let library: Library
    @AppStorage(Prefs.showDetails) private var showDetails = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Videos…") { library.presentOpenPanel() }
                .keyboardShortcut("o")
            Button("New Playlist") { library.newPlaylist() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            // The selected video, else the playing one, in the details panel.
            Button("Details") {
                if player.infoItem == nil { player.infoItem = player.nowPlaying }
                showDetails = true
            }
            .keyboardShortcut("i")
            Button("Show in Finder") { player.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(player.nowPlaying == nil)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Details", isOn: $showDetails)
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePause() }
                .keyboardShortcut("p")
            Button("Stop") { player.stop() }
                .keyboardShortcut(".")
                .disabled(player.nowPlaying == nil)
            Divider()
            // Option-based so Cmd+arrows still move the cursor when renaming a playlist.
            Button("Skip Forward 10 Seconds") { player.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Button("Skip Back 10 Seconds") { player.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Skip Forward 1 Minute") { player.skip(60) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
            Button("Skip Back 1 Minute") { player.skip(-60) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
            Divider()
            Button("Next Video") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!player.hasNext)
            Button("Previous Video") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            Divider()
            Button("Volume Up") { player.nudgeVolume(0.05) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { player.nudgeVolume(-0.05) }
                .keyboardShortcut(.downArrow)
            Divider()
            // The same controls as the bar's audio button and its adjustments popover.
            Menu("Audio Track") {
                if let tracks = player.info?.audio, !tracks.isEmpty {
                    ForEach(tracks) { track in
                        Toggle(track.label, isOn: Binding(get: { player.audioIndex == track.index },
                                                          set: { if $0 { player.selectAudio(track.index) } }))
                    }
                } else {
                    Text(player.nowPlaying == nil ? "Play a video to choose its audio track" : "This video has one audio track")
                }
            }
            Toggle("Volume Booster", isOn: Binding(get: { player.options.volumeBoost }, set: { player.setVolumeBoost($0) }))
                .disabled(player.nowPlaying == nil)
            Toggle("Downmix to Stereo", isOn: Binding(get: { player.options.downmix }, set: { player.setDownmix($0) }))
                .disabled(player.nowPlaying == nil)
            Menu("Audio Delay") {
                Text(String(format: "Current: %+.2f s", player.options.avSyncOffset))
                Button("Later by 0.05 s") { player.nudgeAVSync(0.05) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Earlier by 0.05 s") { player.nudgeAVSync(-0.05) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                Button("Reset") { player.setAVSync(0) }
                    .disabled(player.options.avSyncOffset == 0)
            }
            .disabled(player.nowPlaying == nil)
        }
    }
}

/// The Output menu: the same choices as the toolbar's output button, so the device list is
/// also where menus are expected.
struct OutputCommands: Commands {
    @ObservedObject var player: PlaybackController
    @ObservedObject var discovery: CastDiscovery

    var body: some Commands {
        CommandMenu("Output") {
            Toggle("This Mac", isOn: Binding(get: { player.output == .local && !player.isAirPlaying },
                                             set: { if $0 { player.selectOutput(.local) } }))
            Button("Apple TV or AirPlay TV…") {
                player.selectOutput(.local)
                AirPlayPicker.shared.presentSoon()
            }
            Divider()
            let screens = discovery.devices.filter { !$0.isAudioOnly }
            let speakers = discovery.devices.filter(\.isAudioOnly)
            if screens.isEmpty, speakers.isEmpty {
                Text(discovery.problem.map { "Can't search for Chromecasts: \($0)" } ?? "No Chromecast found yet")
            }
            ForEach(screens) { device in deviceToggle(device) }
            if !speakers.isEmpty {
                Menu("Speakers (audio only)") {
                    ForEach(speakers) { device in deviceToggle(device) }
                }
            }
            Divider()
            Button("Disconnect from Chromecast") { player.disconnectCast() }
                .disabled({ if case .cast = player.output { return false }; return true }())
            Button("Search for Devices Again") { discovery.restart() }
        }
    }

    private func deviceToggle(_ device: CastDeviceInfo) -> some View {
        Toggle(device.name, isOn: Binding(get: { player.output == .cast(device) },
                                          set: { if $0 { player.selectOutput(.cast(device)) } }))
    }
}

/// Help menu: where to read about Driftcast and where to report problems.
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Driftcast Help") {
                if let source = AboutWindow.sourceURL, let readme = URL(string: source.absoluteString + "#readme") {
                    NSWorkspace.shared.open(readme)
                } else {
                    AboutWindow.shared.show()
                }
            }
            if let source = AboutWindow.sourceURL {
                Button("Report a Problem…") {
                    if let issues = URL(string: source.absoluteString + "/issues") { NSWorkspace.shared.open(issues) }
                }
                Button("Driftcast on GitHub") { NSWorkspace.shared.open(source) }
            }
            Button("Driftcast Website") { NSWorkspace.shared.open(AboutWindow.website) }
        }
    }
}

/// The Subtitles menu in the menu bar: the same choices as the bar's subtitle button, plus
/// the online search and where to get its API key.
struct SubtitleCommands: Commands {
    @ObservedObject var player: PlaybackController
    @AppStorage(Prefs.openSubtitlesKey) private var apiKey = ""
    @AppStorage(Prefs.settingsTab) private var settingsTab = "general"
    // Read so that Larger and Smaller enable and disable as the size changes.
    @AppStorage(Prefs.subtitleScale) private var subtitleScale = 1.0

    var body: some Commands {
        CommandMenu("Subtitles") {
            if player.nowPlaying == nil {
                Text("Play a video to choose its subtitles")
            } else {
                Toggle("Off", isOn: Binding(get: { player.subtitle == nil },
                                            set: { if $0 { player.selectSubtitle(nil) } }))
                if player.subtitleChoices.isEmpty {
                    Text("This video has no subtitle tracks")
                }
                ForEach(player.subtitleChoices) { choice in
                    Toggle(choice.label, isOn: Binding(get: { player.subtitle == choice },
                                                       set: { if $0 { player.selectSubtitle(choice) } }))
                }
            }
            Divider()
            Button("Add Subtitle File…") { player.chooseSubtitleFile() }
                .disabled(player.nowPlaying == nil)
            Button("Find Subtitles Online…") { player.showSubtitleSearch = true }
                .disabled(player.nowPlaying == nil)
            Divider()
            // The slider itself is an AppKit item that SubtitleSizeMenuItem adds under these.
            Button("Larger Subtitles") { SubtitleSize.increase() }
                .keyboardShortcut("=", modifiers: [.command, .option])
                .disabled(!SubtitleSize.canIncrease)
            Button("Smaller Subtitles") { SubtitleSize.decrease() }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(!SubtitleSize.canDecrease)
            Divider()
            // Reading apiKey keeps this in step with Settings; the built-in key counts too.
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, OpenSubtitlesClient.builtInKey.isEmpty {
                Button("Get a Free OpenSubtitles API Key…") { NSWorkspace.shared.open(OpenSubtitlesClient.keyPage) }
                Button("Enter API Key…") { showSubtitleSettings() }
            }
            Button("Subtitle Settings…") { showSubtitleSettings() }
        }
    }

    private func showSubtitleSettings() {
        settingsTab = "subtitles"
        SettingsOpener.open()
    }
}
