import AVKit
import SwiftUI

/// Toolbar control choosing where video plays: this Mac (and AirPlay from there) or a Chromecast.
struct OutputPicker: View {
    @EnvironmentObject private var player: PlaybackController
    @EnvironmentObject private var discovery: CastDiscovery

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button {
                    player.selectOutput(.local)
                } label: {
                    Label("This Mac", systemImage: player.output == .local ? "checkmark" : "laptopcomputer")
                }
                Section("Chromecast") {
                    if discovery.devices.isEmpty {
                        Text(discovery.problem.map { "Can't search: \($0)" } ?? "Searching the network…")
                    }
                    ForEach(discovery.devices.filter { !$0.isAudioOnly }) { device in
                        deviceButton(device)
                    }
                }
                let speakers = discovery.devices.filter(\.isAudioOnly)
                if !speakers.isEmpty {
                    Section("Speakers (audio only)") {
                        ForEach(speakers) { device in deviceButton(device) }
                    }
                }
                Section("AirPlay") {
                    Button {
                        player.selectOutput(.local)
                        AirPlayPicker.shared.presentSoon()
                    } label: {
                        Label("Apple TV or AirPlay TV…", systemImage: "airplayvideo")
                    }
                }
                if case .cast = player.output {
                    Divider()
                    Button("Disconnect") { player.disconnectCast() }
                }
                Divider()
                Button("Search Again") { discovery.restart() }
            } label: {
                Label(player.outputName, systemImage: player.outputSymbol)
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose where to play")

            if player.output == .local {
                AirPlayButton(player: player.localTarget.player)
                    .frame(width: 30, height: 22)
                    .help("AirPlay to an Apple TV or AirPlay 2 TV")
            }
        }
    }
}

extension OutputPicker {
    fileprivate func deviceButton(_ device: CastDeviceInfo) -> some View {
        Button {
            player.selectOutput(.cast(device))
        } label: {
            Label(device.name, systemImage: player.output == .cast(device) ? "checkmark" : device.symbol)
        }
    }
}

struct AirPlayButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.isRoutePickerButtonBordered = false
        AirPlayPicker.shared.view = v
        return v
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
        AirPlayPicker.shared.view = nsView
    }
}

/// Only AVRoutePickerView can show the system's list of AirPlay devices, so the output menu's
/// AirPlay item opens that list by clicking the toolbar's picker on the user's behalf.
@MainActor
final class AirPlayPicker {
    static let shared = AirPlayPicker()
    weak var view: AVRoutePickerView?

    /// Waits for the menu to close and, when switching away from a Chromecast, for the picker
    /// to come back into the toolbar.
    func presentSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.present() }
    }

    private func present() {
        guard let view, view.window != nil, let button = Self.firstButton(in: view) else { return }
        button.performClick(nil)
    }

    private static func firstButton(in view: NSView) -> NSButton? {
        for sub in view.subviews {
            if let button = sub as? NSButton { return button }
            if let found = firstButton(in: sub) { return found }
        }
        return nil
    }
}

/// The local/AirPlay picture. When AirPlay is active AVPlayerView shows its own placeholder.
/// A thin bar under the picture says which closed captions the video has (unless Settings hide it).
struct VideoWindow: View {
    @EnvironmentObject private var player: PlaybackController
    @AppStorage(Prefs.hideSubtitleNotices) private var hideNotices = false

    /// DEBUG builds can show the watermark with no device to hand (`-PreviewCastingWatermark Name`).
    private var castingName: String? {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "PreviewCastingWatermark") { return name }
        #endif
        return player.remoteDeviceName
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerViewRepresentable(player: player.localTarget.player)
                .frame(minWidth: castingName == nil ? 480 : 320, minHeight: castingName == nil ? 270 : 140)
                .background(.black)
                .overlay {
                    if let name = castingName {
                        CastingWatermark(deviceName: name, artwork: player.artwork)
                    }
                }
            if castingName != nil {
                // All this window is for while casting: is it playing, and where.
                Divider()
                CastingControls()
            } else if !hideNotices, player.nowPlaying != nil {
                Divider()
                CaptionsFooter()
            }
        }
        .onAppear { fitWindow(casting: castingName != nil) }
        .onChange(of: castingName != nil) { casting in fitWindow(casting: casting) }
        .background(WindowConfigurator { window in
            // Opened by the app when a video starts, never brought back by macOS at launch.
            window.isRestorable = false
        })
        .navigationTitle(player.output == .local ? (player.nowPlaying?.title ?? "Video") : "Video")
    }
}

