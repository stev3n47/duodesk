// Pairing.swift — SAS pairing against a discovered host.
// Flow (same as shared/link.js and mac/pairing.js):
//   1. UDP beacon brings us a DiscoveredDevice (host, address, port, fp).
//   2. Open WSS, pin fp, send pair.start with our commit = sha256(nw bytes).
//   3. Host answers pair.nonce with its nm.
//   4. We reveal nw via pair.reveal.
//   5. Both sides compute sasCode(fp, nw, nm) and show the 6 digits.
//   6. User taps "Codes match" on both -> we send pair.confirm.
//   7. Host sends pair.ok with the reconnect token; we store it in Keychain.

import Foundation

@MainActor
final class Pairing: NSObject, ObservableObject, LinkDelegate {
    enum Phase: Equatable {
        case idle
        case connecting
        case awaitingNonce
        case awaitingHostCommit  // we've sent reveal, waiting for pair.ok or pair.cancel
        case displayingSAS(String)
        case succeeded(PairedHost)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private let device: DiscoveredDevice
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let pinner = PinningProxy()
    private var timeout: Timer?

    private let nw: String
    private var nm: String = ""
    private var sas: String = ""

    init(device: DiscoveredDevice) {
        self.device = device
        self.nw = P.randomHex(16)
        super.init()
        pinner.expectedFingerprint = device.fp
    }

    func begin() {
        guard phase == .idle else { return }
        phase = .connecting

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: pinner, delegateQueue: nil)
        self.session = session

        var comps = URLComponents()
        comps.scheme = "wss"
        comps.host = device.address
        comps.port = Int(device.port)
        comps.path = "/"
        guard let url = comps.url else {
            phase = .failed("bad address")
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = P.MAX_PAYLOAD
        task = t
        t.resume()

        timeout = Timer.scheduledTimer(withTimeInterval: Double(P.PAIR_TIMEOUT_MS) / 1000.0,
                                       repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fail("pair_timeout") }
        }

        receiveLoop()
        sendStart()
    }

    func userConfirm() {
        guard case .displayingSAS = phase else { return }
        send(["t": P.T.PAIR_CONFIRM])
        phase = .awaitingHostCommit
    }

    func cancel() {
        send(["t": P.T.PAIR_CANCEL])
        teardown()
        phase = .failed("cancelled")
    }

    // MARK: - Protocol

    private func sendStart() {
        let msg: [String: Any] = [
            "t": P.T.PAIR_START,
            "v": P.PROTOCOL_VERSION,
            "id": Store.shared.selfId,
            "name": Store.shared.selfName,
            "os": P.OS.ios,
            "commit": P.commitOf(nw),
        ]
        send(msg)
        phase = .awaitingNonce
    }

    private func send(_ msg: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.ingest(text: text)
                    }
                    if case .succeeded = self.phase {
                        // done
                    } else if case .failed = self.phase {
                        // done
                    } else {
                        self.receiveLoop()
                    }
                case .failure(let error):
                    self.fail("transport: \(error.localizedDescription)")
                }
            }
        }
    }

    private func ingest(text: String) {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let msg = any as? [String: Any],
              let t = msg["t"] as? String else {
            fail("bad_message")
            return
        }
        switch t {
        case P.T.PAIR_NONCE:
            guard let nonce = msg["nonce"] as? String else { fail("bad pair.nonce"); return }
            nm = nonce
            send([
                "t": P.T.PAIR_REVEAL,
                "nonce": nw,
            ])
            sas = P.sasCode(fp: device.fp, nwHex: nw, nmHex: nm)
            phase = .displayingSAS(sas)

        case P.T.PAIR_OK:
            guard let token = msg["token"] as? String,
                  let macId = msg["macId"] as? String,
                  let macName = msg["macName"] as? String,
                  let os = msg["os"] as? String else {
                fail("bad pair.ok")
                return
            }
            let host = PairedHost(
                id: macId,
                name: macName,
                os: os,
                address: device.address,
                port: device.port,
                fp: device.fp,
                pairedAt: Date(),
                lastSeen: Date()
            )
            Store.shared.save(host: host, token: token)
            teardown()
            phase = .succeeded(host)

        case P.T.PAIR_CANCEL:
            fail("peer_cancelled")

        case P.T.ERROR:
            fail((msg["code"] as? String) ?? "error")

        default:
            // The host is only allowed to send pair.*. Anything else before pair.ok is a protocol error.
            break
        }
    }

    private func fail(_ reason: String) {
        teardown()
        phase = .failed(reason)
    }

    private func teardown() {
        timeout?.invalidate(); timeout = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - LinkDelegate (unused during pairing; here to satisfy the protocol if we reuse Link later)

    nonisolated func link(_ link: Link, didConnect welcome: [String: Any]) {}
    nonisolated func link(_ link: Link, didReceive message: [String: Any]) {}
    nonisolated func link(_ link: Link, didCloseWith error: Link.CloseReason) {}
}
