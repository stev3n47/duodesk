// Remote.swift — this device as the computer's remote (shared/phone-remote.js; android Remote.kt).
//   remote.hello          the Remote page opened (the computer answers remote.state)
//   remote.release        the page closed: let go of every key and button
//   remote.state {allowed, why, off, pad, text}   computer -> here: does it take our input now
//   remote.mm {dx,dy,smooth}  pointer, pixels · remote.md/mu {b} buttons · remote.wh {dx,dy} scroll
//   remote.kd/ku {code}       KeyboardEvent.code · remote.text {text} characters no key types
// Off on the computer until its Remote switch is on; this page can turn it on (pair.sync).
// A computer older than this app never answers remote.hello, and the page says so.

import SwiftUI

enum Remote {
    static func hello() -> [String: Any] { ["t": P.T.REMOTE_HELLO] }
    static func release() -> [String: Any] { ["t": P.T.REMOTE_RELEASE] }

    static func mouseMove(dx: Int, dy: Int, smooth: Bool) -> [String: Any] {
        ["t": P.T.REMOTE_MM, "dx": dx, "dy": dy, "smooth": smooth]
    }

    static func mouseDown(_ button: Int) -> [String: Any] { ["t": P.T.REMOTE_MD, "b": button] }
    static func mouseUp(_ button: Int) -> [String: Any] { ["t": P.T.REMOTE_MU, "b": button] }

    static func wheel(dx: Int, dy: Int) -> [String: Any] { ["t": P.T.REMOTE_WH, "dx": dx, "dy": dy] }

    static func keyDown(_ code: String) -> [String: Any] { ["t": P.T.REMOTE_KD, "code": code] }
    static func keyUp(_ code: String) -> [String: Any] { ["t": P.T.REMOTE_KU, "code": code] }

    static func text(_ s: String) -> [String: Any] { ["t": P.T.REMOTE_TEXT, "text": s] }
}

@MainActor
final class RemoteFeature: ObservableObject, Feature {
    /// The computer's last answer; nil until it has answered.
    @Published private(set) var allowed: Bool?
    @Published private(set) var why = ""
    /// The computer's Remote switch is off (this page offers to turn it on).
    @Published private(set) var off = false
    /// The computer types text as it is (remote.state text).
    @Published private(set) var textOK = false
    /// It never answered remote.hello: an older DuoDesk there.
    @Published private(set) var unsupported = false

    /// The touchpad's pointer speed.
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "remote.speed") }
    }

    /// A quick tap left-clicks (a slide never does).
    @Published var tapClick: Bool {
        didSet { UserDefaults.standard.set(tapClick, forKey: "remote.tap") }
    }

    private(set) var active = false
    private let peer: Peer
    private let sync: PairSyncFeature
    private var helloWatch: Task<Void, Never>?
    private var mx = 0.0, my = 0.0, wx = 0.0, wy = 0.0

    init(peer: Peer, sync: PairSyncFeature) {
        self.peer = peer
        self.sync = sync
        let d = UserDefaults.standard
        self.speed = (d.object(forKey: "remote.speed") as? Double) ?? 1.0
        self.tapClick = (d.object(forKey: "remote.tap") as? Bool) ?? true
    }

    // MARK: The page

    func open() {
        active = true
        hello()
    }

    func close() {
        guard active else { return }
        active = false
        helloWatch?.cancel()
        if peer.isOpen { peer.send(Remote.release()) }
    }

    func turnOn() {
        sync.set("remote", .outgoing, true)
    }

    private func hello() {
        guard peer.isOpen else { return }
        unsupported = false
        peer.send(Remote.hello())
        helloWatch?.cancel()
        helloWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.allowed == nil && self.active { self.unsupported = true }
        }
    }

    // MARK: Feature

    func onWelcome(host: PairedHost) {
        allowed = nil
        textOK = false
        if active { hello() }
    }

    func onClosed() {
        allowed = nil
        unsupported = false
        helloWatch?.cancel()
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        guard t == P.T.REMOTE_STATE else { return false }
        allowed = (m["allowed"] as? Bool) ?? false
        why = (m["why"] as? String) ?? ""
        off = (m["off"] as? Bool) ?? false
        textOK = (m["text"] as? Bool) ?? false
        unsupported = false
        helloWatch?.cancel()
        return true
    }

    // MARK: Pointer

    /// 1× when slow (fine aim), up to 2× for a quick flick: the same gain as the Android page.
    func pointerMove(dx: Double, dy: Double) {
        let g = speed * (1 + min(1, hypot(dx, dy) / 30))
        mx += dx * g
        my += dy * g
        let ix = mx.rounded(.towardZero), iy = my.rounded(.towardZero)
        guard ix != 0 || iy != 0 else { return }
        mx -= ix
        my -= iy
        peer.send(Remote.mouseMove(dx: Int(ix), dy: Int(iy), smooth: true))
    }

    /// Two fingers: the page follows the fingers, so the sign is the other way, doubled.
    func scroll(dx: Double, dy: Double) {
        wx += -dx * 2
        wy += -dy * 2
        let ix = wx.rounded(), iy = wy.rounded()
        guard ix != 0 || iy != 0 else { return }
        wx -= ix
        wy -= iy
        peer.send(Remote.wheel(dx: Int(ix), dy: Int(iy)))
    }

    func click(_ button: Int) {
        peer.send(Remote.mouseDown(button))
        peer.send(Remote.mouseUp(button))
    }

    func buttonDown(_ button: Int) { peer.send(Remote.mouseDown(button)) }
    func buttonUp(_ button: Int) { peer.send(Remote.mouseUp(button)) }

    // MARK: Keyboard

    func key(_ code: String, down: Bool) {
        peer.send(down ? Remote.keyDown(code) : Remote.keyUp(code))
    }

    func tap(_ stroke: KeyMap.Stroke) {
        if stroke.shift { key("ShiftLeft", down: true) }
        key(stroke.code, down: true)
        key(stroke.code, down: false)
        if stroke.shift { key("ShiftLeft", down: false) }
    }

    func backspace() { tap(KeyMap.Stroke(code: "Backspace", shift: false)) }

    /// Typed text: keys where a key types it, characters as they are where none does (and the
    /// computer can type them).
    func type(_ text: String) {
        var run = ""
        func flush() {
            if !run.isEmpty && textOK { peer.send(Remote.text(String(run.prefix(64)))) }
            run = ""
        }
        for ch in text {
            if ch.isNewline {
                flush()
                tap(KeyMap.Stroke(code: "Enter", shift: false))
            } else if let s = KeyMap.stroke(for: ch) {
                flush()
                tap(s)
            } else {
                run.append(ch)
            }
        }
        flush()
    }
}
