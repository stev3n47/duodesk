// PairSyncFeature.swift — the two-way switches shared with the computer (mac/pairsync.js,
// android PairSync.kt). The computer hosts: right after welcome it sends all of them
// (`pair.sync {all}`) and we adopt them; after that either side sends one when its person
// flips it. Directions are told from the sender's side, so a receiver flips them:
//   we flip clipboard "out"  ->  we send {feature, dir:'out', on}  ->  the computer's "in".
// Features this app has: clipboard, notifs, remote, files.

import Foundation

@MainActor
final class PairSyncFeature: ObservableObject, Feature {
    enum Dir: String {
        case outgoing = "out"   // ours shown there / used there
        case incoming = "in"    // theirs shown here / used here
    }

    struct Dirs: Codable, Equatable {
        var out = false
        var inc = false
        enum CodingKeys: String, CodingKey {
            case out
            case inc = "in"
        }
    }

    static let known = ["clipboard", "notifs", "remote", "files"]

    @Published private(set) var table: [String: Dirs] = [:]
    /// Called with the feature's name when one of its switches changed (here or there).
    var onChange: ((String) -> Void)?

    private let peer: Peer
    private var hostId: String?

    init(peer: Peer) {
        self.peer = peer
    }

    func get(_ feature: String, _ dir: Dir) -> Bool {
        let v = table[feature] ?? Dirs()
        return dir == .outgoing ? v.out : v.inc
    }

    /// The person flipped a switch here: remember it and tell the computer, which follows.
    func set(_ feature: String, _ dir: Dir, _ on: Bool) {
        apply(feature, dir, on)
        peer.send(["t": P.T.PAIR_SYNC, "feature": feature, "dir": dir.rawValue, "on": on])
        persist()
    }

    private func apply(_ feature: String, _ dir: Dir, _ on: Bool) {
        guard Self.known.contains(feature) else { return }
        var v = table[feature] ?? Dirs()
        if dir == .outgoing { v.out = on } else { v.inc = on }
        guard table[feature] != v else { return }
        table[feature] = v
        onChange?(feature)
    }

    // MARK: - Feature

    func onWelcome(host: PairedHost) {
        hostId = host.id
        table = [:]
        if let saved = loadSaved(host.id) {
            for (f, v) in saved {
                apply(f, .outgoing, v.out)
                apply(f, .incoming, v.inc)
            }
        }
    }

    func onClosed() {
        persist()
        hostId = nil
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        guard t == P.T.PAIR_SYNC else { return false }
        if let all = m["all"] as? [String: Any] {
            for f in Self.known {
                guard let v = all[f] as? [String: Any] else { continue }
                // Their in = our out, their out = our in.
                apply(f, .outgoing, (v["in"] as? Bool) ?? false)
                apply(f, .incoming, (v["out"] as? Bool) ?? false)
            }
        } else if let f = m["feature"] as? String, let dir = m["dir"] as? String, dir == "out" || dir == "in" {
            apply(f, dir == "out" ? .incoming : .outgoing, (m["on"] as? Bool) ?? false)
        }
        persist()
        return true
    }

    // MARK: - Remembered per computer

    private func key(_ id: String) -> String { "pairsync.\(id)" }

    private func loadSaved(_ id: String) -> [String: Dirs]? {
        guard let data = UserDefaults.standard.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode([String: Dirs].self, from: data)
    }

    private func persist() {
        guard let id = hostId, let data = try? JSONEncoder().encode(table) else { return }
        UserDefaults.standard.set(data, forKey: key(id))
    }
}
