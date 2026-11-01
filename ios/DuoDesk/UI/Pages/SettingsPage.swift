// SettingsPage.swift — device identity, signing posture, side-load help links.

import SwiftUI

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
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
                supportRow("Pairing (Wi-Fi, BLE, USB)", true)
                supportRow("Phone as remote", true)
                supportRow("Wake-on-LAN", true)
                supportRow("Clipboard", false, note: "Phase 2")
                supportRow("Files, share sheet", false, note: "Phase 2")
                supportRow("iPad as second screen", false, note: "Phase 2")
                supportRow("Camera as PC webcam", false, note: "Phase 3")
                supportRow("Phone screen → PC", false, note: "Phase 3")
                supportRow("Files app provider", false, note: "Phase 3")
                supportRow("Call audio bridge (foreground)", false, note: "Phase 4")
                supportRow("SMS, notification mirror, mouse into iOS", false,
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
