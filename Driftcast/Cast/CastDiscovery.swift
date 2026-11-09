import Foundation
import Network

struct CastDeviceInfo: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var model: String
    var endpoint: NWEndpoint
    /// The TXT record's `ca` bitmask: 1 video out, 4 audio out, 32 speaker group.
    var capabilities: Int?

    static let videoOut = 1
    static let audioOut = 4
    static let multizoneGroup = 32

    static func == (a: CastDeviceInfo, b: CastDeviceInfo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isGroup: Bool {
        if let capabilities { return capabilities & Self.multizoneGroup != 0 }
        return model.lowercased().contains("group")
    }
    var isAudioOnly: Bool { Self.isAudioOnly(model: model, capabilities: capabilities) }
    var symbol: String {
        if isGroup { return "hifispeaker.2" }
        return isAudioOnly ? "hifispeaker" : "tv"
    }

    /// Chromecast Audio, Google Home / Nest speakers and cast groups have no screen; Nest Hubs
    /// do, and play video. The device says so itself in its `ca` flags; the model name is the
    /// fallback for records without them.
    static func isAudioOnly(model: String, capabilities: Int? = nil) -> Bool {
        if let capabilities, capabilities != 0 { return capabilities & videoOut == 0 }
        let m = model.lowercased()
        if m.contains("hub") || m.contains("display") { return false }
        return m.contains("group") || m.contains("audio") || m.contains("speaker") || m.contains("nest") || m.contains("home")
            || m.contains("soundbar") || m.contains("link") || m.contains("stanmore")
    }
}

/// Browses Bonjour for `_googlecast._tcp`. The TXT record carries `fn` (friendly name),
/// `md` (model), `id` (stable device id) and `ca` (capability flags).
@MainActor
final class CastDiscovery: ObservableObject {
    @Published var devices: [CastDeviceInfo] = []
    @Published var isBrowsing = false
    @Published var problem: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var byID: [String: CastDeviceInfo] = [:]
            for r in results {
                guard case .service(let serviceName, _, _, _) = r.endpoint else { continue }
                var name = serviceName, model = "Chromecast", id = serviceName
                var capabilities: Int?
                if case .bonjour(let txt) = r.metadata {
                    name = txt["fn"] ?? name
                    model = txt["md"] ?? model
                    id = txt["id"] ?? id
                    capabilities = txt["ca"].flatMap { Int($0) }
                }
                byID[id] = CastDeviceInfo(id: id, name: name, model: model, endpoint: r.endpoint, capabilities: capabilities)
            }
            let list = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.devices = list }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.isBrowsing = true; self?.problem = nil
                case .failed(let e): self?.isBrowsing = false; self?.problem = e.localizedDescription
                case .waiting(let e): self?.problem = e.localizedDescription
                default: break
                }
            }
        }
        browser = b
        b.start(queue: .main)
    }

    func restart() {
        browser?.cancel()
        browser = nil
        devices = []
        start()
    }
}
