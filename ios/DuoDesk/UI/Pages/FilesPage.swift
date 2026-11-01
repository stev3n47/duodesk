// FilesPage.swift — send files to the connected computer, and see what comes in. Received
// files are in the Files app under On My iPhone > DuoDesk. "Open in DuoDesk" from the share
// sheet sends too.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FilesPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var files: FilesFeature
    @EnvironmentObject var sync: PairSyncFeature

    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        let host = model.connectedHost?.name ?? "the computer"
        List {
            if !model.isConnected {
                Section { Label("Connect to a computer from Overview first.", systemImage: "wifi.slash").foregroundStyle(.secondary) }
            }

            Section {
                Button {
                    importing = true
                } label: {
                    Label("Choose files…", systemImage: "doc.badge.plus")
                }
                PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                    Label("Choose photos and videos…", systemImage: "photo.on.rectangle")
                }
                Toggle("Send files to \(host)", isOn: sync.binding("files", .outgoing))
            } header: {
                Text("Send")
            } footer: {
                if files.notice.isEmpty {
                    Text("The switch lets \(host) take files from this device. You can also use Share › DuoDesk in any app.")
                } else {
                    Text(files.notice).foregroundStyle(.orange)
                }
            }

            if !files.transfers.isEmpty {
                Section("Transfers") {
                    ForEach(files.transfers) { t in TransferRow(t: t) }
                }
            }

            Section {
                Button {
                    if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) }
                } label: {
                    Label("Open the Files app", systemImage: "folder")
                }
            } header: {
                Text("Received")
            } footer: {
                Text("Files from \(host) land in Files › On My iPhone › DuoDesk.")
            }

            if !files.recent.isEmpty {
                Section("Recent") {
                    ForEach(Array(files.recent.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                }
            }
        }
        .navigationTitle("Files")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { files.send(urls: urls, scoped: true) }
        }
        .onChange(of: photos) { items in
            guard !items.isEmpty else { return }
            Task { await sendPhotos(items) }
        }
    }

    private func sendPhotos(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for item in items {
            if let picked = try? await item.loadTransferable(type: PickedFile.self) { urls.append(picked.url) }
        }
        photos = []
        if !urls.isEmpty { files.send(urls: urls, scoped: false, cleanup: true) }
    }
}

private struct TransferRow: View {
    let t: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: t.upload ? "arrow.up.circle" : "arrow.down.circle")
                Text(t.title).lineLimit(1)
                Spacer()
                switch t.state {
                case .active: Text("\(Int(t.fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            if t.state == .active { ProgressView(value: t.fraction) }
        }
        .padding(.vertical, 2)
    }
}
