import Darwin
import Foundation
import os
import SystemConfiguration

/// Serves the active stream sessions over HTTP so Chromecast / Apple TV can fetch them.
///
/// Paths (each session has a random id, so nothing else on disk is reachable):
///   /s/<id>/media.<ext>   original file, byte ranges (direct play)
///   /s/<id>/master.m3u8   HLS master with an optional subtitle rendition (AVPlayer / AirPlay)
///   /s/<id>/cast.m3u8     HLS master with CODECS and RESOLUTION attributes (Chromecast)
///   /s/<id>/poster.jpg    artwork for the Chromecast's loading and pause screens
///   /s/<id>/stream.m3u8   complete VOD media playlist (built before conversion starts)
///   /s/<id>/init.mp4, seg00000.m4s ...   produced on demand, see StreamSession
///   /s/<id>/intro-init.mp4, intro-0.m4s   the title card clip (this Mac / AirPlay)
///   /s/<id>/subs.vtt      whole subtitle file (Chromecast text track)
///   /s/<id>/subs.m3u8, subs-N.vtt   segmented subtitles (AVPlayer)
final class MediaServer: @unchecked Sendable {
    static let shared = MediaServer()

    private let http = HTTPServer()
    private let lock = NSLock()
    private var sessions: [String: StreamSession] = [:]
    private var _lastDeviceRequest: Date?
    private var ownAddresses: Set<String> = []
    private var ownAddressesRead = Date.distantPast

    /// When a TV or Chromecast (anything but this Mac) last fetched part of a stream. AVPlayer
    /// on this Mac also uses the server, so requests from our own addresses don't count.
    var lastDeviceRequest: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastDeviceRequest
    }

    private func noteRequest(from remote: String) {
        guard !remote.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(ownAddressesRead) > 30 {
            ownAddresses = NetworkUtil.localAddresses()
            ownAddressesRead = Date()
        }
        if !ownAddresses.contains(remote) { _lastDeviceRequest = Date() }
    }

    func start() {
        http.handler = { [weak self] req in
            guard let self else { return .notFound }
            return await self.respond(req)
        }
        http.start()
    }

    func register(_ session: StreamSession) {
        lock.lock(); sessions[session.id] = session; lock.unlock()
    }

    func unregister(_ session: StreamSession) {
        lock.lock(); sessions[session.id] = nil; lock.unlock()
    }

    private func session(_ id: String) -> StreamSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    func url(path: String, host: String) async -> URL {
        let port = await http.waitForPort()
        return URL(string: "http://\(host):\(port)\(path)")!
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "m4s": return "video/iso.segment"
        case "vtt": return "text/vtt; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// Every request a device makes is logged (Console: subsystem com.leechsoftware.driftcast),
    /// which is the only way to see what a TV asked for when it shows nothing.
    private static let log = Logger(subsystem: "com.leechsoftware.driftcast", category: "server")

    private func respond(_ req: HTTPRequest) async -> HTTPResponse {
        let started = Date()
        noteRequest(from: req.remote)
        let resp = await route(req)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let agent = req.headers["user-agent"] ?? "-"
        let range = req.headers["range"] ?? "-"
        Self.log.info("\(req.method, privacy: .public) \(req.path, privacy: .public) -> \(resp.status) in \(ms) ms, range \(range, privacy: .public), from \(req.remote, privacy: .public), agent \(agent, privacy: .public)")
        return resp
    }

    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        if req.method == "OPTIONS" { return HTTPResponse(status: 204) }
        guard req.method == "GET" || req.method == "HEAD" else { return .notFound }
        let comps = req.path.split(separator: "/").map(String.init)
        guard comps.count == 3, comps[0] == "s", let session = session(comps[1]) else { return .notFound }
        let name = comps[2]
        guard !name.contains(".."), !name.contains("\\") else { return .notFound }

        if name.hasPrefix("media.") {
            return .file(session.source, type: Self.contentType(forExtension: session.source.pathExtension))
        }
        switch name {
        case "master.m3u8":
            return .text(session.masterPlaylist(), type: Self.contentType(forExtension: "m3u8"))
        case "cast.m3u8":
            guard let text = session.castPlaylist() else { return .notFound }
            return .text(text, type: Self.contentType(forExtension: "m3u8"))
        case "poster.jpg":
            guard let data = session.poster else { return .notFound }
            return HTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: .data(data))
        case "intro-init.mp4":
            guard let data = session.introInit() else { return .notFound }
            return HTTPResponse(status: 200, headers: ["Content-Type": "video/mp4"], body: .data(data))
        case "intro-0.m4s":
            guard let data = session.introSegment() else { return .notFound }
            return HTTPResponse(status: 200, headers: ["Content-Type": Self.contentType(forExtension: "m4s")], body: .data(data))
        case "stream.m3u8":
            guard let text = session.mediaPlaylist() else { return .notFound }
            return .text(text, type: Self.contentType(forExtension: "m3u8"))
        case "init.mp4":
            guard let data = session.initSegment() else { return HTTPResponse(status: 503) }
            return HTTPResponse(status: 200, headers: ["Content-Type": "video/mp4"], body: .data(data))
        case "subs.vtt":
            return .text(session.subtitleDocument(), type: Self.contentType(forExtension: "vtt"))
        case "subs.m3u8":
            return .text(session.subtitlePlaylist(), type: Self.contentType(forExtension: "m3u8"))
        case "subs-card.vtt":
            return .text(session.subtitleCard(), type: Self.contentType(forExtension: "vtt"))
        default:
            break
        }
        if name.hasPrefix("subs-"), name.hasSuffix(".vtt"), let n = Int(name.dropFirst(5).dropLast(4)) {
            return .text(session.subtitleSegment(n), type: Self.contentType(forExtension: "vtt"))
        }

        // Media segment: produced (and rebased onto the stream timeline) on demand.
        if name.hasPrefix("seg"), name.hasSuffix(".m4s"), let n = Int(name.dropFirst(3).dropLast(4)) {
            do {
                let data = try await session.segment(n)
                return HTTPResponse(status: 200, headers: ["Content-Type": Self.contentType(forExtension: "m4s")], body: .data(data))
            } catch {
                return HTTPResponse(status: 503, headers: ["Content-Type": "text/plain"], body: .data(Data(error.localizedDescription.utf8)))
            }
        }
        return .notFound
    }
}

