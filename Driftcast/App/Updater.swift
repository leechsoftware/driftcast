import AppKit
import SwiftUI

/// Looks for a newer release on GitHub (`UpdateConfig.repository`) at launch and every eight
/// hours while running, and offers it in a dialog: Update Now (downloads it, checks it is
/// signed by Leech Software, closes Driftcast and reopens the new copy; see `UpdateInstaller`),
/// Remind Me Later (asked again eight hours on, or at the next launch) or Skip This Version
/// (never for that version). Automatic checking is switched in Settings > General.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case unknown
        case checking
        case upToDate
        case available(AppRelease)
        case failed
    }

    private enum Key {
        static let lastCheck = "updateLastCheck"
        static let skipped = "updateSkippedVersion"
    }

    /// How an update being installed is getting on (the dialog follows it).
    enum InstallProgress: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var install = InstallProgress.idle
    @Published private(set) var status: Status = .unknown
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date

    private var remindAfter: Date?
    private var remindTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var installTask: Task<Void, Never>?

    /// `-ShowAvailableUpdate YES` on the command line shows the dialog for a made-up version
    /// without touching the network, to see how it looks.
    static var showsMockedUpdate: Bool { UserDefaults.standard.bool(forKey: "ShowAvailableUpdate") }

    /// Whether there is anywhere to check; the menu item and the Settings section follow it.
    static var isAvailable: Bool { UpdateConfig.isConfigured || showsMockedUpdate || testUpdate != nil }

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.skipped) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skipped) }
    }

    /// Checks shortly after launch and then every eight hours, while automatic checks are on.
    func start() {
        guard Self.isAvailable, periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                if Prefs.bool(Prefs.autoUpdateCheck) { await self?.check(manual: false) }
                try? await Task.sleep(for: .seconds(UpdateConfig.checkInterval))
            }
        }
    }

    /// Check for Updates… and Check Now: a version skipped or put off earlier is offered
    /// again if it's still the newest, and the answer is always said, whatever it is.
    func checkNow() {
        guard Self.isAvailable else {
            say("No Updates Available", "This copy of Driftcast isn't linked to a release page on GitHub yet, so there is nothing to check.")
            return
        }
        skippedVersion = nil
        remindAfter = nil
        remindTask?.cancel()
        Task { await check(manual: true) }
    }

    static func lastCheckText(_ date: Date?) -> String {
        guard let date else { return "Last check: never" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return "Last check: \(f.string(from: date))"
    }

    private func check(manual: Bool) async {
        guard status != .checking else { return }
        status = .checking
        let outcome: GitHubReleases.Outcome
        if let zip = Self.testUpdate {
            outcome = .release(AppRelease(version: "9.9", page: URL(string: "https://github.com")!, download: zip))
        } else if Self.showsMockedUpdate {
            outcome = .release(AppRelease(version: "9.9", page: URL(string: "https://github.com")!, download: nil))
        } else if let repository = UpdateConfig.repositoryPath {
            outcome = await GitHubReleases.latest(repository: repository)
        } else {
            outcome = .failed
        }

        if outcome != .failed {
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: Key.lastCheck)
        }
        switch outcome {
        case .release(let release) where AppVersion.isNewer(release.version, than: AppVersion.installed):
            status = .available(release)
            present(activating: manual)
        case .release, .none:
            status = .upToDate
            if manual {
                say("No Updates Available", "Driftcast \(AppVersion.installed) is the newest version.")
            }
        case .failed:
            status = .failed
            if manual {
                say("Couldn't check for updates", "Check that this Mac is connected to the internet, then try again.")
            }
        }
    }

    private func say(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Forgets the dialog once it has gone, with its watcher.
    private func letGo() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }

    private func present(activating: Bool) {
        guard case .available(let release) = status else { return }
        if let window {
            if activating { window.makeKeyAndOrderFront(nil) }
            return
        }
        guard skippedVersion != release.version, remindAfter.map({ Date.now >= $0 }) ?? true else { return }

        install = .idle
        let view = UpdateDialogView(newVersion: release.version, installed: AppVersion.installed,
                                    canInstall: UpdateInstaller.canInstall(release)) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .install:
                self.installUpdate(release)
                return   // the dialog stays up to show how it is going
            case .cancelInstall:
                self.installTask?.cancel()
                self.install = .idle
                return
            case .browser:
                NSWorkspace.shared.open(release.download ?? release.page)
                // Not asked again this run: the download is on its way.
                self.remindAfter = .distantFuture
            case .later:
                self.remindAfter = Date.now.addingTimeInterval(UpdateConfig.checkInterval)
                self.remindTask?.cancel()
                self.remindTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(UpdateConfig.checkInterval))
                    guard !Task.isCancelled else { return }
                    self?.present(activating: false)
                }
            case .skip:
                self.skippedVersion = release.version
            }
            self.window?.close()
            self.letGo()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        // Shut with its own close button rather than a choice: let go of it all the same, or
        // the dialog would count as still open and no later check could show it again.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.letGo() }
        }
        window.center()
        window.level = .floating
        self.window = window
        if activating { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Fetches and checks the new copy, then quits; the script `UpdateInstaller` starts swaps
    /// the two and opens the new one. On any failure this copy simply carries on.
    private func installUpdate(_ release: AppRelease) {
        guard let source = release.download else { return }
        install = .downloading(0)
        installTask?.cancel()
        // Only what a DEBUG test run passes in may be older than the running copy.
        let newerThan = Self.testUpdate == nil ? AppVersion.installed : "0"
        installTask = Task { [weak self] in
            do {
                let prepared = try await UpdateInstaller.prepare(download: source, replacing: Bundle.main.bundleURL, newerThan: newerThan) { fraction in
                    Task { @MainActor in
                        if case .downloading = self?.install { self?.install = .downloading(fraction) }
                    }
                }
                try Task.checkCancellation()
                self?.install = .installing
                try UpdateInstaller.swapAfterExit(prepared)
                NSApp.terminate(nil)
            } catch is CancellationError {
                self?.install = .idle
            } catch {
                self?.install = .failed(error.localizedDescription)
            }
        }
    }

    /// DEBUG builds only: a local zip to install (`-UpdateTestZip /path`), to try the whole
    /// install without publishing a release.
    private static var testUpdate: URL? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "UpdateTestZip").map { URL(fileURLWithPath: $0) }
        #else
        return nil
        #endif
    }
}

