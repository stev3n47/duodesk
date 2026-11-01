// RemotePage.swift — touchpad and keyboard for the connected computer. The page tells the
// computer when it opens (remote.hello) and lets go when it closes (remote.release); the
// computer answers whether it takes the input (remote.state) and the page says why not.

import SwiftUI

struct RemotePage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var remote: RemoteFeature
    @State private var softKeyboard = false

    var body: some View {
        Group {
            if let host = model.connectedHost {
                VStack(spacing: 12) {
                    banner(host)
                    ZStack {
                        TrackpadView(remote: remote)
                        VStack(spacing: 6) {
                            Image(systemName: "hand.draw").font(.system(size: 30))
                            Text("Slide to move · tap to click · hold to right-click · two fingers to scroll")
                                .font(.caption).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .padding()
                        .allowsHitTesting(false)
                    }
                    HStack(spacing: 10) {
                        Button { remote.click(P.Button.LEFT) } label: {
                            Label("Click", systemImage: "cursorarrow.click").frame(maxWidth: .infinity)
                        }
                        Button { remote.click(P.Button.RIGHT) } label: {
                            Label("Right-click", systemImage: "cursorarrow.click.2").frame(maxWidth: .infinity)
                        }
                        Button { softKeyboard.toggle() } label: {
                            Label(softKeyboard ? "Hide" : "Keyboard", systemImage: "keyboard").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $remote.speed, in: 0.3...3)
                        Image(systemName: "hare")
                    }
                    .foregroundStyle(.secondary)
                    Toggle("Tap to click", isOn: $remote.tapClick)
                }
                .padding()
                .background(
                    KeyCaptureView(softKeyboard: softKeyboard,
                                   onText: { remote.type($0) },
                                   onBackspace: { remote.backspace() },
                                   onKey: { code, down in remote.key(code, down: down) })
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                )
            } else {
                EmptyRemoteView()
            }
        }
        .navigationTitle("Remote")
        .onAppear { remote.open() }
        .onDisappear { remote.close() }
    }

    @ViewBuilder
    private func banner(_ host: PairedHost) -> some View {
        if remote.unsupported {
            note("\(host.name) doesn’t answer the remote. Update DuoDesk there to the version that supports iPhone and iPad.",
                 symbol: "exclamationmark.triangle.fill", tint: .orange)
        } else if remote.off {
            VStack(alignment: .leading, spacing: 8) {
                note("The remote is off on \(host.name).", symbol: "power", tint: .orange)
                Button("Turn it on") { remote.turnOn() }.buttonStyle(.bordered)
            }
        } else if remote.allowed == false, !remote.why.isEmpty {
            note(remote.why, symbol: "hand.raised.fill", tint: .orange)
        } else if remote.allowed == nil {
            note("Asking \(host.name)…", symbol: "ellipsis.circle", tint: .secondary)
        }
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        Label { Text(text).font(.footnote) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyRemoteView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Not connected").font(.title3)
            Text("Connect to a paired computer from Overview, then come back here.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }
}
