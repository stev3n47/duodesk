// Link.swift — WSS client on P.PORT. Pins the host's TLS cert by sha256(leaf DER)
// against the stored `fp` from pairing. Everything we send is JSON text, one object per
// frame, max P.MAX_PAYLOAD bytes.
//
// This is the control plane. All media (WebRTC) is set up through it. BLE pipes tunnel
// an identical WSS session byte-for-byte to 127.0.0.1, so this same class works there too.
//
// Named PeerLink so it doesn't collide with SwiftUI.Link in UI code.

import Foundation
import CryptoKit

protocol PeerLinkDelegate: AnyObject {
    func peerLink(_ link: PeerLink, didConnect welcome: [String: Any])
    func peerLink(_ link: PeerLink, didReceive message: [String: Any])
    func peerLink(_ link: PeerLink, didCloseWith error: PeerLink.CloseReason)
}

final class PeerLink: NSObject {
    enum State {
        case idle, connecting, open, closing, closed
    }

    enum CloseReason {
        case bye
        case replaced
        case timeout
        case error(String)
        case versionMismatch
        case badToken
        case transport(Error)
    }

    enum LinkError: Error {
        case pinningFailed
        case unexpectedBinary
        case protocolError(String)
        case notConnected
    }

    weak var delegate: PeerLinkDelegate?

    private(set) var state: State = .idle

    private let host: PairedHost
    private let token: String
    private let selfId: String
    private let selfName: String

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let delegateProxy = PinningProxy()

    private var pingTimer: Timer?
    private var silenceTimer: Timer?
    private var lastSeen = Date()

    init(host: PairedHost, token: String, selfId: String, selfName: String) {
        self.host = host
        self.token = token
        self.selfId = selfId
        self.selfName = selfName
        super.init()
        delegateProxy.expectedFingerprint = host.fp
    }

    func connect() {
        guard state == .idle || state == .closed else { return }
        state = .connecting
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: delegateProxy, delegateQueue: nil)
        self.session = session

        var components = URLComponents()
        components.scheme = "wss"
        components.host = host.address
        components.port = Int(host.port)
        components.path = "/"
        guard let url = components.url else {
            fail(.error("bad url"))
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = P.MAX_PAYLOAD
        self.task = task
        task.resume()

        receiveLoop()
        sendHello()
    }

    func disconnect() {
        guard state != .closed else { return }
        state = .closing
        send(["t": P.T.BYE])
        task?.cancel(with: .goingAway, reason: nil)
        teardown()
    }

    // MARK: - Send

    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        guard let task else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []) else {
            return false
        }
        guard data.count <= P.MAX_PAYLOAD else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    private func sendHello() {
        let hello: [String: Any] = [
            "t": P.T.HELLO,
            "v": P.PROTOCOL_VERSION,
            "id": selfId,
            "name": selfName,
            "os": P.OS.ios,
            "token": token,
            "fx": 1,
            "takeover": true,
        ]
        send(hello)
    }

    // MARK: - Receive

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.lastSeen = Date()
                switch message {
                case .string(let text):
                    self.ingest(text: text)
                case .data:
                    // The protocol is strict JSON text. Treat binary as a protocol error.
                    self.fail(.error("unexpected binary frame"))
                    return
                @unknown default:
                    break
                }
                if self.state != .closed {
                    self.receiveLoop()
                }
            case .failure(let error):
                self.fail(.transport(error))
            }
        }
    }

    private func ingest(text: String) {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let msg = any as? [String: Any],
              let t = msg["t"] as? String
        else {
            fail(.error(P.E.BAD_MESSAGE))
            return
        }
        switch t {
        case P.T.WELCOME:
            state = .open
            startKeepalive()
            delegate?.peerLink(self, didConnect: msg)
        case P.T.ERROR:
            let code = (msg["code"] as? String) ?? ""
            switch code {
            case P.E.VERSION_MISMATCH: fail(.versionMismatch)
            case P.E.BAD_TOKEN:        fail(.badToken)
            case P.E.REPLACED:         fail(.replaced)
            default:                   fail(.error(code))
            }
        case P.T.PING:
            send(["t": P.T.PONG, "ts": msg["ts"] ?? Date().timeIntervalSince1970 * 1000])
        case P.T.PONG:
            // keepalive bookkeeping; lastSeen already touched
            break
        case P.T.BYE:
            fail(.bye)
        default:
            delegate?.peerLink(self, didReceive: msg)
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Double(P.PING_MS) / 1000.0, repeats: true) { [weak self] _ in
            self?.send(["t": P.T.PING, "ts": Date().timeIntervalSince1970 * 1000])
        }
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastSeen) > Double(P.TIMEOUT_MS) / 1000.0 {
                self.fail(.timeout)
            }
        }
    }

    // MARK: - Teardown

    private func teardown() {
        pingTimer?.invalidate(); pingTimer = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .closed
    }

    private func fail(_ reason: CloseReason) {
        guard state != .closed else { return }
        teardown()
        delegate?.peerLink(self, didCloseWith: reason)
    }
}

// MARK: - TLS fingerprint pinning

final class PinningProxy: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    /// Lowercase hex, no colons. Matches P.normFingerprint output.
    var expectedFingerprint: String = ""

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let leaf: SecCertificate?
        if #available(iOS 15.0, *) {
            leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            leaf = SecTrustGetCertificateAtIndex(trust, 0)
        }

        guard let certificate = leaf else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let der = SecCertificateCopyData(certificate) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        if fp == P.normFingerprint(expectedFingerprint) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
