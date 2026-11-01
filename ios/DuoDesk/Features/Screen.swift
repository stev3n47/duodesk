// Screen.swift — the computer's screen on this device, like a second monitor or a mirror
// (mac/stream.js, android Web.kt). The picture is WebRTC; the page that plays it and sends
// the touch back as in.* is the Android app's own viewer.html/viewer.js, run unchanged in a
// WKWebView with a small window.TD shim (ViewerWebView). The flow, from the phone's side:
//   welcome            screen.policy {accept:false}  (silence makes the Mac think a viewer waits)
//   viewer opens       screen.policy {accept:true, width, height}; screen.ctl {share:true, mode}
//   computer           stream.info, rtc.offer, rtc.ice  ->  page  ->  rtc.answer, rtc.ice
//   viewer closes      screen.policy {accept:false}; screen.ctl {share:false} if we started it
// A phone is always the guest here, so it gets plain rtc.*; rtc2.* is a PC's swapped naming.

import SwiftUI
import UIKit
import WebKit

@MainActor
final class ScreenFeature: ObservableObject, Feature {
    @Published private(set) var state: [String: Any]?      // the computer's screen.state
    @Published private(set) var viewing = false
    @Published private(set) var size: CGSize?               // the picture playing now
    @Published private(set) var inputOn = true              // the computer's "Receive input"

    let bridge = ViewerBridge()
    private let peer: Peer
    private var lastInfo: [String: Any]?
    private var wantStart = false
    private var startedByUs = false

    init(peer: Peer) {
        self.peer = peer
        bridge.owner = self
    }

    var sharing: Bool { (state?["on"] as? Bool) == true }
    var mode: String { (state?["mode"] as? String) ?? "" }
    var canControl: Bool { (state?["remote"] as? Bool) != false }
    var modes: [String] { (state?["modes"] as? [String]) ?? ["extend", "mirror"] }

    // MARK: Feature

    func onWelcome(host: PairedHost) {
        state = nil
        lastInfo = nil
        // Without this the computer waits 1.5 s, takes the silence for an old viewer that is
        // watching, and starts sharing its screen to nobody.
        peer.send(["t": P.T.SCREEN_POLICY, "accept": false])
        if viewing { policy() }
    }

    func onClosed() {
        state = nil
        lastInfo = nil
        size = nil
        startedByUs = false
        wantStart = false
        bridge.post(["t": P.T.STREAM_STOP])
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case P.T.STREAM_INFO:
            lastInfo = m
            bridge.post(m)
        case P.T.RTC_OFFER, P.T.RTC_ICE:
            if viewing { bridge.post(m) }
        case P.T.STREAM_STOP:
            if viewing { bridge.post(m) }
        case P.T.SCREEN_STATE:
            state = m
            bridge.post(m)
            if wantStart { startIfNeeded() }
        case P.T.STREAM_INPUT:
            inputOn = (m["on"] as? Bool) ?? true
        default:
            return false
        }
        return true
    }

    // MARK: The viewer

    /// The viewer opened: stream to us, at our screen's size (Extend becomes a screen of that shape).
    func attach() {
        viewing = true
        bridge.post(opts())
        if let lastInfo { bridge.post(lastInfo) }
        if let state { bridge.post(state) }
        policy()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func detach() {
        guard viewing else { return }
        viewing = false
        size = nil
        wantStart = false
        bridge.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        if peer.isOpen {
            peer.send(["t": P.T.SCREEN_POLICY, "accept": false])
            if startedByUs && sharing { control(share: false) }
        }
        startedByUs = false
    }

    private func policy() {
        guard peer.isOpen else { return }
        let b = UIScreen.main.nativeBounds.size
        // Landscape physical pixels, the larger side as the width (the computer reads 320...7680).
        let w = Int(max(b.width, b.height)), h = Int(min(b.width, b.height))
        peer.send(["t": P.T.SCREEN_POLICY, "accept": true, "width": w, "height": h])
        // Show the computer's screen = it starts sharing, in Mirror to begin with.
        if state == nil { wantStart = true } else { startIfNeeded() }
    }

    private func startIfNeeded() {
        wantStart = false
        guard viewing, !sharing, canControl else { return }
        startedByUs = true
        control(share: true, mode: modes.contains("mirror") ? "mirror" : (modes.first ?? "mirror"))
    }

    func control(share: Bool? = nil, mode: String? = nil, close: Bool = false) {
        var m: [String: Any] = ["t": P.T.SCREEN_CTL]
        if let share { m["share"] = share }
        if let mode { m["mode"] = mode }
        if close { m["close"] = true }
        if share == false { startedByUs = false }
        peer.send(m)
    }

    /// The viewer's Close: the computer stops sharing too, whoever started it.
    func end() {
        if peer.isOpen && sharing { control(share: false, close: true) }
        detach()
    }

    func pick(mode: String) { control(share: true, mode: mode) }

    /// What the page needs to know first (viewer.js `opts`).
    func opts() -> [String: Any] {
        let sound: Bool = option("screen.sound", default: false)
        let smooth: Bool = option("screen.smooth", default: false)
        let touchpad: Bool = option("screen.touchpad", default: true)
        let pen: Bool = option("screen.pen", default: true)
        let tap: Bool = option("remote.tap", default: true)
        let speed: Double = (UserDefaults.standard.object(forKey: "remote.speed") as? Double) ?? 1.0
        var o: [String: Any] = ["t": "opts"]
        o["sound"] = sound
        o["pacing"] = smooth ? "smooth" : "fast"
        o["name"] = peer.host?.name ?? "the computer"
        o["touch"] = touchpad ? "pad" : "direct"
        o["speed"] = speed
        o["tap"] = tap
        o["pen"] = pen
        return o
    }

    func setOption(_ key: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        bridge.post(opts())
        objectWillChange.send()
    }

    func option(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    // MARK: From the page

    fileprivate func fromPage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String,
              t.hasPrefix("rtc.") || t.hasPrefix("in.") else { return }
        peer.send(obj)
    }

    fileprivate func playing(_ w: Double, _ h: Double) {
        size = CGSize(width: w, height: h)
    }
}

