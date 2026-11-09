import AppKit
import SwiftUI

/// The About window: who makes Driftcast, how it works, what it plays and needs, and that it
/// is free and open to changes. An AppKit window rather than a SwiftUI scene so that it is
/// never reopened by itself at launch.
@MainActor
final class AboutWindow {
    static let shared = AboutWindow()

    static let website = URL(string: "https://leechsoftware.com")!

    /// The project's page on GitHub, once it has one (`UpdateConfig.repository`).
    static var sourceURL: URL? {
        UpdateConfig.repositoryPath.flatMap { URL(string: "https://github.com/\($0)") }
    }

    /// The licence texts copied into the app by the build.
    static func licenceFile(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses/\(name)"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            host.sizingOptions = []   // the window's size is the person's to change
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "About Driftcast"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 420)
            // Big, but never taller than a small laptop's screen.
            let room = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 720, height: min(860, room - 60)))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    @ObservedObject private var updater = Updater.shared

    private var updateWords: String? {
        switch updater.status {
        case .unknown: return nil
        case .checking: return "Checking GitHub\u{2026}"
        case .upToDate: return "You have the newest version"
        case .available(let release): return "Version \(release.version) is available"
        case .failed: return "Couldn't reach GitHub"
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("How it works", "arrow.triangle.branch") {
                        para("Driftcast runs a small media server on this Mac. Your Chromecast, Apple TV or AirPlay TV fetches the video from it over your home network, so the picture never goes through the internet.")
                        para("It changes as little as it can. A file the device already plays is sent untouched. When only the file type is the problem, such as an MKV, the video and sound are repackaged without re-encoding, which loses no quality and uses almost no processor time. Only a video or sound format the device can't play is converted, on the fly, with the built-in FFmpeg.")
                    }
                    section("What it plays", "film") {
                        row("Files", "MKV, MP4, MOV, AVI, WMV, TS, WebM, VOB and nearly anything else FFmpeg reads.")
                        row("Video", "H.264 and HEVC are sent as they are, including 4K, HDR10 and Dolby Vision on devices that support them, and so are VP8, VP9 and AV1 on Chromecasts that play them. Anything else, such as MPEG-2, MPEG-4, VC-1 or WMV, is converted to H.264, normally with the Mac's hardware encoder. HDR is converted to standard range for devices without HDR.")
                        row("Sound", "AAC, MP3 and FLAC are passed through, and so is Dolby Digital / Digital Plus (including Atmos) to an Apple TV or AirPlay TV. DTS and Dolby TrueHD become Dolby Digital Plus 5.1 or lossless FLAC. A Chromecast gets stereo AAC or Opus unless surround passthrough is turned on in Settings.")
                        row("Subtitles", "SRT, ASS and WebVTT files and subtitle tracks inside the video. Picture subtitles from Blu-ray and DVD (PGS, VobSub) are read into text. OpenSubtitles search is built in.")
                    }
                    section("Film and show details", "star") {
                        para("The details panel shows each video's poster, plot, director, writers, cast, genres, age rating and running time, and for an episode its show, number, name and synopsis. Films come from Wikipedia and Wikidata and shows from TVmaze, with no account needed; a free OMDb key adds IMDb, Rotten Tomatoes and Metacritic ratings. Only the title read from the file name is sent, and the lookup can be turned off in Settings > General.")
                    }
                    section("What you need", "desktopcomputer") {
                        bullet("macOS 13 Ventura or later, on an Apple silicon or Intel Mac.")
                        bullet("A Chromecast or Google TV device, an Apple TV, or a TV with AirPlay 2 (Samsung, LG, Sony, Roku and others).")
                        bullet("The Mac and the TV on the same home network.")
                        bullet("Nothing else to install: FFmpeg is inside the app.")
                    }
                    section("Good to know", "lightbulb") {
                        bullet("The first time, macOS asks whether Driftcast may find devices on your local network. Choose Allow, or no device will appear.")
                        bullet("For AirPlay, choose \"Apple TV or AirPlay TV…\" in the output menu at the top of the window. AirPlay has to be turned on in the TV's settings, and the TV may show a code to type on the Mac the first time.")
                        bullet("If the TV connects but nothing plays, check that both are on the same Wi-Fi network, turn off any VPN on this Mac, and allow Driftcast under System Settings > Network > Firewall > Options.")
                        bullet("Keep the Mac on and its lid open while watching: the video comes from this Mac. Driftcast keeps it awake while a video is playing.")
                        bullet("Chromecast support has had less testing than AirPlay. If something doesn't work, please report it.")
                    }
                    section("Free and open", "heart") {
                        para("Driftcast is freeware: free to use, with no trial, no ads, no account and no time limit.")
                        para("It is also open source, under the GNU General Public License, version 3. You are encouraged to fix things, add features and submit your changes yourself on GitHub.")
                        if let source = AboutWindow.sourceURL {
                            Link("Driftcast on GitHub", destination: source)
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    credits
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Keeps a real scrollbar on the window, for a mouse with no wheel.
                .background(ScrollObserver { _ in })
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 3) {
                Text("Driftcast")
                    .font(.system(size: 26, weight: .bold))
                Text(version)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("by")
                    Link("Leech Software", destination: AboutWindow.website)
                        .help("Open leechsoftware.com")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.top, 2)
                Link("leechsoftware.com", destination: AboutWindow.website)
                    .font(.system(size: 12))
                Text("Plays the videos on your Mac on a Chromecast, Apple TV or AirPlay TV.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Check for Updates\u{2026}") { updater.checkNow() }
                    .disabled(updater.status == .checking)
                if let updateWords {
                    Text(updateWords)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Copyright © 2026 Leech Software, Inc.")
                .font(.system(size: 11, weight: .medium))
            Text("Driftcast includes FFmpeg (ffmpeg.org), with x264 and x265, under the GNU General Public License, and subtitle reading code from macSubtitleOCR by Ethan Dye under the MIT License. It comes with no warranty.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Chromecast and Google TV are trademarks of Google LLC. AirPlay, Apple TV and Mac are trademarks of Apple Inc. Dolby is a trademark of Dolby Laboratories. Driftcast is not affiliated with or endorsed by any of them.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let licence = AboutWindow.licenceFile("LICENSE.txt") {
                    Button("Licence") { NSWorkspace.shared.open(licence) }
                }
                if let notice = AboutWindow.licenceFile("NOTICE.txt") {
                    Button("Acknowledgements") { NSWorkspace.shared.open(notice) }
                }
                Spacer()
                Button("Visit leechsoftware.com") { NSWorkspace.shared.open(AboutWindow.website) }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func section<Content: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
            content()
        }
    }

    private func para(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ name: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 62, alignment: .leading)
            para(text)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2022}")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            para(text)
        }
    }
}

/// The app menu's first group: About Driftcast and the update check.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Driftcast") { AboutWindow.shared.show() }
            Button("Check for Updates…") { Updater.shared.checkNow() }
        }
    }
}
