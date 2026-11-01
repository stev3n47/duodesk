// PairingPage.swift — show the SAS code once the pair flow is far enough; before that,
// pick a nearby device (or prefill one from a tap in Overview).

import SwiftUI

struct PairingPage: View {
    @EnvironmentObject var discovery: Discovery
    @StateObject private var pairing: PairingHolder

    init(prefilled: DiscoveredDevice? = nil) {
        _pairing = StateObject(wrappedValue: PairingHolder(seed: prefilled))
    }

    var body: some View {
        VStack {
            switch pairing.flow?.phase {
            case .displayingSAS(let code):
                sasView(code)
            case .succeeded(let host):
                successView(host)
            case .failed(let reason):
                failureView(reason)
            case .connecting, .awaitingNonce, .awaitingHostCommit:
                ProgressView("Pairing…")
            case .none, .idle:
                pickDeviceView()
            }
        }
        .padding()
        .navigationTitle("Pairing")
    }

    // MARK: - Subviews

    private func pickDeviceView() -> some View {
        List {
            Section("Found on Wi-Fi") {
                if discovery.devices.isEmpty {
                    Text("Looking for computers running DuoDesk on the same Wi-Fi…")
                        .foregroundStyle(.secondary)
                }
                ForEach(discovery.devices) { d in
                    Button {
                        pairing.start(with: d)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text("\(d.os.capitalized) · \(d.address)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Enter manually") {
                ManualEntryRow { host, port, fp in
                    let fake = DiscoveredDevice(id: "manual-\(UUID().uuidString)",
                                                name: "Manual",
                                                os: "unknown",
                                                address: host,
                                                port: port,
                                                fp: fp,
                                                role: "host",
                                                seenAt: Date())
                    pairing.start(with: fake)
                }
            }
        }
    }

    private func sasView(_ code: String) -> some View {
        VStack(spacing: 24) {
            Text("Codes should match on both devices")
                .font(.title3).multilineTextAlignment(.center)
            Text(formatSAS(code))
                .font(.system(size: 48, weight: .semibold, design: .monospaced))
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
            HStack(spacing: 12) {
                Button(role: .destructive) { pairing.cancel() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button {
                    pairing.flow?.userConfirm()
                } label: {
                    Text("Codes match").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func successView(_ host: PairedHost) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48)).foregroundStyle(.green)
            Text("Paired with \(host.name)").font(.title3)
            Text("You can use the Remote tab now.").foregroundStyle(.secondary)
            Button("Done") { pairing.flow = nil }
                .buttonStyle(.borderedProminent)
        }
    }

    private func failureView(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48)).foregroundStyle(.red)
            Text("Pairing failed").font(.title3)
            Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { pairing.flow = nil }
                .buttonStyle(.borderedProminent)
        }
    }

    private func formatSAS(_ s: String) -> String {
        guard s.count == 6 else { return s }
        let mid = s.index(s.startIndex, offsetBy: 3)
        return s[s.startIndex..<mid] + " " + s[mid..<s.endIndex]
    }
}

@MainActor
final class PairingHolder: ObservableObject {
    @Published var flow: Pairing?

    init(seed: DiscoveredDevice? = nil) {
        if let seed { start(with: seed) }
    }

    func start(with device: DiscoveredDevice) {
        let p = Pairing(device: device)
        flow = p
        p.begin()
    }

    func cancel() {
        flow?.cancel()
    }
}

private struct ManualEntryRow: View {
    @State private var host: String = ""
    @State private var port: String = "47800"
    @State private var fp: String = ""
    var onSubmit: (String, UInt16, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Host or IP", text: $host).textContentType(.URL).autocorrectionDisabled()
            TextField("Port", text: $port).keyboardType(.numberPad)
            TextField("Fingerprint (sha256)", text: $fp).autocorrectionDisabled()
            Button("Connect") {
                onSubmit(host, UInt16(port) ?? P.PORT, fp)
            }
            .disabled(host.isEmpty || fp.isEmpty)
        }
    }
}
