// RemotePage.swift — trackpad + hidden keyboard capture. Sends remote.* messages over the
// active Link. If no Link, shows an empty state that tells the user to connect first.

import SwiftUI

struct RemotePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.currentLink != nil {
                RemoteSurface(link: model.currentLink)
            } else {
                EmptyRemoteView()
            }
        }
        .navigationTitle("Remote")
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

private struct RemoteSurface: View {
    let link: PeerLink?
    @StateObject private var pointer = RemotePointerHolder()
    @FocusState private var kbFocus: Bool
    @State private var kbText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            trackpad
            Divider()
            HStack(spacing: 12) {
                Button {
                    link?.send(Remote.mouseDown(P.Button.LEFT))
                    link?.send(Remote.mouseUp(P.Button.LEFT))
                } label: {
                    Label("Click", systemImage: "cursorarrow.click").frame(maxWidth: .infinity)
                }
                Button {
                    link?.send(Remote.mouseDown(P.Button.RIGHT))
                    link?.send(Remote.mouseUp(P.Button.RIGHT))
                } label: {
                    Label("Right-click", systemImage: "cursorarrow.click.2").frame(maxWidth: .infinity)
                }
                Button { kbFocus = true } label: {
                    Label("Keyboard", systemImage: "keyboard").frame(maxWidth: .infinity)
                }
            }
            .padding()
            .buttonStyle(.borderedProminent)
            // Hidden text field — focusing it opens the iOS keyboard and feeds keystrokes
            // into the IME. We send remote.text on each change and remote.kd/ku for the
            // handful of control keys the field reports.
            TextField("", text: $kbText)
                .focused($kbFocus)
                .textFieldStyle(.plain)
                .opacity(0.01)
                .frame(height: 1)
                .onChange(of: kbText) { new in
                    if !new.isEmpty {
                        link?.send(Remote.text(new))
                        kbText = ""
                    }
                }
        }
        .onAppear {
            pointer.rebind(link: link)
            link?.send(Remote.hello())
        }
    }

    private var trackpad: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.thickMaterial)
                .overlay(
                    VStack {
                        Image(systemName: "hand.draw").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text("Trackpad").font(.caption).foregroundStyle(.secondary)
                    }
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            pointer.inner?.update(translation: CGPoint(x: g.translation.width,
                                                                       y: g.translation.height))
                        }
                        .onEnded { _ in pointer.inner?.begin() }
                )
                .simultaneousGesture(
                    TapGesture().onEnded { pointer.inner?.tap() }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded { pointer.inner?.twoFingerTap() }
                )
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

@MainActor
final class RemotePointerHolder: ObservableObject {
    var inner: RemotePointer?
    func rebind(link: PeerLink?) { inner = RemotePointer(link: link) }
}
