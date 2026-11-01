// App.swift — SwiftUI entry.
// AppModel owns the services (Discovery, BLECentral, USBTether), the one session with a
// computer (PeerLink), and the Features that handle its messages: pair.sync, clipboard, files,
// notifications, the remote, and the screen viewer. Link events are queued and drained in
// arrival order on the main actor, so file chunks and the like never get out of order.

import SwiftUI
import UserNotifications

@main
struct DuoDeskApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        UNUserNotificationCenter.current().delegate = NotifDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.discovery)
                .environmentObject(model.ble)
                .environmentObject(model.usb)
                .environmentObject(model.sync)
                .environmentObject(model.clipboard)
                .environmentObject(model.files)
                .environmentObject(model.notifs)
                .environmentObject(model.remote)
                .environmentObject(model.screen)
                .onAppear { model.start() }
                .onOpenURL(perform: model.handleOpen)
                .onChange(of: phase) { p in
                    if p == .active { model.didBecomeActive() }
                }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Page: Hashable {
        case overview, pairing, remote, clipboard, files, screen, settings
    }

    @Published var selection: Page = .overview
    @Published var posture: SigningPosture = .init()
    @Published private(set) var connectedHost: PairedHost?
    @Published var connectionStatus: String = "Not connected"

    let store = Store.shared
    let discovery = Discovery()
    let ble = BLECentral()
    let usb = USBTether()

    let peer: Peer
    let sync: PairSyncFeature
    let clipboard: ClipboardFeature
    let files: FilesFeature
    let notifs: NotifsFeature
    let remote: RemoteFeature
    let screen: ScreenFeature

    private var features: [Feature] = []
    private var link: PeerLink?
    private var connecting: PairedHost?
    private let inbox = LinkInbox()

    var isConnected: Bool { connectedHost != nil }

    init() {
        let peer = Peer()
        let sync = PairSyncFeature(peer: peer)
        let clipboard = ClipboardFeature(peer: peer, sync: sync)
        let files = FilesFeature(peer: peer)
        let notifs = NotifsFeature(peer: peer, sync: sync)
        let remote = RemoteFeature(peer: peer, sync: sync)
        let screen = ScreenFeature(peer: peer)
        self.peer = peer
        self.sync = sync
        self.clipboard = clipboard
        self.files = files
        self.notifs = notifs
        self.remote = remote
        self.screen = screen
        // sync first: a feature's welcome reads the switches it restores.
        self.features = [sync, clipboard, files, notifs, remote, screen]
        sync.onChange = { [weak self] feature in self?.syncChanged(feature) }
    }

    func start() {
        posture = SigningPostureDetector.detect()
        discovery.start()
        usb.start()
        notifs.refreshAuthorization()
        // BLE central starts itself when the system reports .poweredOn.
    }

    func didBecomeActive() {
        discovery.sendProbe()
        notifs.refreshAuthorization()
        clipboard.checkPasteboard()
    }

    func handleOpen(_ url: URL) {
        if url.isFileURL {
            // "Open in DuoDesk" from the share sheet or the Files app: send it to the computer.
            selection = .files
            files.send(urls: [url], scoped: true)
            return
        }
        // twindesk://pair?... jumps straight to the pairing page.
        guard url.scheme == "twindesk", url.host == "pair" else { return }
        selection = .pairing
    }

    private func syncChanged(_ feature: String) {
        switch feature {
        case "clipboard": clipboard.sendPolicy()
        case "notifs": notifs.sendPolicy()
        default: break
        }
    }

    // MARK: Session

    func connect(to host: PairedHost) {
        guard let token = store.token(for: host.id) else {
            connectionStatus = "No saved token: pair again"
            return
        }
        disconnect()
        let link = PeerLink(host: host, token: token, selfId: store.selfId, selfName: store.selfName)
        link.delegate = self
        self.link = link
        connecting = host
        connectionStatus = "Connecting to \(host.name)…"
        link.connect()
    }

    func disconnect() {
        guard let l = link else { return }
        l.disconnect()
        finishClosed("Disconnected")
    }

    private func drain() {
        for e in inbox.drain() {
            guard let l = link, ObjectIdentifier(l) == e.link else { continue }
            switch e.kind {
            case .welcome:
                handleWelcome()
            case .message:
                if let t = e.body["t"] as? String { route(t, e.body) }
            case .closed(let why):
                finishClosed(why)
            }
        }
    }

    private func handleWelcome() {
        guard let host = connecting, let link else { return }
        connecting = nil
        connectedHost = host
        connectionStatus = "Connected to \(host.name)"
        peer.attach(link, host: host)
        store.update(hostId: host.id, lastSeen: Date())
        for f in features { f.onWelcome(host: host) }
    }

    private func route(_ t: String, _ m: [String: Any]) {
        for f in features where f.onMessage(t, m) { return }
    }

    private func finishClosed(_ reason: String) {
        link = nil
        connecting = nil
        peer.attach(nil, host: nil)
        connectedHost = nil
        connectionStatus = reason
        for f in features.reversed() { f.onClosed() }
    }

    nonisolated private func enqueue(_ link: PeerLink, _ kind: LinkEvent.Kind, _ body: [String: Any] = [:]) {
        inbox.push(LinkEvent(link: ObjectIdentifier(link), kind: kind, body: body))
        Task { @MainActor [weak self] in self?.drain() }
    }
}

extension AppModel: PeerLinkDelegate {
    nonisolated func peerLink(_ link: PeerLink, didConnect welcome: [String: Any]) {
        enqueue(link, .welcome, welcome)
    }

    nonisolated func peerLink(_ link: PeerLink, didReceive message: [String: Any]) {
        enqueue(link, .message, message)
    }

    nonisolated func peerLink(_ link: PeerLink, didCloseWith reason: PeerLink.CloseReason) {
        enqueue(link, .closed(reason.text))
    }
}
