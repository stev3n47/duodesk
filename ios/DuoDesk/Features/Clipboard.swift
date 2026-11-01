// Clipboard.swift — clipboard text and pictures both ways (android Clip.kt, mac/clipboard.js).
//
// One-to-one the wire form is plain: {t:'clip', text} (no timestamps; those are Multi-device).
// A side sends only while the other's clip.policy says it accepts. Pictures: PNG up to 10 MiB
// in 256 KiB pieces (clip.image header + clip.image.part), only when both sides said images.
//
// iOS reads another app's clipboard only with the person's say-so: the system Paste button
// (PasteButton in the Clipboard page) never prompts; reading it by itself (the automatic
// option) makes iOS ask "Allow Paste?" unless the person set Paste from Other Apps to Allow.
// Writing the clipboard never prompts, so the computer's copies land here at once.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardFeature: ObservableObject, Feature {
    struct Item: Identifiable {
        let id = UUID()
        let dir: String      // "in" (from the computer) or "out"
        let text: String
    }

    @Published private(set) var history: [Item] = []
    @Published private(set) var peerAccepts = false
    @Published private(set) var peerImages = false

    /// Send what is on the clipboard when DuoDesk opens (iOS may ask to allow the paste).
    @Published var autoSend: Bool {
        didSet { UserDefaults.standard.set(autoSend, forKey: "clip.autoSend") }
    }

    /// Pictures both ways (clip.policy images).
    @Published var picturesOn: Bool {
        didSet {
            UserDefaults.standard.set(picturesOn, forKey: "clip.images")
            sendPolicy()
        }
    }

    private let peer: Peer
    private let sync: PairSyncFeature
    private var lastOut: String?
    private var lastIn: String?
    private var changeCount = UIPasteboard.general.changeCount
    private var outId = ""
    private var inPic: PicIn?

    private struct PicIn {
        let id: String
        let w: Int
        let h: Int
        let bytes: Int
        let parts: Int
        let at: Date
        var buf = Data()
        var got = 0
    }

    init(peer: Peer, sync: PairSyncFeature) {
        self.peer = peer
        self.sync = sync
        self.autoSend = UserDefaults.standard.bool(forKey: "clip.autoSend")
        self.picturesOn = UserDefaults.standard.bool(forKey: "clip.images")
    }

    var receiving: Bool { sync.get("clipboard", .incoming) }
    var sending: Bool { sync.get("clipboard", .outgoing) }

    var canSendPictures: Bool {
        picturesOn && peerImages && sending && peer.isOpen
    }

    // MARK: - Feature

    func onWelcome(host: PairedHost) {
        peerAccepts = false
        peerImages = false
        sendPolicy()
    }

    func onClosed() {
        peerAccepts = false
        peerImages = false
        outId = ""
        inPic = nil
    }

    func sendPolicy() {
        let accept = receiving
        peer.send(["t": P.T.CLIP_POLICY, "accept": accept, "images": accept && picturesOn])
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case P.T.CLIP_POLICY:
            peerAccepts = (m["accept"] as? Bool) ?? false
            peerImages = (m["images"] as? Bool) ?? false
        case P.T.CLIP:
            outId = ""
            inPic = nil
            if receiving, let text = m["text"] as? String, !text.isEmpty,
               text.utf8.count <= P.CLIP_MAX_BYTES {
                receiveText(text)
            }
        case P.T.CLIP_IMAGE:
            header(m)
        case P.T.CLIP_IMAGE_PART:
            part(m)
        default:
            return false
        }
        return true
    }

    // MARK: - Text

    /// `force`: the person asked (the Paste button); else only when the computer takes it.
    @discardableResult
    func sendText(_ text: String, force: Bool) -> Bool {
        guard peer.isOpen, !text.isEmpty else { return false }
        if !force && (text == lastOut || text == lastIn) { return false }
        guard text.utf8.count <= P.CLIP_MAX_BYTES else { return false }
        if !force && !peerAccepts { return false }
        outId = ""
        lastOut = text
        remember("out", text)
        return peer.send(["t": P.T.CLIP, "text": text])
    }

    /// Ask the computer to send what it has copied.
    func requestFromComputer() {
        peer.send(["t": P.T.CLIP_REQUEST])
    }

    private func receiveText(_ text: String) {
        lastIn = text
        remember("in", text)
        UIPasteboard.general.string = text
        changeCount = UIPasteboard.general.changeCount
    }

    /// DuoDesk came to the front: send a new copy if the person turned that on.
    func checkPasteboard() {
        guard autoSend, sending, peer.isOpen else { return }
        let pb = UIPasteboard.general
        guard pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        if pb.hasStrings, let s = pb.string {
            sendText(s, force: false)
        } else if pb.hasImages, canSendPictures, let img = pb.image {
            sendImage(img)
        }
    }

    // MARK: - Pictures out

    func sendImage(_ image: UIImage) {
        guard canSendPictures else { return }
        Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { ClipboardFeature.toPng(image) }.value
            guard let self, let png else { return }
            await self.sendPicture(png.data, w: png.w, h: png.h)
        }
    }

    private func sendPicture(_ png: Data, w: Int, h: Int) async {
        guard canSendPictures, png.count <= P.CLIP_IMAGE_MAX_BYTES else { return }
        let id = P.randomHex(8)
        outId = id
        let size = P.CLIP_IMAGE_PART_BYTES
        let parts = (png.count + size - 1) / size
        peer.send(["t": P.T.CLIP_IMAGE, "id": id, "w": w, "h": h, "bytes": png.count, "parts": parts])
        for i in 0..<parts {
            while peer.pendingBytes > 512 * 1024 {
                if outId != id || !peer.isOpen { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard outId == id, canSendPictures else { return }
            let from = i * size
            let to = min(from + size, png.count)
            peer.send(["t": P.T.CLIP_IMAGE_PART, "id": id, "i": i,
                       "data": png.subdata(in: from..<to).base64EncodedString()])
        }
        if outId == id { outId = "" }
        remember("out", "Picture · \(w) × \(h)")
    }

    /// A PNG of at most CLIP_IMAGE_MAX_BYTES, made smaller while it is too big.
    nonisolated static func toPng(_ image: UIImage) -> (data: Data, w: Int, h: Int)? {
        var img = image
        for _ in 0..<5 {
            guard let data = img.pngData() else { return nil }
            let w = Int(img.size.width * img.scale)
            let h = Int(img.size.height * img.scale)
            if data.count <= P.CLIP_IMAGE_MAX_BYTES { return (data, w, h) }
            let k = (Double(P.CLIP_IMAGE_MAX_BYTES) / Double(data.count)).squareRoot() * 0.9
            let target = CGSize(width: max(1, (Double(w) * k).rounded()), height: max(1, (Double(h) * k).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let current = img
            img = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                current.draw(in: CGRect(origin: .zero, size: target))
            }
        }
        return nil
    }

    // MARK: - Pictures in

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func isPng(_ d: Data) -> Bool {
        d.count > 8 && Array(d.prefix(8)) == pngSignature
    }

    private func header(_ m: [String: Any]) {
        inPic = nil
        guard let id = m["id"] as? String, !id.isEmpty, id.count <= 128 else { return }
        let w = min(max((m["w"] as? Int) ?? 0, 0), 65535)
        let h = min(max((m["h"] as? Int) ?? 0, 0), 65535)
        // Whole in one message (Multi-device's form).
        if let inline = m["png"] as? String, !inline.isEmpty {
            if inline.count <= (P.CLIP_IMAGE_MAX_BYTES * 4 + 2) / 3 + 8,
               let png = Data(base64Encoded: inline, options: .ignoreUnknownCharacters),
               png.count <= P.CLIP_IMAGE_MAX_BYTES, Self.isPng(png) {
                receivePicture(png, w: w, h: h)
            }
            return
        }
        let bytes = (m["bytes"] as? Int) ?? 0
        let parts = (m["parts"] as? Int) ?? 0
        guard bytes >= 9, bytes <= P.CLIP_IMAGE_MAX_BYTES,
              parts == (bytes + P.CLIP_IMAGE_PART_BYTES - 1) / P.CLIP_IMAGE_PART_BYTES else { return }
        inPic = PicIn(id: id, w: w, h: h, bytes: bytes, parts: parts, at: Date())
    }

    private func part(_ m: [String: Any]) {
        guard var c = inPic, (m["id"] as? String) == c.id else { return }
        guard let data = m["data"] as? String, !data.isEmpty,
              (m["i"] as? Int) == c.got,
              data.count <= (P.CLIP_IMAGE_PART_BYTES * 4 + 2) / 3 + 8,
              Date().timeIntervalSince(c.at) <= 60,
              let bytes = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
              c.buf.count + bytes.count <= c.bytes,
              !(c.got + 1 < c.parts && bytes.count != P.CLIP_IMAGE_PART_BYTES)
        else {
            inPic = nil
            return
        }
        c.buf.append(bytes)
        c.got += 1
        if c.got < c.parts {
            inPic = c
            return
        }
        inPic = nil
        if c.buf.count == c.bytes, Self.isPng(c.buf) {
            receivePicture(c.buf, w: c.w, h: c.h)
        }
    }

    private func receivePicture(_ png: Data, w: Int, h: Int) {
        guard receiving, picturesOn else { return }
        outId = ""
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        changeCount = UIPasteboard.general.changeCount
        let size = (w > 0 && h > 0) ? "\(w) × \(h)" : "\(png.count / 1024) KB"
        remember("in", "Picture · \(size)")
    }

    // MARK: - Recent

    private func remember(_ dir: String, _ text: String) {
        history.removeAll { $0.text == text }
        history.insert(Item(dir: dir, text: text), at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
    }

    /// A Recent item back on this clipboard.
    func copyAgain(_ item: Item) {
        UIPasteboard.general.string = item.text
        changeCount = UIPasteboard.general.changeCount
    }
}