/// window.TD for viewer.js, and the way in for what the computer sends it. Messages wait
/// until the page says it is ready (TD.ready), like the Android WebHost does.
@MainActor
final class ViewerBridge: NSObject, WKScriptMessageHandler {
    weak var owner: ScreenFeature?
    weak var webView: WKWebView?
    private var ready = false
    private var queue: [String] = []

    static let shim = """
    (function () {
      var post = function (o) { window.webkit.messageHandlers.td.postMessage(o); };
      window.TD = {
        send: function (j) { post({ m: 'send', j: j }); },
        ready: function () { post({ m: 'ready' }); },
        playing: function (w, h) { post({ m: 'playing', w: w, h: h }); },
        haptic: function () { post({ m: 'haptic' }); }
      };
      var log = console.log;
      console.log = function () {
        try { post({ m: 'log', s: Array.prototype.slice.call(arguments).join(' ') }); } catch (e) {}
        log.apply(console, arguments);
      };
      window.addEventListener('error', function (e) { post({ m: 'log', s: 'error: ' + e.message }); });
    })();
    """

    /// A page is loading: nothing is ready until it says so (what is queued waits for it).
    func pageLoading() {
        ready = false
    }

    /// The viewer closed: drop what never got delivered.
    func clear() {
        ready = false
        queue = []
    }

    func post(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var json = String(data: data, encoding: .utf8) else { return }
        // JSON is JavaScript except for these two line separators.
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let js = "window.tdRecv && window.tdRecv(\(json));"
        if ready, let web = webView {
            web.evaluateJavaScript(js, completionHandler: nil)
        } else {
            queue.append(js)
            if queue.count > 200 { queue.removeFirst(queue.count - 200) }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let m = body["m"] as? String else { return }
        switch m {
        case "send":
            if let j = body["j"] as? String { owner?.fromPage(j) }
        case "ready":
            ready = true
            let pending = queue
            queue = []
            for js in pending { webView?.evaluateJavaScript(js, completionHandler: nil) }
        case "playing":
            let w = (body["w"] as? NSNumber)?.doubleValue ?? 0
            let h = (body["h"] as? NSNumber)?.doubleValue ?? 0
            owner?.playing(w, h)
        case "haptic":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "log":
            NSLog("viewer: %@", (body["s"] as? String) ?? "")
        default:
            break
        }
    }
}

struct ViewerWebView: UIViewRepresentable {
    let bridge: ViewerBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: ViewerBridge.shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(bridge, name: "td")
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        bridge.webView = web
        bridge.pageLoading()

        // The Android app's own web/ folder, bundled as it is (fonts are read by relative path).
        if let dir = Bundle.main.url(forResource: "web", withExtension: nil) {
            web.loadFileURL(dir.appendingPathComponent("viewer.html"), allowingReadAccessTo: dir)
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "td")
        uiView.configuration.userContentController.removeAllUserScripts()
        uiView.stopLoading()
    }
}
