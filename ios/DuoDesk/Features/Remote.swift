// Remote.swift — serialize touchpad / keyboard / gamepad events into remote.* messages.
// Matches the Android app's Remote.kt and the browser remote under shared/phone-remote.js:
//   remote.hello          (phone -> PC on connect)
//   remote.state {allowed, pad, text}  (PC -> phone, drives UI gating)
//   remote.mm {dx, dy}    mouse move (relative)
//   remote.md / remote.mu {b}  button down/up (b is P.Button.*)
//   remote.wh {dx, dy}    scroll
//   remote.kd / remote.ku {code}  key down/up (KeyboardEvent-style code)
//   remote.text {text}    IME text
//   remote.pad {b, lx, ly, rx, ry, lt, rt}  gamepad frame (0..1 analog)
//   remote.release        return mouse/kb home
//
// Keyboard uses JS KeyboardEvent `code` strings on the wire (same as desktop and
// shared/keylayout.js). We do NOT send Android keycodes.

import Foundation

/// Thin stateless encoder. ViewModel owns the Link and calls these when gestures fire.
enum Remote {
    static func hello() -> [String: Any] {
        ["t": P.T.REMOTE_HELLO, "pad": true, "text": true]
    }

    static func mouseMove(dx: Double, dy: Double) -> [String: Any] {
        ["t": P.T.REMOTE_MM, "dx": dx, "dy": dy]
    }

    static func mouseDown(_ button: Int) -> [String: Any] {
        ["t": P.T.REMOTE_MD, "b": button]
    }

    static func mouseUp(_ button: Int) -> [String: Any] {
        ["t": P.T.REMOTE_MU, "b": button]
    }

    static func wheel(dx: Double, dy: Double) -> [String: Any] {
        ["t": P.T.REMOTE_WH, "dx": dx, "dy": dy]
    }

    static func keyDown(code: String, char: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["t": P.T.REMOTE_KD, "code": code]
        if let c = char { m["ch"] = c }
        return m
    }

    static func keyUp(code: String) -> [String: Any] {
        ["t": P.T.REMOTE_KU, "code": code]
    }

    static func text(_ s: String) -> [String: Any] {
        ["t": P.T.REMOTE_TEXT, "text": s]
    }

    /// Gamepad frame. Button bitmask: 0 A, 1 B, 2 X, 3 Y, 4 L1, 5 R1, 6 Back, 7 Start,
    /// 8 Up, 9 Down, 10 Left, 11 Right. Triggers lt/rt are 0..1.
    static func pad(buttons: UInt32, lx: Double, ly: Double, rx: Double, ry: Double,
                    lt: Double, rt: Double) -> [String: Any] {
        [
            "t": P.T.REMOTE_PAD,
            "b": Int(buttons),
            "lx": lx, "ly": ly,
            "rx": rx, "ry": ry,
            "lt": lt, "rt": rt,
        ]
    }

    static func release() -> [String: Any] {
        ["t": P.T.REMOTE_RELEASE]
    }
}

/// Smooths a trackpad gesture into a stream of remote.mm messages. UIKit gives us a
/// cumulative translation per gesture; we send deltas and reset.
@MainActor
final class RemotePointer {
    private var last: CGPoint = .zero
    private weak var link: PeerLink?

    init(link: PeerLink?) { self.link = link }

    func begin() { last = .zero }

    func update(translation t: CGPoint, sensitivity: Double = 1.6) {
        let dx = (t.x - last.x) * sensitivity
        let dy = (t.y - last.y) * sensitivity
        last = t
        guard abs(dx) >= 0.5 || abs(dy) >= 0.5 else { return }
        link?.send(Remote.mouseMove(dx: Double(dx), dy: Double(dy)))
    }

    func tap() {
        link?.send(Remote.mouseDown(P.Button.LEFT))
        link?.send(Remote.mouseUp(P.Button.LEFT))
    }

    func twoFingerTap() {
        link?.send(Remote.mouseDown(P.Button.RIGHT))
        link?.send(Remote.mouseUp(P.Button.RIGHT))
    }

    func scroll(dx: Double, dy: Double) {
        link?.send(Remote.wheel(dx: dx, dy: dy))
    }
}
