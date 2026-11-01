// ScreenPage.swift — show the computer's screen on this device (a mirror, or an extra monitor
// when the computer is in Extend). The viewer is full screen; its Close also stops the computer
// sharing. Touch works as a touchpad (slide moves the pointer, tap clicks) or directly.

import SwiftUI

struct ScreenPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var screen: ScreenFeature
    @State private var showing = false

    var body: some View {
        let host = model.connectedHost?.name ?? "the computer"
        List {
            Section {
                if model.isConnected {
                    Button {
                        showing = true
                    } label: {
                        Label("Show \(host)’s screen", systemImage: "rectangle.on.rectangle")
                    }
                    if screen.sharing {
                        Label("\(host) is sharing its screen (\(screen.mode.isEmpty ? "mirror" : screen.mode)).",
                              systemImage: "dot.radiowaves.left.and.right").font(.footnote)
                    }
                } else {
                    Label("Connect to a computer from Overview first.", systemImage: "wifi.slash").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Mirror shows the computer’s screen as it is. Extend adds this device as another monitor; pick it in the viewer.")
            }

            Section("Viewer") {
                Toggle("Touchpad", isOn: option("screen.touchpad", true))
                Toggle("Sound from the computer", isOn: option("screen.sound", false))
                Toggle("Smoother, a little later", isOn: option("screen.smooth", false))
                Toggle("Apple Pencil as a pen", isOn: option("screen.pen", true))
            }
        }
        .navigationTitle("Screen")
        .fullScreenCover(isPresented: $showing) {
            ViewerScreen(isPresented: $showing)
                .environmentObject(screen)
        }
    }

    private func option(_ key: String, _ fallback: Bool) -> Binding<Bool> {
        Binding(get: { screen.option(key, default: fallback) }, set: { screen.setOption(key, $0) })
    }
}

struct ViewerScreen: View {
    @EnvironmentObject var screen: ScreenFeature
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ViewerWebView(bridge: screen.bridge)
                .ignoresSafeArea()
            HStack(spacing: 12) {
                if screen.canControl {
                    Menu {
                        Button("Mirror") { screen.pick(mode: "mirror") }
                        if screen.modes.contains("extend") {
                            Button("Extend") { screen.pick(mode: "extend") }
                        }
                    } label: {
                        Image(systemName: "rectangle.on.rectangle").padding(10)
                    }
                }
                Button {
                    screen.end()
                    isPresented = false
                } label: {
                    Image(systemName: "xmark").padding(10)
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .background(Capsule().fill(.black.opacity(0.45)))
            .padding(12)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .onAppear { screen.attach() }
        .onDisappear { screen.detach() }
    }
}
