// Notifs.swift — the computer's notifications on this device (mac/notifs.js; android Notifs.kt).
// One way only: iOS has no API to read other apps' notifications, so this device never sends any.
//   notif.policy {accept}  either way: this side shows the other's notifications
//   notif {id, app, appName, title, subtitle, body, at, icon?}  computer -> here
// They show while DuoDesk is running (in front, or for the short while iOS keeps it alive in
// the background). Nothing wakes a suspended app: that takes a push server, which a re-signed
// build can't have.

import SwiftUI
import UserNotifications

@MainActor
final class NotifsFeature: ObservableObject, Feature {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var shown = 0
    @Published private(set) var peerAccepts = false

    private let peer: Peer
    private let sync: PairSyncFeature

    init(peer: Peer, sync: PairSyncFeature) {
        self.peer = peer
        self.sync = sync
    }

    var wanted: Bool { sync.get("notifs", .incoming) }

    var authorized: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in self?.authorization = status }
        }
    }

    /// Ask iOS once; the person's answer decides whether the switch can stay on.
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        refreshAuthorization()
        return granted
    }

    func sendPolicy() {
        peer.send(["t": P.T.NOTIF_POLICY, "accept": wanted && authorized])
    }

    // MARK: Feature

    func onWelcome(host: PairedHost) {
        peerAccepts = false
        refreshAuthorization()
        sendPolicy()
    }

    func onClosed() {
        peerAccepts = false
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case P.T.NOTIF_POLICY:
            peerAccepts = (m["accept"] as? Bool) ?? false
        case P.T.NOTIF:
            present(m)
        default:
            return false
        }
        return true
    }

    private func present(_ m: [String: Any]) {
        guard wanted, authorized else { return }
        let id = String((m["id"] as? String ?? UUID().uuidString).prefix(64))
        let app = (m["appName"] as? String) ?? ""
        let title = (m["title"] as? String) ?? ""
        let subtitle = (m["subtitle"] as? String) ?? ""
        let body = (m["body"] as? String) ?? ""
        if title.isEmpty && body.isEmpty && subtitle.isEmpty { return }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? app : title
        content.subtitle = title.isEmpty ? subtitle : (subtitle.isEmpty ? app : "\(app) · \(subtitle)")
        content.body = body
        content.sound = .default
        if let bundle = m["app"] as? String, !bundle.isEmpty { content.threadIdentifier = bundle }
        if let icon = m["icon"] as? String, let attachment = Self.attachment(fromDataURL: icon, id: id) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
        shown += 1
    }

    /// "data:image/png;base64,..." as a notification attachment (it needs a file).
    private static func attachment(fromDataURL s: String, id: String) -> UNNotificationAttachment? {
        guard s.hasPrefix("data:image/"), let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notif-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: id, url: url, options: nil)
    }
}

/// Shows the computer's notifications as banners even while DuoDesk is in front.
final class NotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotifDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
