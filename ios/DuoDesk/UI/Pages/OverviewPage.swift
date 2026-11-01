// OverviewPage.swift — paired hosts, nearby devices, signing-posture banner.

import SwiftUI

struct OverviewPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var discovery: Discovery
    @EnvironmentObject var ble: BLECentral

    var body: some View {
        List {
            if model.posture.shouldWarn, let days = model.posture.daysUntilExpiry {
                Section {
                    PostureBanner(days: days, profile: model.posture.profile)
                }
            }

            Section("Paired") {
                if store.hosts.isEmpty {
                    emptyRow("No paired computers yet. Open Pairing to find one nearby.")
                } else {
                    ForEach(store.hosts) { host in
                        HostRow(host: host,
                                connected: model.connectedHost?.id == host.id,
                                onConnect: { model.connect(to: host) },
                                onDisconnect: { model.disconnect() },
                                onForget: { store.forget(hostId: host.id) })
                    }
                }
            }

            Section("Nearby on Wi-Fi") {
                let paired = Set(store.hosts.map(\.id))
                let fresh = discovery.devices.filter { !paired.contains($0.id) }
                if fresh.isEmpty {
                    emptyRow("Nothing new nearby.")
                } else {
                    ForEach(fresh) { d in
                        NavigationLink(value: d) {
                            NearbyRow(device: d)
                        }
                    }
                }
            }

            Section("Nearby on Bluetooth") {
                if ble.hosts.isEmpty {
                    emptyRow(ble.authorized ? "Scanning…" : "Bluetooth is off or not permitted.")
                } else {
                    ForEach(ble.hosts) { h in
                        BLERow(host: h)
                    }
                }
            }
        }
        .navigationTitle("Overview")
        .navigationDestination(for: DiscoveredDevice.self) { d in
            PairingPage(prefilled: d)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
    }
}

private struct HostRow: View {
    let host: PairedHost
    let connected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack {
            Image(systemName: osSymbol(host.os)).frame(width: 24)
            VStack(alignment: .leading) {
                Text(host.name).font(.body)
                Text("\(host.osLabel) · \(host.address):\(host.port)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if connected {
                Button("Disconnect", role: .destructive, action: onDisconnect).buttonStyle(.bordered)
            } else {
                Button("Connect", action: onConnect).buttonStyle(.borderedProminent)
            }
        }
        .swipeActions {
            Button("Forget", role: .destructive, action: onForget)
        }
    }
}

private struct NearbyRow: View {
    let device: DiscoveredDevice
    var body: some View {
        HStack {
            Image(systemName: osSymbol(device.os)).frame(width: 24)
            VStack(alignment: .leading) {
                Text(device.name)
                Text("\(device.address):\(device.port)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
    }
}

private struct BLERow: View {
    let host: BLEHost
    var body: some View {
        HStack {
            Image(systemName: "dot.radiowaves.left.and.right").frame(width: 24)
            VStack(alignment: .leading) {
                Text(host.name)
                Text("RSSI \(host.rssi) dBm").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct PostureBanner: View {
    let days: Int
    let profile: SigningPosture.Profile
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Re-install coming up", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("Your \(profile.rawValue) build expires in \(days) day\(days == 1 ? "" : "s"). " +
                 "Re-install the IPA before it does, or DuoDesk stops opening.")
                .font(.footnote).foregroundStyle(.secondary)
            Link("Open side-load guide", destination: URL(string: "https://getduodesk.vercel.app/sideload")!)
                .font(.footnote)
        }
        .padding(.vertical, 4)
    }
}

private func osSymbol(_ os: String) -> String {
    switch os {
    case "mac": return "laptopcomputer"
    case "win": return "pc"
    case "linux": return "terminal"
    case "android": return "candybarphone"
    case "ios": return "iphone"
    default: return "questionmark.square.dashed"
    }
}
