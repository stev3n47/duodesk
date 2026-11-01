// Files.swift — files both ways in the computers' batch protocol (mac/filesend.js, mac/drop.js;
// android Files.kt):
//   in:  file.offer {id, name, size, drop:'send', batch, rel, index, count, bytes}
//        -> file.accept -> file.chunk {id, seq, data (base64)}... -> file.end {id, sha256}
//        -> file.done {id, ok, path|error}; files.done {batch, ok, where, files} when the whole batch is here.
//   out: the same, the other way: an offer for every file, then chunks one file at a time while the
//        socket has little queued, so pings and input never wait behind a big file.
// Received files land in Documents/DuoDesk (the Files app shows it under On My iPhone > DuoDesk).
// No `fx` (HTTPS fast files) and no drag/paste/ReZume drops: this app says drag.policy accept:false.

import SwiftUI
import CryptoKit
import PhotosUI
import UniformTypeIdentifiers

struct Transfer: Identifiable, Equatable {
    enum State: Equatable { case active, ok, failed }

    let id: String          // the batch
    var title: String
    var upload: Bool
    var bytes: Int64
    var moved: Int64
    var state: State
    var version: Int        // later reports win, however the hops were scheduled

    var fraction: Double { bytes <= 0 ? 1 : min(1, Double(moved) / Double(bytes)) }
}

struct FileOffer: Sendable {
    let id: String
    let drop: String
    let size: Int64
    let batch: String
    let rel: String
    let count: Int
    let bytes: Int64
}

private func int64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }

private func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

// MARK: - Coming in

final class IncomingEngine: @unchecked Sendable {
    typealias Report = @Sendable (Transfer, String?) -> Void

    private final class Incoming {
        let id: String
        let batch: String
        let url: URL
        let rel: String
        let size: Int64
        let handle: FileHandle
        var hasher = SHA256()
        var got: Int64 = 0
        var seq = 0
        init(id: String, batch: String, url: URL, rel: String, size: Int64, handle: FileHandle) {
            self.id = id; self.batch = batch; self.url = url; self.rel = rel; self.size = size; self.handle = handle
        }
    }

    private final class Batch {
        let id: String
        let count: Int
        let bytes: Int64
        var done = 0
        var ok = true
        var got: Int64 = 0
        var tops: [String] = []
        var lastReport = Date.distantPast
        init(id: String, count: Int, bytes: Int64) { self.id = id; self.count = count; self.bytes = bytes }
    }

    private let queue = DispatchQueue(label: "duodesk.files.in")
    private let peer: Peer
    private let root: URL
    private var files: [String: Incoming] = [:]
    private var batches: [String: Batch] = [:]
    private var version = 0
    var report: Report?

    private func hostName() -> String { peer.host?.name ?? "your computer" }

