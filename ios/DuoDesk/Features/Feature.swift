// Feature.swift — how the app's pieces (clipboard, files, ...) plug into the session.
// AppModel owns the link; it tells each Feature when the session starts and ends and hands
// it every message in the order it arrived. First Feature to return true owns the message.

import Foundation

@MainActor
protocol Feature: AnyObject {
    /// The computer said welcome: send this feature's policies and start.
    func onWelcome(host: PairedHost)
    /// The session ended (either side): stop anything in flight.
    func onClosed()
    /// True when the message was this feature's.
    func onMessage(_ t: String, _ m: [String: Any]) -> Bool
}

extension Feature {
    func onWelcome(host: PairedHost) {}
    func onClosed() {}
    func onMessage(_ t: String, _ m: [String: Any]) -> Bool { false }
}

/// What features use to talk to the computer. Safe to call from any thread.
final class Peer: @unchecked Sendable {
    private let lock = NSLock()
    private var link: PeerLink?
    private var _host: PairedHost?

    func attach(_ link: PeerLink?, host: PairedHost?) {
        lock.lock(); self.link = link; self._host = host; lock.unlock()
    }

    var host: PairedHost? {
        lock.lock(); defer { lock.unlock() }
        return _host
    }

    private var current: PeerLink? {
        lock.lock(); defer { lock.unlock() }
        return link
    }

    var isOpen: Bool { current?.state == .open }

    var pendingBytes: Int { current?.pendingBytes ?? 0 }

    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        current?.send(message) ?? false
    }
}

/// Events from the link, queued in arrival order and then drained on the main actor, so
/// message order never depends on how tasks happen to be scheduled (file chunks need it).
struct LinkEvent {
    enum Kind {
        case welcome
        case message
        case closed(String)
    }

    let link: ObjectIdentifier
    let kind: Kind
    let body: [String: Any]
}

final class LinkInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LinkEvent] = []

    func push(_ e: LinkEvent) {
        lock.lock(); events.append(e); lock.unlock()
    }

    func drain() -> [LinkEvent] {
        lock.lock(); defer { lock.unlock() }
        let out = events
        events.removeAll()
        return out
    }
}
