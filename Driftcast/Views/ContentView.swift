import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var player: PlaybackController
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.showDetails) private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                // A fixed-width panel inside the window rather than an inspector, which widens
                // the window each time it opens; the playlist gives up the room instead and the
                // panel scrolls.
                HStack(spacing: 0) {
                    PlaylistView()
                    if showDetails {
                        Divider()
                        DetailsView()
                            .frame(width: 330)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showDetails)
            }
            Divider()
            NowPlayingBar()
                .zIndex(1)
        }
        .frame(minWidth: 820, minHeight: 460)
        .capturingSettingsOpener()
        .onChange(of: player.videoWindowRequest) { _ in
            openWindow(id: "video")
        }
        .overlay(alignment: .top) {
            if !FFmpeg.isAvailable {
                FFmpegMissingBanner()
            } else if let problem = player.airPlayProblem {
                AirPlayProblemBanner(text: problem)
            }
        }
    }
}

private struct AirPlayProblemBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Network Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }
}

private struct FFmpegMissingBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Driftcast's built-in media engine (ffmpeg) is missing or can't run on this Mac. Reinstall Driftcast, or choose an ffmpeg folder in Settings.")
                .font(.callout)
            Button("Settings…") { SettingsOpener.open() }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }
}


/// The "nothing here yet" message: an icon, a title, a line of explanation and optional buttons.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            actions().padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, systemImage: String, message: String? = nil) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// Opens the Settings window on any macOS: `openSettings` is the only way from macOS 14 on
/// and doesn't exist before it, where the classic menu action does the job.
@MainActor
enum SettingsOpener {
    static var action: (() -> Void)?

    static func open() {
        if let action {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@available(macOS 14.0, *)
private struct SettingsOpenerCapture: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear { SettingsOpener.action = { openSettings() } }
    }
}

extension View {
    /// Put once on the main window so `SettingsOpener` can reach SwiftUI's action.
    func capturingSettingsOpener() -> some View {
        background {
            if #available(macOS 14.0, *) { SettingsOpenerCapture() }
        }
    }
}