    init(peer: Peer) {
        self.peer = peer
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = docs.appendingPathComponent("DuoDesk", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // The same cleaning as Android: nothing that could leave the folder or confuse a path.
    static func cleanSegment(_ s: String) -> String {
        var n = String(s.unicodeScalars.map { u -> Character in
            (u.value < 0x20 || u == "/" || u == ":" || u == "\\") ? "_" : Character(u)
        }).trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n == "." || n == ".." { n = "file" }
        return String(n.prefix(200))
    }

    private static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private func refuse(_ id: String, _ why: String) {
        peer.send(["t": P.T.FILE_REFUSE, "id": id, "why": why])
    }

    func offer(_ o: FileOffer) {
        queue.async { [self] in
            if files[o.id] != nil { return }
            guard o.drop == "send" else { return refuse(o.id, "not_allowed") }
            guard o.size >= 0, o.size <= 4 * 1024 * 1024 * 1024 else { return refuse(o.id, "too_big") }
            let relText = o.rel.isEmpty ? "" : o.rel
            let rel = relText.split(separator: "/").map(String.init).filter { !$0.isEmpty }.map(Self.cleanSegment)
            guard let name = rel.last else { return refuse(o.id, "bad_name") }
            let batchId = o.batch.isEmpty ? o.id : o.batch
            let batch: Batch
            if let b = batches[batchId] {
                batch = b
            } else {
                batch = Batch(id: batchId, count: max(1, o.count), bytes: o.bytes > 0 ? o.bytes : o.size)
                batches[batchId] = batch
            }
            if !batch.tops.contains(rel[0]) { batch.tops.append(rel[0]) }
            do {
                var dir = root
                for seg in rel.dropLast() { dir.appendPathComponent(seg, isDirectory: true) }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = Self.unique(dir.appendingPathComponent(name))
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: url)
                files[o.id] = Incoming(id: o.id, batch: batchId, url: url, rel: rel.joined(separator: "/"), size: o.size, handle: handle)
                peer.send(["t": P.T.FILE_ACCEPT, "id": o.id])
                publish(batch, force: true)
            } catch {
                refuse(o.id, "not_allowed")
                finished(batch, ok: false)
            }
        }
    }

    func chunk(id: String, seq: Int, data: String) {
        queue.async { [self] in
            guard let f = files[id] else { return }
            guard let bytes = Data(base64Encoded: data), seq == f.seq, f.got + Int64(bytes.count) <= f.size else {
                return abort(id, tell: true)
            }
            do { try f.handle.write(contentsOf: bytes) } catch { return abort(id, tell: true) }
            f.seq += 1
            f.hasher.update(data: bytes)
            f.got += Int64(bytes.count)
            if let b = batches[f.batch] {
                b.got += Int64(bytes.count)
                publish(b, force: false)
            }
        }
    }

    func end(id: String, sha256: String) {
        queue.async { [self] in
            guard let f = files.removeValue(forKey: id) else { return }
            let batch = batches[f.batch]
            try? f.handle.close()
            let ok = f.got == f.size && hex(f.hasher.finalize()) == sha256
            if !ok {
                try? FileManager.default.removeItem(at: f.url)
                peer.send(["t": P.T.FILE_DONE, "id": id, "ok": false, "error": "checksum"])
                if let batch { finished(batch, ok: false) }
                return
            }
            peer.send(["t": P.T.FILE_DONE, "id": id, "ok": true, "path": "DuoDesk/\(f.rel)"])
            if let batch { finished(batch, ok: true) }
        }
    }

    /// The computer cancelled it (or we do, tell: true).
    func cancel(id: String) {
        queue.async { [self] in abort(id, tell: false) }
    }

    func closeAll() {
        queue.async { [self] in
            for id in Array(files.keys) { abort(id, tell: false) }
            for b in batches.values { report?(snapshot(b, state: .failed), nil) }
            batches.removeAll()
        }
    }

    private func abort(_ id: String, tell: Bool) {
        guard let f = files.removeValue(forKey: id) else { return }
        try? f.handle.close()
        try? FileManager.default.removeItem(at: f.url)
        if tell { peer.send(["t": P.T.FILE_CANCEL, "id": id]) }
        if let b = batches[f.batch] { finished(b, ok: false) }
    }

    private func finished(_ b: Batch, ok: Bool) {
        b.done += 1
        if !ok { b.ok = false }
        guard b.done >= b.count else { return publish(b, force: false) }
        batches.removeValue(forKey: b.id)
        peer.send(["t": P.T.FILES_DONE, "batch": b.id, "ok": b.ok, "where": "Files › DuoDesk", "files": b.done])
        let what = b.tops.count == 1 ? b.tops[0] : "\(b.tops.count) items"
        let line = "\(b.ok ? "Received" : "Some of") \(what) from \(hostName())"
        report?(snapshot(b, state: b.ok ? .ok : .failed), line)
    }

    private func publish(_ b: Batch, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(b.lastReport) > 0.15 else { return }
        b.lastReport = now
        report?(snapshot(b, state: .active), nil)
    }

    private func snapshot(_ b: Batch, state: Transfer.State) -> Transfer {
        version += 1
        let what = b.tops.count == 1 ? b.tops[0] : "\(b.count) files"
        return Transfer(id: b.id, title: what, upload: false, bytes: b.bytes,
                        moved: state == .ok ? b.bytes : b.got, state: state, version: version)
    }
}

// MARK: - Going out

final class OutgoingEngine: @unchecked Sendable {
    typealias Report = @Sendable (Transfer, String?) -> Void