/// The dialog's contents, laid out like the familiar update dialog: icon at the left, the
/// words beside it, buttons in a row.
struct UpdateDialogView: View {
    enum Choice { case install, cancelInstall, browser, later, skip }

    let newVersion: String
    let installed: String
    let canInstall: Bool
    let answer: (Choice) -> Void
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                // The system alert's own sizes: 13 bold, then 11 regular.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Update version \(newVersion) available")
                        .font(.system(size: 13, weight: .bold))
                    Text("You have Driftcast \(installed). Click \(canInstall ? "Update Now to install" : "Download Update to get") the new version.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(canInstall
                         ? "Driftcast will download the update, close and reopen by itself. Whatever is playing will stop."
                         : "The download opens in your browser. Quit Driftcast, then replace the old copy with the new one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            controls
                .controlSize(.large)
                .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private var controls: some View {
        switch updater.install {
        case .idle:
            HStack {
                Button("Skip This Version") { answer(.skip) }
                Spacer()
                Button("Remind Me Later") { answer(.later) }
                    .keyboardShortcut(.cancelAction)
                Button(canInstall ? "Update Now" : "Download Update") { answer(canInstall ? .install : .browser) }
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let fraction):
            HStack(spacing: 12) {
                ProgressView(value: fraction).controlSize(.regular)
                Text("Downloading \(Int(fraction * 100))%").font(.system(size: 11)).monospacedDigit().frame(width: 110, alignment: .leading)
                Button("Cancel") { answer(.cancelInstall) }
            }
        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Installing and reopening\u{2026}").font(.system(size: 11))
                Spacer()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Close") { answer(.later) }
                    Spacer()
                    Button("Download in Browser") { answer(.browser) }
                    Button("Try Again") { answer(.install) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
