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
    func peerLink(_ link: PeerLink, didCloseWith reason: PeerLink.CloseReason)
}

final class PeerLink: NSObject, @unchecked Sendable {
    enum State {
        case idle, connecting, open, closing, closed
    }

    enum CloseReason {
        case bye
        case replaced
        case released
        case asleep
        case busy(String)
        case timeout
        case error(String)
        case versionMismatch
        case badToken
        case transport(Error)

        var text: String {
            switch self {
            case .bye: return "The computer disconnected"
            case .replaced: return "Another device took over"
            case .released: return "The computer let go of this device"
            case .asleep: return "The computer went to sleep"
            case .busy(let s): return s.isEmpty ? "The computer is in use" : s
            case .timeout: return "Timed out"
            case .error(let s): return "Error: \(s)"
            case .versionMismatch: return "Protocol version mismatch"
            case .badToken: return "Not paired any more: pair again"
            case .transport(let e): return "Connection lost: \(e.localizedDescription)"
            }
        }
    }

    weak var delegate: PeerLinkDelegate?

    private let lock = NSLock()
    private var _state: State = .idle
    private var _pending = 0
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Bytes handed to the socket that it hasn't taken yet. Senders of big things (files,
    /// pictures) wait while this is large so pings and input never queue behind them.
    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _pending
    }

    private let host: PairedHost
    private let token: String
    private let selfId: String
    private let selfName: String
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

    private func setState(_ s: State) {
        lock.lock(); _state = s; lock.unlock()
    }

    func connect() {
        let st = state
        guard st == .idle || st == .closed else { return }
        setState(.connecting)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: delegateProxy, delegateQueue: nil)

        var components = URLComponents()
        components.scheme = "wss"
        components.host = host.address
        components.port = Int(host.port)
        components.path = "/"
        guard let url = components.url else {
            fail(.error("bad address"))
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = P.MAX_PAYLOAD
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()

        receiveLoop(task)
        sendHello()
    }

    /// Say goodbye (a phone that leaves on purpose gets no grace to resume) and close.
    func disconnect() {
        guard state != .closed else { return }
        setState(.closing)
        lock.lock(); let task = self.task; lock.unlock()
        if let task, let data = try? JSONSerialization.data(withJSONObject: ["t": P.T.BYE]),
           let text = String(data: data, encoding: .utf8) {
            task.send(.string(text)) { [weak self] _ in self?.teardown() }
            // If the socket never takes it, close anyway.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.teardown() }
        } else {
            teardown()
        }
    }

    // MARK: - Send

    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: []),
              data.count <= P.MAX_PAYLOAD,
              let text = String(data: data, encoding: .utf8) else { return false }
        lock.lock()
        let task = self.task
        if task != nil { _pending += data.count }
        lock.unlock()
        guard let task else { return false }
        let size = data.count
        task.send(.string(text)) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self._pending -= size; self.lock.unlock()
        }
        return true
    }

    private func sendHello() {
        // No `fx`: that makes the computer move files over HTTPS (shared/fastfile.js), which
        // this app doesn't speak. Android doesn't send it either. `takeover`: this device only
        // connects when its person asked for it.
        let hello: [String: Any] = [
            "t": P.T.HELLO,
            "v": P.PROTOCOL_VERSION,
            "id": selfId,
            "name": selfName,
            "os": P.OS.ios,
            "token": token,
            "takeover": true,
        ]
        send(hello)
    }

    // MARK: - Receive

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
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
                    self.receiveLoop(task)
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
            setState(.open)
            DispatchQueue.main.async { [weak self] in self?.startKeepalive() }
            delegate?.peerLink(self, didConnect: msg)
        case P.T.ERROR:
            let code = (msg["code"] as? String) ?? ""
            let message = (msg["message"] as? String) ?? ""
            switch code {
            case P.E.VERSION_MISMATCH: fail(.versionMismatch)
            case P.E.BAD_TOKEN:        fail(.badToken)
            case P.E.REPLACED:         fail(.replaced)
            case P.E.RELEASED:         fail(.released)
            case P.E.ASLEEP:           fail(.asleep)
            case P.E.BUSY:             fail(.busy(message))
            default:                   fail(.error(message.isEmpty ? code : message))
            }
        case P.T.PING:
            send(["t": P.T.PONG, "ts": msg["ts"] ?? Date().timeIntervalSince1970 * 1000])
        case P.T.PONG:
            break
        case P.T.BYE:
            fail(.bye)
        default:
            delegate?.peerLink(self, didReceive: msg)
        }
    }

    // MARK: - Keepalive (timers live on the main run loop)

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
        lock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        _state = .closed
        _pending = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate(); self?.pingTimer = nil
            self?.silenceTimer?.invalidate(); self?.silenceTimer = nil
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
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