    struct Item {
        let url: URL
        let name: String
        let size: Int64
        let scoped: Bool     // a security-scoped URL from the file picker
        let cleanup: Bool    // a copy of ours to delete afterwards
    }

    private final class Out {
        enum State { case offered, accepted, sending, done }
        let id: String
        let batch: String
        let order: Int
        let item: Item
        var state = State.offered
        var cancelled = false
        init(id: String, batch: String, order: Int, item: Item) {
            self.id = id; self.batch = batch; self.order = order; self.item = item
        }
    }

    private final class OutBatch {
        let id: String
        let title: String
        let bytes: Int64
        var sent: Int64 = 0
        var lastReport = Date.distantPast
        var items: [Item]
        init(id: String, title: String, bytes: Int64, items: [Item]) {
            self.id = id; self.title = title; self.bytes = bytes; self.items = items
        }
    }

    private let lock = NSLock()
    private let peer: Peer
    private var outs: [String: Out] = [:]
    private var batches: [String: OutBatch] = [:]
    private var pumping = false
    private var version = 0
    private var counter = 0
    var report: Report?

    private func hostName() -> String { peer.host?.name ?? "your computer" }

    init(peer: Peer) { self.peer = peer }

    private func nextVersion() -> Int {
        lock.lock(); defer { lock.unlock() }
        version += 1
        return version
    }

    /// Offer every file now. False when there is nothing to send to.
    @discardableResult
    func send(_ items: [Item]) -> Bool {
        guard peer.isOpen, !items.isEmpty else { return false }
        // Two files with one name in a batch: the second becomes "name 2".
        var seen = Set<String>()
        let unique: [Item] = items.map { it in
            var n = it.name
            var i = 2
            let ext = (it.name as NSString).pathExtension
            let base = (it.name as NSString).deletingPathExtension
            while !seen.insert(n).inserted {
                n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
                i += 1
            }
            return Item(url: it.url, name: n, size: it.size, scoped: it.scoped, cleanup: it.cleanup)
        }
        let batchId = UUID().uuidString
        let bytes = unique.reduce(Int64(0)) { $0 + $1.size }
        let title = unique.count == 1 ? unique[0].name : "\(unique.count) items"
        lock.lock()
        batches[batchId] = OutBatch(id: batchId, title: title, bytes: bytes, items: unique)
        var offers: [[String: Any]] = []
        for (index, it) in unique.enumerated() {
            let id = UUID().uuidString
            counter += 1
            outs[id] = Out(id: id, batch: batchId, order: counter, item: it)
            offers.append(["t": P.T.FILE_OFFER, "id": id, "name": it.name, "size": it.size, "drop": "send",
                           "batch": batchId, "rel": it.name, "index": index, "count": unique.count, "bytes": bytes])
        }
        lock.unlock()
        report?(Transfer(id: batchId, title: title, upload: true, bytes: bytes, moved: 0, state: .active, version: nextVersion()), nil)
        for o in offers { peer.send(o) }
        return true
    }

    func accepted(id: String) {
        lock.lock()
        if let o = outs[id], o.state == .offered { o.state = .accepted }
        lock.unlock()
        startPump()
    }

    /// Refused or cancelled by the computer: this file won't go.
    func dropped(id: String) {
        lock.lock()
        let o = outs.removeValue(forKey: id)
        o?.cancelled = true
        lock.unlock()
    }

    func batchDone(_ m: [String: Any]) {
        guard let id = m["batch"] as? String else { return }
        let ok = (m["ok"] as? Bool) ?? false
        lock.lock()
        let b = batches.removeValue(forKey: id)
        for (k, o) in outs where o.batch == id { outs.removeValue(forKey: k) }
        lock.unlock()
        guard let b else { return }
        cleanup(b)
        let line = ok ? "Sent \(b.title) to \(hostName())" : "\(b.title) didn’t all arrive on \(hostName())"
        report?(Transfer(id: b.id, title: b.title, upload: true, bytes: b.bytes, moved: ok ? b.bytes : b.sent,
                         state: ok ? .ok : .failed, version: nextVersion()), line)
    }

