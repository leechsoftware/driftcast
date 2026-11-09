import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    /// Address of the device that made the request ("" when unknown).
    var remote = ""

    static func parse(_ head: Data) -> HTTPRequest? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path
        var req = HTTPRequest(method: String(parts[0]).uppercased(), path: path, headers: headers)
        if parts.count >= 3, parts[2] == "HTTP/1.0", headers["connection"]?.lowercased() != "keep-alive" {
            req.headers["connection"] = "close"
        }
        return req
    }
}

struct HTTPResponse: Sendable {
    enum Body: Sendable {
        case none
        case data(Data)
        case file(URL)
    }

    var status: Int
    var headers: [String: String] = [:]
    var body: Body = .none

    static let notFound = HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"], body: .data(Data("Not found".utf8)))

    static func text(_ s: String, type: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type, "Cache-Control": "no-cache"], body: .data(Data(s.utf8)))
    }

    static func file(_ url: URL, type: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": type], body: .file(url))
    }
}

/// Minimal HTTP/1.1 server on Network.framework: GET/HEAD/OPTIONS, byte ranges, keep-alive, CORS.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    var handler: Handler?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "driftcast.http.listener")
    private let lock = NSLock()
    private var _port: UInt16 = 0
    static let preferredPort: UInt16 = 48_100

    var port: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return _port
    }

    func start() {
        start(on: NWEndpoint.Port(rawValue: Self.preferredPort) ?? .any)
    }

    private func start(on port: NWEndpoint.Port) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            l.newConnectionHandler = { [weak self] conn in
                guard let self, let handler = self.handler else { conn.cancel(); return }
                HTTPConnection(connection: conn, handler: handler).start()
            }
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock(); self._port = l?.port?.rawValue ?? 0; self.lock.unlock()
                case .failed:
                    l?.cancel()
                    // Preferred port busy: let the system pick one.
                    if port != .any { self.start(on: .any) }
                default:
                    break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            if port != .any { start(on: .any) }
        }
    }

    func waitForPort() async -> UInt16 {
        for _ in 0..<100 {
            let p = port
            if p != 0 { return p }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return port
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: HTTPServer.Handler
    private let queue = DispatchQueue(label: "driftcast.http.connection")
    private var buffer = Data()
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let chunkSize = 1 << 20

    init(connection: NWConnection, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: connection.stateUpdateHandler = nil
            default: break
            }
        }
        connection.start(queue: queue)
        nextRequest()
    }

    private func close() { connection.cancel() }

    /// The caller's IP without port, interface scope or IPv4-in-IPv6 prefix.
    private var remoteAddress: String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "" }
        var text = "\(host)"
        if let scope = text.firstIndex(of: "%") { text = String(text[..<scope]) }
        if text.lowercased().hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        return text
    }

    private func nextRequest() {
        if let r = buffer.range(of: Self.headerEnd) {
            let head = buffer[..<r.lowerBound]
            buffer.removeSubrange(..<r.upperBound)
            guard var req = HTTPRequest.parse(Data(head)) else { close(); return }
            req.remote = remoteAddress
            let handler = self.handler
            Task {
                let resp = await handler(req)
                self.queue.async { self.send(resp, for: req) }
            }
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if error != nil || buffer.count > 64 * 1024 { close(); return }
            if complete && buffer.range(of: Self.headerEnd) == nil { close(); return }
            nextRequest()
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    private func send(_ response: HTTPResponse, for req: HTTPRequest) {
        let keepAlive = req.headers["connection"]?.lowercased() != "close"
        var status = response.status
        var headers = response.headers
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Methods"] = "GET, HEAD, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Content-Type, Range, Accept-Encoding"
        headers["Access-Control-Expose-Headers"] = "Content-Length, Content-Range, Accept-Ranges"
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
        headers["Server"] = "Driftcast"

        var fileRange: (url: URL, start: UInt64, length: UInt64)?
        var bodyData: Data?

        switch response.body {
        case .none:
            headers["Content-Length"] = "0"
        case .data(let d):
            // Players sometimes ask for part of an init segment or a playlist with a Range
            // header; honouring it is cheap and some refuse a 200 when they asked for a 206.
            let size = UInt64(d.count)
            headers["Accept-Ranges"] = "bytes"
            if let range = req.headers["range"], let (s, e) = Self.parseRange(range, size: size) {
                if s >= size || e < s {
                    status = 416
                    headers["Content-Range"] = "bytes */\(size)"
                    headers["Content-Length"] = "0"
                } else {
                    status = 206
                    headers["Content-Range"] = "bytes \(s)-\(e)/\(size)"
                    let slice = d.subdata(in: Int(s)..<Int(e + 1))
                    headers["Content-Length"] = "\(slice.count)"
                    bodyData = slice
                }
            } else {
                headers["Content-Length"] = "\(d.count)"
                bodyData = d
            }
        case .file(let url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            headers["Accept-Ranges"] = "bytes"
            if let range = req.headers["range"], let (s, e) = Self.parseRange(range, size: size) {
                if s >= size || e < s {
                    status = 416
                    headers["Content-Range"] = "bytes */\(size)"
                    headers["Content-Length"] = "0"
                } else {
                    status = 206
                    headers["Content-Range"] = "bytes \(s)-\(e)/\(size)"
                    headers["Content-Length"] = "\(e - s + 1)"
                    fileRange = (url, s, e - s + 1)
                }
            } else {
                headers["Content-Length"] = "\(size)"
                fileRange = (url, 0, size)
            }
        }

        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        let isHead = req.method == "HEAD"

        connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] error in
            if error != nil { close(); return }
            if isHead { finish(keepAlive); return }
            if let d = bodyData {
                connection.send(content: d, completion: .contentProcessed { [self] err in
                    if err != nil { close() } else { finish(keepAlive) }
                })
            } else if let f = fileRange {
                sendFile(f.url, from: f.start, length: f.length) { [self] ok in
                    if ok { finish(keepAlive) } else { close() }
                }
            } else {
                finish(keepAlive)
            }
        })
    }

    private func finish(_ keepAlive: Bool) {
        if keepAlive { nextRequest() } else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in close() })
        }
    }

    private func sendFile(_ url: URL, from start: UInt64, length: UInt64, done: @escaping (Bool) -> Void) {
        guard length > 0 else { done(true); return }
        guard let fh = try? FileHandle(forReadingFrom: url) else { done(false); return }
        do { try fh.seek(toOffset: start) } catch { try? fh.close(); done(false); return }
        var remaining = length

        func pump() {
            if remaining == 0 { try? fh.close(); done(true); return }
            let n = Int(min(remaining, UInt64(Self.chunkSize)))
            let chunk = (try? fh.read(upToCount: n)) ?? Data()
            if chunk.isEmpty { try? fh.close(); done(false); return }
            remaining -= UInt64(chunk.count)
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? fh.close(); done(false) } else { pump() }
            })
        }
        pump()
    }

    /// "bytes=0-499", "bytes=500-", "bytes=-500" -> inclusive (start, end).
    static func parseRange(_ header: String, size: UInt64) -> (UInt64, UInt64)? {
        guard header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, size > 0 else { return nil }
        if parts[0].isEmpty, let suffix = UInt64(parts[1]) {
            let len = min(suffix, size)
            return (size - len, size - 1)
        }
        guard let s = UInt64(parts[0]) else { return nil }
        let e = UInt64(parts[1]).map { min($0, size - 1) } ?? size - 1
        return (s, e)
    }
}
