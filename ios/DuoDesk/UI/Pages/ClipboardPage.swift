// ClipboardPage.swift — the clipboard shared with the computer. The computer's copies land
// here by themselves; this device's go over when the person pastes them in with the system
// Paste button (no prompt), or automatically when DuoDesk opens (iOS may ask first).

import SwiftUI
import UniformTypeIdentifiers

extension PairSyncFeature {
    func binding(_ feature: String, _ dir: Dir) -> Binding<Bool> {
        Binding(get: { self.get(feature, dir) }, set: { self.set(feature, dir, $0) })
    }
}

struct ClipboardPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var clip: ClipboardFeature
    @EnvironmentObject var sync: PairSyncFeature

    var body: some View {
        let host = model.connectedHost?.name ?? "the computer"
        List {
            if !model.isConnected {
                Section { Label("Connect to a computer from Overview first.", systemImage: "wifi.slash").foregroundStyle(.secondary) }
            }

            Section {
                Toggle("Use \(host)’s copies here", isOn: sync.binding("clipboard", .incoming))
                Toggle("Send my copies to \(host)", isOn: sync.binding("clipboard", .outgoing))
                Toggle("Pictures too", isOn: $clip.picturesOn)
            } footer: {
                Text("Off until you turn it on. Both switches follow the ones in DuoDesk on \(host).")
            }

            Section {
                PasteButton(supportedContentTypes: [.plainText, .image]) { providers in
                    send(providers)
                }
                .labelStyle(.titleAndIcon)
                Button {
                    clip.requestFromComputer()
                } label: {
                    Label("Get \(host)’s clipboard", systemImage: "arrow.down.doc")
                }
                .disabled(!model.isConnected)
                Toggle("Send my copy when DuoDesk opens", isOn: $clip.autoSend)
            } header: {
                Text("Send now")
            } footer: {
                Text("iOS lets an app read the clipboard only when you paste. The Paste button sends what you copied without a prompt; the last switch makes iOS ask “Allow Paste?” each time.")
            }

            Section("Recent") {
                if clip.history.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(clip.history) { item in
                    Button {
                        clip.copyAgain(item)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.dir == "in" ? "arrow.down.left" : "arrow.up.right")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(item.text).lineLimit(3).multilineTextAlignment(.leading)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle("Clipboard")
    }

    private func send(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in clip.sendText(text, force: true) }
                }
                return
            }
            if p.canLoadObject(ofClass: UIImage.self) {
                _ = p.loadObject(ofClass: UIImage.self) { image, _ in
                    guard let image else { return }
                    Task { @MainActor in clip.sendImage(image) }
                }
                return
            }
        }
    }
}