    func closeAll() {
        lock.lock()
        for o in outs.values { o.cancelled = true }
        outs.removeAll()
        let all = Array(batches.values)
        batches.removeAll()
        lock.unlock()
        for b in all {
            cleanup(b)
            report?(Transfer(id: b.id, title: b.title, upload: true, bytes: b.bytes, moved: b.sent,
                             state: .failed, version: nextVersion()), nil)
        }
    }

    private func cleanup(_ b: OutBatch) {
        for it in b.items where it.cleanup { try? FileManager.default.removeItem(at: it.url) }
    }

    // One file at a time, so a big one never starves the others' turn.
    private func startPump() {
        lock.lock()
        if pumping { lock.unlock(); return }
        pumping = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in await pump() }
    }

    private func pump() async {
        while let next = takeNext() {
            await sendFile(next)
        }
    }

    /// The oldest accepted file, marked as sending; nil (and the pump stops) when none is left.
    private func takeNext() -> Out? {
        lock.lock(); defer { lock.unlock() }
        guard let next = outs.values.filter({ $0.state == .accepted }).min(by: { $0.order < $1.order }) else {
            pumping = false
            return nil
        }
        next.state = .sending
        return next
    }

    private func markDone(_ o: Out) {
        lock.lock(); o.state = .done; lock.unlock()
    }

