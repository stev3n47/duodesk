// App.swift — SwiftUI entry.
// Phase 1 shell: NavigationSplitView with four pages (Overview, Pairing, Remote, Settings).
// AppModel holds the shared services (Discovery, BLECentral, USBTether) and the active Link.

import SwiftUI

@main
struct DuoDeskApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.discovery)
                .environmentObject(model.ble)
                .environmentObject(model.usb)
                .onAppear { model.start() }
                .onOpenURL(perform: model.handleOpen)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: Page = .overview
    @Published var posture: SigningPosture = .init()
    @Published var activeHostId: String? = nil
    @Published var connectionStatus: String = "Not connected"

    let store = Store.shared
    let discovery = Discovery()
    let ble = BLECentral()
    let usb = USBTether()

    private var activeLink: Link?

    enum Page: Hashable {
        case overview, pairing, remote, settings
    }

    func start() {
        posture = SigningPostureDetector.detect()
        discovery.start()
        usb.start()
        // BLE central starts itself when the system reports .poweredOn.
    }

    func handleOpen(_ url: URL) {
        // twindesk://pair?host=192.168.1.4&port=47800&fp=abcd... — jumps straight to the pairing page.
        guard url.scheme == "twindesk", url.host == "pair" else { return }
        selection = .pairing
    }

    func connect(to host: PairedHost) {
        guard let token = store.token(for: host.id) else {
            connectionStatus = "No saved token — pair again"
            return
        }
        let link = Link(host: host, token: token, selfId: store.selfId, selfName: store.selfName)
        link.delegate = self
        activeHostId = host.id
        connectionStatus = "Connecting to \(host.name)…"
        link.connect()
        activeLink = link
    }

    func disconnect() {
        activeLink?.disconnect()
        activeLink = nil
        activeHostId = nil
        connectionStatus = "Disconnected"
    }

    var currentLink: Link? { activeLink }
}

extension AppModel: LinkDelegate {
    nonisolated func link(_ link: Link, didConnect welcome: [String: Any]) {
        let name = (welcome["macName"] as? String) ?? "host"
        Task { @MainActor in
            self.connectionStatus = "Connected to \(name)"
            // Use the stored link to avoid moving a non-Sendable Link across the Task boundary.
            self.activeLink?.send(Remote.hello())
        }
    }

    nonisolated func link(_ link: Link, didReceive message: [String: Any]) {
        // Phase 1 wires only the UI shell; feature modules will attach their own handlers
        // off this hook in later phases.
    }

    nonisolated func link(_ link: Link, didCloseWith reason: Link.CloseReason) {
        let description: String
        switch reason {
        case .bye: description = "Host disconnected"
        case .replaced: description = "Replaced by another peer"
        case .timeout: description = "Timed out"
        case .versionMismatch: description = "Protocol version mismatch"
        case .badToken: description = "Bad token — pair again"
        case .error(let s): description = "Error: \(s)"
        case .transport(let e): description = "Transport: \(e.localizedDescription)"
        }
        Task { @MainActor in
            self.activeLink = nil
            self.activeHostId = nil
            self.connectionStatus = description
        }
    }
}
