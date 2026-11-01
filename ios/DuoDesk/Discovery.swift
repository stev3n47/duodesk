// Discovery.swift — UDP beacons / probes / invites on P.DISCOVERY_PORT.
// Matches shared/protocol.js: every peer broadcasts a beacon every BEACON_MS; a probe
// elicits a unicast beacon back. The host listens; we're the guest, so mostly we listen,
// but we also send a probe when we come to the foreground.
//
// Needs com.apple.developer.networking.multicast + NSLocalNetworkUsageDescription + the
// _duodesk._udp service listed in NSBonjourServices. Without all three the listener
// silently fails.

import Foundation
import Network

struct DiscoveredDevice: Identifiable, Equatable, Hashable {
    let id: String        // the peer's protocol id
    var name: String
    var os: String
    var address: String   // IP string
    var port: UInt16
    var fp: String
    var role: String      // "host" or "guest"
    var seenAt: Date
}

@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var running = false

    private var listener: NWListener?
    private var broadcaster: NWConnection?
    private var pruneTimer: Timer?

    func start() {
        guard !running else { return }
        running = true

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: P.DISCOVERY_PORT)!)
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                Task { @MainActor in self?.receive(on: conn, remember: true) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            running = false
            return
        }

        // Broadcast connection that we reuse to send probes.
        let b = NWConnection(host: "255.255.255.255",
                             port: NWEndpoint.Port(rawValue: P.DISCOVERY_PORT)!,
                             using: .udp)
        b.start(queue: .main)
        broadcaster = b

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }

        sendProbe()
    }

    func stop() {
        running = false
        listener?.cancel()
        listener = nil
        broadcaster?.cancel()
        broadcaster = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    /// Ask any host nearby to answer with its beacon. Called at launch and on return to foreground.
    func sendProbe() {
        guard let b = broadcaster else { return }
        let probe: [String: Any] = [
            "t": P.T.PROBE,
            "v": P.PROTOCOL_VERSION,
            "id": Store.shared.selfId,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: probe) else { return }
        b.send(content: data, completion: .idempotent)
    }

    // MARK: - Receive

    private func receive(on conn: NWConnection, remember: Bool) {
        conn.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                if let data, !data.isEmpty { self?.handle(datagram: data, from: conn) }
                if error == nil { self?.receive(on: conn, remember: remember) }
            }
        }
    }

    private func handle(datagram data: Data, from conn: NWConnection) {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let msg = any as? [String: Any],
              let t = msg["t"] as? String
        else { return }

        // Drop packets we sent ourselves. The protocol pins by peer id, not by address.
        if (msg["id"] as? String) == Store.shared.selfId { return }

        switch t {
        case P.T.BEACON, P.T.INVITE:
            guard
                let id = msg["id"] as? String,
                let name = msg["name"] as? String,
                let os = msg["os"] as? String,
                let port = msg["port"] as? Int,
                let fp = msg["fp"] as? String
            else { return }
            let role = (msg["role"] as? String) ?? "host"
            let address = Discovery.endpointAddress(conn.endpoint) ?? "unknown"
            let device = DiscoveredDevice(
                id: id,
                name: name,
                os: os,
                address: address,
                port: UInt16(port),
                fp: P.normFingerprint(fp),
                role: role,
                seenAt: Date()
            )
            upsert(device)
            // Keep paired-host records fresh with the newest address we see.
            Store.shared.update(hostId: id, address: address, port: UInt16(port), lastSeen: Date())
        case P.T.PROBE:
            // We're a guest; we don't advertise a host beacon.
            break
        default:
            break
        }
    }

    private func upsert(_ dev: DiscoveredDevice) {
        if let i = devices.firstIndex(where: { $0.id == dev.id }) {
            devices[i] = dev
        } else {
            devices.append(dev)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(P.DEVICE_STALE_MS) / 1000.0)
        devices.removeAll { $0.seenAt < cutoff }
    }

    private static func endpointAddress(_ endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .name(let n, _): return n
            case .ipv4(let ip): return "\(ip)"
            case .ipv6(let ip): return "\(ip)"
            @unknown default: return nil
            }
        default:
            return nil
        }
    }
}
