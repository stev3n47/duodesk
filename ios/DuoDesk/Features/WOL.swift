// WOL.swift — send a Wake-on-LAN magic packet to a paired host's broadcast address.
// 6 bytes of 0xFF + MAC repeated 16 times = 102 bytes, UDP to 255.255.255.255:9.
//
// Needs NSLocalNetworkUsageDescription or the OS silently drops the broadcast.

import Foundation
import Network

enum WakeOnLAN {
    static func send(mac: String) {
        let bytes = macBytes(mac)
        guard bytes.count == 6 else { return }

        var packet = Data(count: 6 + 16 * 6)
        for i in 0..<6 { packet[i] = 0xFF }
        for i in 0..<16 {
            for j in 0..<6 {
                packet[6 + i * 6 + j] = bytes[j]
            }
        }

        let conn = NWConnection(host: "255.255.255.255",
                                port: NWEndpoint.Port(rawValue: 9)!,
                                using: .udp)
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: packet, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
            if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    private static func macBytes(_ mac: String) -> [UInt8] {
        let cleaned = mac
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard cleaned.count == 12 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(6)
        var idx = cleaned.startIndex
        for _ in 0..<6 {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return [] }
            out.append(b)
            idx = next
        }
        return out
    }
}
