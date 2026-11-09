import Foundation
import Security

/// Installs a newer copy of Driftcast over the running one: download, unpack, prove the new copy
/// really is Driftcast from Leech Software, then quit and let a small script swap the two and
/// open the new one. Until the swap every step works in a folder beside the app, so a failure at
/// any point leaves the installed copy exactly as it was.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case download(String)
        case badArchive
        case wrongApp
        case notSigned
        case notNewer
        case needsNewerMac(String)
        case cantReplace

        var errorDescription: String? {
            switch self {
            case .download(let why): return "The update couldn't be downloaded (\(why))."
            case .badArchive: return "The downloaded update couldn't be opened."
            case .wrongApp: return "The downloaded file isn't Driftcast."
            case .notSigned: return "The downloaded update isn't signed by Leech Software, so it wasn't installed."
            case .notNewer: return "The downloaded update isn't newer than this copy."
            case .needsNewerMac(let version): return "This update needs macOS \(version) or later."
            case .cantReplace: return "Driftcast can't replace itself where it is now. Move it to your Applications folder and try again, or download the update yourself."
            }
        }
    }

    /// A Developer ID signature from this team on this app, and nothing else. Apple's chain of
    /// trust is what makes this meaningful: a file swapped in on the way here can't satisfy it.
    static let requirement = """
    identifier "com.leechsoftware.driftcast" and anchor apple generic \
    and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
    and certificate leaf[subject.OU] = "CBAE6JXBHC"
    """

    /// A new copy that has passed every check and is ready to be swapped in.
    struct Prepared: Sendable {
        var installed: URL
        var replacement: URL
        var staging: URL
    }

    /// Only a zip can be installed in place; anything else goes to the browser.
    static func canInstall(_ release: AppRelease) -> Bool {
        release.download?.pathExtension.lowercased() == "zip"
    }

    /// Throws unless the app at `app` can be replaced: it can't when macOS is running it from a
    /// temporary read-only copy (opened straight from Downloads), from a disk image, or from a
    /// folder this user can't write to.
    static func checkReplaceable(_ app: URL) throws {
        let fm = FileManager.default
        let parent = app.deletingLastPathComponent()
        let readOnly = (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? true
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/"), !readOnly,
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: app.path) else { throw Failure.cantReplace }
    }

    /// Downloads and checks a new copy. Nothing outside the staging folder is touched.
    static func prepare(download source: URL, replacing app: URL, newerThan installed: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Prepared {
        try checkReplaceable(app)
        // Beside the app so that the swap is a rename on one volume, not a slow, breakable copy.
        let staging = app.deletingLastPathComponent().appendingPathComponent(".driftcast-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let zip = staging.appendingPathComponent("update.zip")
            try await download(source, to: zip, progress: progress)
            let replacement = try await unpack(zip, into: staging)
            try? FileManager.default.removeItem(at: zip)
            try await Task.detached(priority: .userInitiated) { try verify(replacement, newerThan: installed) }.value
            return Prepared(installed: app, replacement: replacement, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func download(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: source)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Unpacks the zip and returns the one app inside it.
    static func unpack(_ zip: URL, into folder: URL) async throws -> URL {
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        do {
            _ = try await FFmpeg.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path])
        } catch {
            throw Failure.badArchive
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        let apps = items.filter { $0.pathExtension == "app" }
        guard apps.count == 1 else { throw Failure.badArchive }
        return apps[0]
    }

    /// The checks that make it safe to run what was downloaded.
    static func verify(_ app: URL, newerThan installed: String) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary,
              bundle.bundleIdentifier == "com.leechsoftware.driftcast" else { throw Failure.wrongApp }

        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess else { throw Failure.notSigned }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw Failure.notSigned }

        guard AppVersion.isNewer(info["CFBundleShortVersionString"] as? String ?? "0", than: installed) else { throw Failure.notNewer }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = AppVersion.components(minimum)
            let needed = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) else { throw Failure.needsNewerMac(minimum) }
        }
    }

    /// Waits for the process to end, swaps the copies by renaming, and opens whichever is then
    /// installed. If the new copy can't be moved in, the old one goes straight back.
    static let swapScript = #"""
    pid="$1"; app="$2"; new="$3"; staging="$4"; opener="$5"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        waited=$((waited + 1))
        if [ "$waited" -gt 300 ]; then rm -rf "$staging"; exit 1; fi
        sleep 0.1
    done
    old="$staging/previous.app"
    if mv "$app" "$old"; then
        mv "$new" "$app" || mv "$old" "$app"
    fi
    rm -rf "$staging"
    "$opener" "$app"
    """#

    /// Starts the script that finishes the job once this process has quit. It carries on by
    /// itself after Driftcast has gone. `opener` is what opens the app afterwards.
    static func swapAfterExit(_ prepared: Prepared, of pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                              opener: String = "/usr/bin/open") throws {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", swapScript, "driftcast-update", String(pid),
                            prepared.installed.path, prepared.replacement.path, prepared.staging.path, opener]
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var failure: Error?
    private var _continuation: CheckedContinuation<Void, Error>?

    var continuation: CheckedContinuation<Void, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return _continuation }
        set { lock.lock(); _continuation = newValue; lock.unlock() }
    }

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file vanishes when this returns, so it has to be moved here.
        lock.lock(); defer { lock.unlock() }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = UpdateInstaller.Failure.download("the server answered \(http.statusCode)")
            return
        }
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiting = _continuation
        _continuation = nil
        let outcome = error ?? failure
        lock.unlock()
        if let outcome {
            if (outcome as? URLError)?.code == .cancelled { waiting?.resume(throwing: CancellationError()); return }
            waiting?.resume(throwing: outcome is UpdateInstaller.Failure ? outcome : UpdateInstaller.Failure.download(outcome.localizedDescription))
        } else {
            waiting?.resume()
        }
    }
}
