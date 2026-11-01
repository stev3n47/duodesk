// RootView.swift — top-level split view. Sidebar on iPad, tab-like navigation on iPhone.

import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { if let v = $0 { model.selection = v } })) {
                Section("DuoDesk") {
                    row(.overview, "Overview", "house")
                    row(.pairing, "Pairing", "qrcode.viewfinder")
                    row(.remote, "Remote", "cursorarrow.rays")
                    row(.settings, "Settings", "gearshape")
                }
            }
            .navigationTitle("DuoDesk")
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                detail
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            StatusPill(text: model.connectionStatus, connected: model.activeHostId != nil)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func row(_ page: AppModel.Page, _ title: String, _ sfSymbol: String) -> some View {
        Label(title, systemImage: sfSymbol).tag(page as AppModel.Page?)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: OverviewPage()
        case .pairing:  PairingPage()
        case .remote:   RemotePage()
        case .settings: SettingsPage()
        }
    }
}

struct StatusPill: View {
    let text: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(text).font(.caption).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
    }
}