/// The window drops to half its size while casting, keeping its top-left corner where it is,
/// and goes back when playback returns to this Mac.
extension VideoWindow {
    /// Kept in the defaults so that quitting mid-cast doesn't leave the window small for good.
    private static let sizeBeforeCastingKey = "videoWindowSizeBeforeCasting"

    fileprivate func fitWindow(casting: Bool) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("video") == true }) else { return }
        let defaults = UserDefaults.standard
        let wanted: NSSize
        if casting {
            guard defaults.string(forKey: Self.sizeBeforeCastingKey) == nil else { return }
            let current = window.contentLayoutRect.size
            defaults.set(NSStringFromSize(current), forKey: Self.sizeBeforeCastingKey)
            wanted = NSSize(width: max(400, current.width / 2), height: max(225, current.height / 2))
        } else {
            guard let saved = defaults.string(forKey: Self.sizeBeforeCastingKey) else { return }
            defaults.removeObject(forKey: Self.sizeBeforeCastingKey)
            wanted = NSSizeFromString(saved)
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: wanted))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Play and pause and the timeline, for a video that is playing on another device.
private struct CastingControls: View {
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        HStack(spacing: 6) {
            Button { player.togglePause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(player.isPlaying ? "Pause" : "Play")
            TimelineRow(clock: player.clock)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Covers the picture while the video is on another device, so an empty or frozen window doesn't
/// look like a fault: the film's poster, dimmed, with who it is playing on written across it.
private struct CastingWatermark: View {
    let deviceName: String
    let artwork: NSImage?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                Color.black
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: height)
                        .clipped()
                        .opacity(0.28)
                }
                // The big grey streaming mark, with the words laid across it.
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: min(height * 0.62, geometry.size.width * 0.34)))
                    .foregroundStyle(Color.gray.opacity(0.42))
                VStack(spacing: height * 0.035) {
                    Text("Connected to \(deviceName)")
                        .font(.system(size: height * 0.1, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.4)
                    Text("Streaming video\u{2026}")
                        .font(.system(size: height * 0.05))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                .padding(24)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The video window's footer: "Closed Captions: English, Spanish" (or that there are none)
/// and the same menu as the playback bar's subtitle button. Full screen shows the picture
/// alone, since AVPlayerView takes only itself full screen.
struct CaptionsFooter: View {
    @EnvironmentObject private var player: PlaybackController
    @AppStorage(Prefs.subtitleLanguage) private var language = ""

    /// Nothing in the Settings language, forced tracks included: the crossed-out mark (the menu offers Find Subtitles Online…).
    private var missing: Bool { !language.isEmpty && !SubtitleChoice.hasAny(player.subtitleChoices, in: language) }

    var body: some View {
        HStack(spacing: 8) {
            CaptionsIcon(missing: missing, filled: player.subtitle != nil, size: 18)
            Text(notice)
                .font(.callout)
                .foregroundStyle(.secondary)   // a quiet note under the picture, not a heading
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Menu {
                SubtitleMenuItems()
            } label: {
                // "English (forced)" for a signs-only track, so it doesn't contradict "No English captions".
                Text(player.subtitle.map { ($0.isForced ? "\(Lang.name($0.language) ?? "On") (forced)" : Lang.name($0.language)) ?? "On" } ?? "Off")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Closed captions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var notice: String {
        let languages = SubtitleChoice.languageSummary(player.subtitleChoices)
        if player.subtitleChoices.isEmpty { return "No closed captions in this video" }
        if missing { return "No \(Lang.name(language) ?? language) captions" }   // the menu lists what there is
        return "Closed Captions: \(languages)"
    }
}

/// Off, every track and file, then the ways to add one: the body of the subtitle menus in the
/// playback bar and the video window's footer.
struct SubtitleMenuItems: View {
    @EnvironmentObject private var player: PlaybackController

    var body: some View {
        Button { player.selectSubtitle(nil) } label: {
            if player.subtitle == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
        }
        if !player.subtitleChoices.isEmpty { Divider() }
        ForEach(player.subtitleChoices) { choice in
            Button { player.selectSubtitle(choice) } label: {
                if choice == player.subtitle { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
            }
        }
        Divider()
        Button("Find Subtitles Online…") { player.showSubtitleSearch = true }
        Button("Add Subtitle File…") { player.chooseSubtitleFile() }
    }
}

/// Runs a closure on the NSWindow that ends up hosting the view.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { configure(window) }
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
