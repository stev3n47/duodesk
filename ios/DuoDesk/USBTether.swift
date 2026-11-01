// USBTether.swift — accept a WSS session over USB.
//
// Mechanism: the PC runs `usbmuxd` (built into macOS, part of libimobiledevice on
// Linux/Windows). The PC's DuoDesk daemon opens a TCP channel through usbmuxd to this
// iOS listener; from the socket's view it's just localhost. iOS has no USB-attach
// notification public API, so we always listen while the companion is foreground and let
// the PC decide when to dial in.
//
// This listener terminates the WSS/TLS inside Link.swift the same way the Wi-Fi path does;
// the only difference is that `host.address` from the PC side is 127.0.0.1 and the port is
// whatever usbmuxd forwarded.

import Foundation
import Network

@MainActor
final class USBTether: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var activeConnections = 0

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    func start() {
        guard !listening else { return }
        do {
            let params = NWParameters(tls: nil, tcp: .init())
            params.allowLocalEndpointReuse = true
            // Loopback only — iOS cannot bind to anything else via usbmuxd anyway.
            params.requiredInterfaceType = .loopback

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: P.PORT)!)
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
            listening = true
        } catch {
            listening = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listening = false
        activeConnections = 0
    }

    private func accept(_ conn: NWConnection) {
        let id = UUID()
        connections[id] = conn
        activeConnections = connections.count
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    // Phase 1: just hold the socket open; Link.swift will take ownership
                    // when we wire USB as a Link transport in Phase 2.
                    break
                case .failed, .cancelled:
                    self.connections.removeValue(forKey: id)
                    self.activeConnections = self.connections.count
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }
}
