// RemoteControls.swift — UIKit pieces of the Remote page: the touchpad and the key capture.
// Gestures as on the Android page: slide = move (never clicks) · tap = left click · hold = right
// click · two fingers = scroll · two-finger tap = right click.

import SwiftUI
import UIKit

struct TrackpadView: UIViewRepresentable {
    let remote: RemoteFeature

    func makeCoordinator() -> Coordinator { Coordinator(remote) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.layer.cornerRadius = 16
        v.isMultipleTouchEnabled = true
        let c = context.coordinator

        let move = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.move(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        tap.numberOfTouchesRequired = 1
        let twoTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.twoTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.55
        hold.allowableMovement = 8
        hold.numberOfTouchesRequired = 1
        for g in [move, scroll, tap, twoTap, hold] as [UIGestureRecognizer] { v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.remote = remote
    }

    @MainActor
    final class Coordinator: NSObject {
        var remote: RemoteFeature
        init(_ remote: RemoteFeature) { self.remote = remote }

        @objc func move(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed else { return }
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            remote.pointerMove(dx: Double(t.x), dy: Double(t.y))
        }

        @objc func scroll(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed else { return }
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            remote.scroll(dx: Double(t.x), dy: Double(t.y))
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, remote.tapClick else { return }
            remote.click(P.Button.LEFT)
        }

        @objc func twoTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended else { return }
            remote.click(P.Button.RIGHT)
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            remote.click(P.Button.RIGHT)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

/// Takes the keys: the soft keyboard's text and a hardware keyboard's presses. Invisible; it
/// just has to be the first responder while the page is in front.
struct KeyCaptureView: UIViewRepresentable {
    var softKeyboard: Bool
    var onText: (String) -> Void
    var onBackspace: () -> Void
    var onKey: (String, Bool) -> Void

    func makeUIView(context: Context) -> KeyCaptureUIView {
        KeyCaptureUIView()
    }

    func updateUIView(_ v: KeyCaptureUIView, context: Context) {
        v.onText = onText
        v.onBackspace = onBackspace
        v.onKey = onKey
        v.softKeyboard = softKeyboard
        if v.window != nil && !v.isFirstResponder { _ = v.becomeFirstResponder() }
    }
}

final class KeyCaptureUIView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onKey: ((String, Bool) -> Void)?

    var softKeyboard = false {
        didSet { if oldValue != softKeyboard { reloadInputViews() } }
    }

    private let noKeyboard = UIView(frame: .zero)

    override var canBecomeFirstResponder: Bool { true }
    // An empty input view keeps the on-screen keyboard down until the person asks for it.
    override var inputView: UIView? { softKeyboard ? nil : noKeyboard }

    var hasText: Bool { true }
    func insertText(_ text: String) { onText?(text) }
    func deleteBackward() { onBackspace?() }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        } else {
            _ = resignFirstResponder()
        }
    }

    // A hardware keyboard (an iPad's, or a Bluetooth one): its keys go as they are.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, down: true, event: event) { super.pressesBegan($0, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, down: false, event: event) { super.pressesEnded($0, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, down: false, event: event) { super.pressesCancelled($0, with: event) }
    }

    private func forward(_ presses: Set<UIPress>, down: Bool, event: UIPressesEvent?,
                         passOn: (Set<UIPress>) -> Void) {
        var rest = Set<UIPress>()
        for p in presses {
            if let key = p.key, let code = KeyMap.code(forHID: Int(key.keyCode.rawValue)) {
                onKey?(code, down)
            } else {
                rest.insert(p)
            }
        }
        if !rest.isEmpty { passOn(rest) }
    }
}