enum NetworkUtil {
    /// Every address this Mac answers to, loopback included, as plain text.
    static func localAddresses() -> Set<String> {
        var result: Set<String> = ["127.0.0.1", "::1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var ip = String(cString: host)
            if let scope = ip.firstIndex(of: "%") { ip = String(ip[..<scope]) }
            result.insert(ip)
        }
        return result
    }

    /// The interface macOS routes through by default ("en0"), from the system configuration
    /// store, which follows the service order in Network Settings.
    static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Driftcast" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return global["PrimaryInterface"] as? String
    }

    /// Interfaces that reach other networks rather than the home network: VPNs and the like.
    static func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp", "gif", "stf", "tap", "tun", "awdl", "llw", "bridge", "vmnet", "vnic"].contains { name.hasPrefix($0) }
    }

    /// The Mac's LAN IPv4 address: the address of the primary interface when it is a real
    /// network link, else the first live Wi-Fi / Ethernet (en*) address, never a VPN tunnel
    /// unless nothing else is up. A TV or Chromecast fetches the video from this address, so
    /// an unplugged Ethernet port or a VPN picked here would leave the TV waiting forever.
    static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            // RUNNING tells an unplugged Ethernet port (still UP) from one that carries traffic.
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            candidates.append((String(cString: ptr.pointee.ifa_name), ip))
        }
        if let primary = primaryInterfaceName(), !isTunnel(primary), let match = candidates.first(where: { $0.name == primary }) {
            return match.ip
        }
        return candidates.first { $0.name.hasPrefix("en") }?.ip
            ?? candidates.first { !isTunnel($0.name) }?.ip
            ?? candidates.first?.ip
    }
}