    private func isCancelled(_ o: Out) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return o.cancelled
    }

    private func progress(_ o: Out, _ n: Int) {
        lock.lock()
        guard let b = batches[o.batch] else { lock.unlock(); return }
        b.sent += Int64(n)
        let now = Date()
        let due = now.timeIntervalSince(b.lastReport) > 0.15
        if due { b.lastReport = now }
        let t = Transfer(id: b.id, title: b.title, upload: true, bytes: b.bytes, moved: b.sent, state: .active, version: 0)
        lock.unlock()
        if due {
            var t2 = t
            t2.version = nextVersion()
            report?(t2, nil)
        }
    }

    private func sendFile(_ o: Out) async {
        let item = o.item
        let scoped = item.scoped && item.url.startAccessingSecurityScopedResource()
        defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            peer.send(["t": P.T.FILE_CANCEL, "id": o.id])
            dropped(id: o.id)
            return
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var seq = 0
        while true {
            if isCancelled(o) || !peer.isOpen { return }
            while peer.pendingBytes > 1024 * 1024 {
                if isCancelled(o) || !peer.isOpen { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let data: Data?
            do { data = try handle.read(upToCount: P.FILE_CHUNK_BYTES) } catch {
                peer.send(["t": P.T.FILE_CANCEL, "id": o.id])
                dropped(id: o.id)
                return
            }
            guard let chunk = data, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            peer.send(["t": P.T.FILE_CHUNK, "id": o.id, "seq": seq, "data": chunk.base64EncodedString()])
            seq += 1
            progress(o, chunk.count)
        }
        peer.send(["t": P.T.FILE_END, "id": o.id, "sha256": hex(hasher.finalize())])
        markDone(o)
    }
}

// MARK: - The feature

@MainActor
final class FilesFeature: ObservableObject, Feature {
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var recent: [String] = []
    @Published var notice = ""

    private let peer: Peer
    private let incoming: IncomingEngine
    private let outgoing: OutgoingEngine
    private var waiting: [(url: URL, scoped: Bool, cleanup: Bool)] = []
    private var hostName = "your computer"

    init(peer: Peer) {
        self.peer = peer
        self.incoming = IncomingEngine(peer: peer)
        self.outgoing = OutgoingEngine(peer: peer)
        let report: @Sendable (Transfer, String?) -> Void = { [weak self] t, line in
            Task { @MainActor in self?.apply(t, line) }
        }
        incoming.report = report
        outgoing.report = report
    }

    private func apply(_ t: Transfer, _ line: String?) {
        if let i = transfers.firstIndex(where: { $0.id == t.id }) {
            if t.version > transfers[i].version { transfers[i] = t }
        } else {
            transfers.insert(t, at: 0)
        }
        if transfers.count > 12 { transfers.removeLast(transfers.count - 12) }
        if let line {
            recent.insert(line, at: 0)
            if recent.count > 20 { recent.removeLast(recent.count - 20) }
        }
    }

    // MARK: Sending

    /// Files from the picker, the share sheet's "Open in", or a copy of ours. Sent now when
    /// connected, else when the session starts.
    func send(urls: [URL], scoped: Bool, cleanup: Bool = false) {
        guard peer.isOpen else {
            waiting.append(contentsOf: urls.map { (url: $0, scoped: scoped, cleanup: cleanup) })
            notice = "These go as soon as DuoDesk is connected to a computer."
            return
        }
        notice = ""
        var items: [OutgoingEngine.Item] = []
        for url in urls {
            let ok = scoped && url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true else { continue }
            items.append(OutgoingEngine.Item(url: url, name: IncomingEngine.cleanSegment(url.lastPathComponent),
                                             size: Int64(values.fileSize ?? 0), scoped: scoped, cleanup: cleanup))
        }
        if items.isEmpty { notice = "Nothing to send: folders aren’t supported yet."; return }
        outgoing.send(items)
    }

    // MARK: Feature

    func onWelcome(host: PairedHost) {
        hostName = host.name
        // Dragging across the edge isn't something this app can take.
        peer.send(["t": P.T.DRAG_POLICY, "accept": false])
        if !waiting.isEmpty {
            let w = waiting
            waiting = []
            for group in Dictionary(grouping: w, by: { "\($0.scoped)-\($0.cleanup)" }).values {
                send(urls: group.map { $0.url }, scoped: group[0].scoped, cleanup: group[0].cleanup)
            }
        }
    }

    func onClosed() {
        incoming.closeAll()
        outgoing.closeAll()
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case P.T.FILE_OFFER:
            guard let id = m["id"] as? String, !id.isEmpty else { return true }
            let size = int64(m["size"]) ?? -1
            incoming.offer(FileOffer(id: id, drop: (m["drop"] as? String) ?? "", size: size,
                                     batch: (m["batch"] as? String) ?? "",
                                     rel: (m["rel"] as? String) ?? ((m["name"] as? String) ?? ""),
                                     count: (m["count"] as? Int) ?? 1, bytes: int64(m["bytes"]) ?? size))
        case P.T.FILE_CHUNK:
            if let id = m["id"] as? String, let data = m["data"] as? String, let seq = m["seq"] as? Int {
                incoming.chunk(id: id, seq: seq, data: data)
            }
        case P.T.FILE_END:
            if let id = m["id"] as? String { incoming.end(id: id, sha256: (m["sha256"] as? String) ?? "") }
        case P.T.FILE_CANCEL:
            if let id = m["id"] as? String {
                incoming.cancel(id: id)
                outgoing.dropped(id: id)
            }
        case P.T.FILE_ACCEPT:
            if let id = m["id"] as? String { outgoing.accepted(id: id) }
        case P.T.FILE_REFUSE:
            if let id = m["id"] as? String { outgoing.dropped(id: id) }
            switch (m["why"] as? String) ?? "" {
            case "not_allowed":
                notice = "\(hostName) isn’t taking files. Turn on “Send files to \(hostName)” below, or allow it in DuoDesk there."
            case "too_big":
                notice = "That file is too big (4 GB at most)."
            default:
                notice = "\(hostName) refused the file."
            }
        case P.T.FILE_DONE:
            if (m["ok"] as? Bool) == false { notice = "A file didn’t arrive intact: \((m["error"] as? String) ?? "failed")." }
        case P.T.FILES_DONE:
            outgoing.batchDone(m)
        case P.T.DRAG_POLICY:
            break
        case P.T.DRAG_START:
            if let id = m["drag"] as? String { peer.send(["t": P.T.DRAG_END, "drag": id, "result": "failed"]) }
        case P.T.DRAG_CANCEL:
            break
        default:
            return false
        }
        return true
    }
}

// MARK: - Picker helper

/// A photo or video from the picker, copied to a file of ours (the picker's own is temporary).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DuoDeskOut/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedFile(url: copy)
        }
    }
}
