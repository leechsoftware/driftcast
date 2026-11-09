import Foundation
import Network

/// Google Cast v2 wire format: TLS to port 8009, each message a 4-byte big-endian length
/// followed by a protobuf `CastMessage` (see cast_channel.proto in Chromium):
///
///   1 protocol_version  enum   (0 = CASTV2_1_0)
///   2 source_id         string
///   3 destination_id    string
///   4 namespace         string
///   5 payload_type      enum   (0 = STRING, 1 = BINARY)
///   6 payload_utf8      string
///   7 payload_binary    bytes
///
/// The message is small and fixed, so it's encoded by hand instead of pulling in swift-protobuf.
enum CastProto {
    struct Message: Sendable {
        var source: String
        var destination: String
        var namespace: String
        var payload: String?
    }

    static func encode(source: String, destination: String, namespace: String, payload: String) -> Data {
        var d = Data()
        func varint(_ value: UInt64) {
            var v = value
            while v >= 0x80 { d.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            d.append(UInt8(v))
        }
        func key(_ field: UInt64, _ wire: UInt64) { varint(field << 3 | wire) }
        func string(_ field: UInt64, _ s: String) {
            let bytes = Data(s.utf8)
            key(field, 2); varint(UInt64(bytes.count)); d.append(bytes)
        }
        key(1, 0); varint(0)
        string(2, source)
        string(3, destination)
        string(4, namespace)
        key(5, 0); varint(0)
        string(6, payload)
        return d
    }

    static func decode(_ data: Data) -> Message? {
        let bytes = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        var msg = Message(source: "", destination: "", namespace: "", payload: nil)
        while i < bytes.count {
            guard let tag = varint() else { return nil }
            let field = tag >> 3, wire = tag & 7
            switch wire {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let len = varint(), i + Int(len) <= bytes.count else { return nil }
                let chunk = Data(bytes[i..<(i + Int(len))])
                i += Int(len)
                let s = String(decoding: chunk, as: UTF8.self)
                switch field {
                case 2: msg.source = s
                case 3: msg.destination = s
                case 4: msg.namespace = s
                case 6: msg.payload = s
                default: break
                }
            case 1: i += 8
            case 5: i += 4
            default: return nil
            }
        }
        return msg
    }
}

/// One TLS connection to a Cast device, delivering decoded messages.
final class CastChannel: @unchecked Sendable {
    enum Event: Sendable {
        case ready
        case failed(String)
    }

    var onMessage: (@Sendable (CastProto.Message) -> Void)?
    var onEvent: (@Sendable (Event) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "driftcast.cast.channel")
    private var closed = false

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // Cast devices present certificates signed by Google's device CA, not a public CA.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: tls, tcp: tcp)
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4 // media URLs we hand out are IPv4
        }
        connection = NWConnection(to: endpoint, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent?(.ready)
                self.readFrame()
            case .waiting:
                // Not a failure: the system is still resolving the device, or is waiting for
                // the person to allow local network access (macOS 15 asks the first time). The
                // connection goes on to ready or failed, and CastTarget has its own timeout.
                break
            case .failed(let error):
                self.fail(error.localizedDescription)
            case .cancelled:
                self.fail("Connection closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Our address as the device sees it; media URLs must use it.
    var localIPv4: String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else { return nil }
        if case .ipv4(let addr) = host {
            let s = "\(addr)"
            return String(s.split(separator: "%").first ?? Substring(s))
        }
        return nil
    }

    func send(namespace: String, destination: String, source: String = "sender-0", payload: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        let body = CastProto.encode(source: source, destination: destination, namespace: namespace, payload: text)
        var frame = Data()
        let len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: len) { frame.append(contentsOf: $0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        })
    }

    func close() {
        queue.async { [self] in
            closed = true
            connection.cancel()
        }
    }

    private func fail(_ reason: String) {
        if closed { return }
        closed = true
        connection.cancel()
        onEvent?(.failed(reason))
    }

    private func readFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.fail(error.localizedDescription); return }
            guard let data, data.count == 4 else {
                if isComplete { self.fail("Device closed the connection") }
                return
            }
            let length = data.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length < 1 << 20 else { self.fail("Bad frame length"); return }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                if let error { self.fail(error.localizedDescription); return }
                guard let body, body.count == length else { self.fail("Short frame"); return }
                if let msg = CastProto.decode(body) { self.onMessage?(msg) }
                self.readFrame()
            }
        }
    }
}
