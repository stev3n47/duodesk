// SettingsPage.swift — device identity, signing posture, side-load help links.

import SwiftUI
import UserNotifications

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var sync: PairSyncFeature
    @EnvironmentObject var notifs: NotifsFeature
    @State private var editingName: String = ""

    var body: some View {
        // `List` instead of `Form` — Xcode 26's `Form` has an ambiguous overload with
        // `FormStyleConfiguration` that trips the trailing-closure resolver on iOS 16.
        List {
            Section("This device") {
                TextField("Device name", text: $editingName)
                    .textContentType(.name)
                    .autocorrectionDisabled()
                    .onAppear { editingName = store.selfName }
                Button("Save") { store.setSelfName(editingName) }
                    .disabled(editingName.trimmingCharacters(in: .whitespaces) == store.selfName)
                HStack {
                    Text("Device ID")
                    Spacer()
                    Text(store.selfId.prefix(8) + "…")
                        .font(.footnote).monospaced().foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show the computer’s notifications here", isOn: Binding(
                    get: { sync.get("notifs", .incoming) },
                    set: { on in
                        if on {
                            Task {
                                if await notifs.requestAuthorization() {
                                    sync.set("notifs", .incoming, true)
                                    notifs.sendPolicy()
                                }
                            }
                        } else {
                            sync.set("notifs", .incoming, false)
                        }
                    }))
                if notifs.authorization == .denied {
                    Label("Notifications are off for DuoDesk in iOS Settings.", systemImage: "bell.slash")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("They arrive while DuoDesk is running. iOS doesn’t let an app read other apps’ notifications, so this device’s don’t go to the computer.")
            }

            Section("Signing") {
                row("Profile", model.posture.profile.rawValue)
                if let days = model.posture.daysUntilExpiry {
                    row("Expires in", "\(days) day\(days == 1 ? "" : "s")")
                }
                row("App Group", model.posture.hasAppGroup ? "Available" : "Unavailable")
                row("Multicast entitlement", model.posture.hasMulticast ? "Granted" : "Not granted")
                Link("Side-load guide",
                     destination: URL(string: "https://getduodesk.vercel.app/sideload")!)
            }

            Section("What this build supports") {
                supportRow("Pairing and connecting over Wi-Fi", true)
                supportRow("Bluetooth and USB links", false, note: "Not yet")
                supportRow("Remote: touchpad and keyboard", true)
                supportRow("Clipboard, text and pictures", true)
                supportRow("Files, both ways; Open in DuoDesk", true)
                supportRow("Computer’s screen on this device", true)
                supportRow("Computer’s notifications here", true)
                supportRow("Gamepad", false, note: "Later")
                supportRow("Camera as the computer’s webcam", false, note: "Phase 3")
                supportRow("This screen on the computer", false, note: "Phase 3")
                supportRow("Files app folder", false, note: "Phase 3")
                supportRow("Calls (while open)", false, note: "Phase 4")
                supportRow("Chat", false, note: "Needs the computer apps")
                supportRow("Texts, other apps’ notifications, controlling this device", false,
                           note: "Not possible on iOS")
            }

            Section {
                Link("DuoDesk website", destination: URL(string: "https://getduodesk.vercel.app")!)
                Link("Source on GitHub", destination: URL(string: "https://github.com/0xCodez/DuoDesk")!)
            }
        }
        .navigationTitle("Settings")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label); Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func supportRow(_ label: String, _ on: Bool, note: String? = nil) -> some View {
        HStack {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(on ? .green : .secondary)
                .frame(width: 24)
            Text(label)
            Spacer()
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
