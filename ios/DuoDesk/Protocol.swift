// Protocol.swift — port of ../shared/protocol.js (v1).
// Byte-for-byte compatible with the Android app and all three desktops.
// Keep this file in sync when shared/protocol.js changes.

import CryptoKit
import Foundation

enum P {
    static let PROTOCOL_VERSION = 1

    static let PORT: UInt16 = 47800            // WSS control channel
    static let DISCOVERY_PORT: UInt16 = 47801  // UDP beacons / probes / invites

    static let BEACON_MS: Int = 2000
    static let PROBE_MS: Int = 10000
    static let PROBE_REPLY_MS: Int = 1500
    static let DEVICE_STALE_MS: Int = 10000
    static let PHONE_GRACE_MS: Int = 30000
    static let PING_MS: Int = 1000
    static let TIMEOUT_MS: Int = 4000
    static let PAIR_TIMEOUT_MS: Int = 60000
    static let UNAUTH_TIMEOUT_MS: Int = 70000
    static let RECONNECT_MS: [Int] = [1000, 2000, 3000]
    static let MAX_PAYLOAD: Int = 16 * 1024 * 1024
    static let CLIP_MAX_BYTES: Int = 256 * 1024
    static let CLIP_IMAGE_MAX_BYTES: Int = 10 * 1024 * 1024
    static let CLIP_IMAGE_PART_BYTES: Int = 256 * 1024
    static let FILE_CHUNK_BYTES: Int = 64 * 1024

    static let SAS_LABEL = "macshare-sas-v1"

    enum OS {
        static let mac = "mac"
        static let win = "win"
        static let linux = "linux"
        static let android = "android"
        static let ios = "ios"  // what this companion identifies as
    }

    enum T {
        static let BEACON = "beacon"
        static let PROBE = "probe"
        static let INVITE = "invite"

        static let PAIR_START = "pair.start"
        static let PAIR_NONCE = "pair.nonce"
        static let PAIR_REVEAL = "pair.reveal"
        static let PAIR_CONFIRM = "pair.confirm"
        static let PAIR_OK = "pair.ok"
        static let PAIR_CANCEL = "pair.cancel"

        static let HELLO = "hello"
        static let WELCOME = "welcome"
        static let ERROR = "error"
        static let PING = "ping"
        static let PONG = "pong"
        static let BYE = "bye"

        static let CLIP = "clip"
        static let CLIP_REQUEST = "clip.request"
        static let CLIP_POLICY = "clip.policy"
        static let CLIP_IMAGE = "clip.image"
        static let CLIP_IMAGE_PART = "clip.image.part"
        static let CLIP_LATEST = "clip.latest"

        static let FILE_OFFER = "file.offer"
        static let FILE_ACCEPT = "file.accept"
        static let FILE_REFUSE = "file.refuse"
        static let FILE_CHUNK = "file.chunk"
        static let FILE_END = "file.end"
        static let FILE_DONE = "file.done"
        static let FILE_CANCEL = "file.cancel"
        static let FILE_PULL = "file.pull"
        static let FILES_DONE = "files.done"
        static let DRAG_START = "drag.start"
        static let DRAG_CANCEL = "drag.cancel"
        static let DRAG_END = "drag.end"
        static let DRAG_POLICY = "drag.policy"

        // The computer's screen on this device (mac/stream.js; android Web.kt).
        static let SCREEN_POLICY = "screen.policy"
        static let SCREEN_CTL = "screen.ctl"
        static let SCREEN_STATE = "screen.state"
        static let STREAM_INFO = "stream.info"
        static let STREAM_STOP = "stream.stop"
        static let STREAM_INPUT = "stream.input"
        static let RTC_OFFER = "rtc.offer"
        static let RTC_ANSWER = "rtc.answer"
        static let RTC_ICE = "rtc.ice"

        static let NOTIF = "notif"
        static let NOTIF_POLICY = "notif.policy"

        // Remote (phone-as-touchpad / keyboard / gamepad). See mac/phone-bridge.js.
        static let REMOTE_HELLO = "remote.hello"
        static let REMOTE_STATE = "remote.state"
        static let REMOTE_MM = "remote.mm"
        static let REMOTE_MD = "remote.md"
        static let REMOTE_MU = "remote.mu"
        static let REMOTE_WH = "remote.wh"
        static let REMOTE_KD = "remote.kd"
        static let REMOTE_KU = "remote.ku"
        static let REMOTE_TEXT = "remote.text"
        static let REMOTE_PAD = "remote.pad"
        static let REMOTE_RELEASE = "remote.release"

        static let WOL_INFO = "wol.info"
        static let PAIR_SYNC = "pair.sync"
    }

    enum E {
        static let VERSION_MISMATCH = "version_mismatch"
        static let BAD_TOKEN = "bad_token"
        static let PAIR_REFUSED = "pair_refused"
        static let PAIR_TIMEOUT = "pair_timeout"
        static let BUSY = "busy"
        static let REPLACED = "replaced"
        static let RELEASED = "released"
        static let ASLEEP = "asleep"
        static let BAD_MESSAGE = "bad_message"
    }

    enum Button {
        static let LEFT = 0
        static let RIGHT = 1
        static let MIDDLE = 2
        static let BACK = 3
        static let FORWARD = 4
    }

    enum BLE {
        // Service UUIDs — must match shared/protocol.js verbatim.
        static let SERVICE = "b7f30001-2c4e-4d1a-9a57-3e8c2f6d0a91"
        static let INFO    = "b7f30002-2c4e-4d1a-9a57-3e8c2f6d0a91"
        static let CTRL    = "b7f30003-2c4e-4d1a-9a57-3e8c2f6d0a91"
        static let UP      = "b7f30004-2c4e-4d1a-9a57-3e8c2f6d0a91"
        static let DOWN    = "b7f30005-2c4e-4d1a-9a57-3e8c2f6d0a91"
        static let PHONE_SERVICE = "b7f30006-2c4e-4d1a-9a57-3e8c2f6d0a91"
    }

    // "AB:CD:..." -> "abcd...". Matches shared/protocol.js normFingerprint.
    static func normFingerprint(_ fp: String) -> String {
        fp.replacingOccurrences(of: ":", with: "").lowercased()
    }

    // sha256(hex-decode input) -> hex string. Matches sha256Hex over the decoded bytes.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func commitOf(_ nonceHex: String) -> String {
        sha256Hex(Data(hex: nonceHex))
    }

    // 6-digit SAS. Matches shared/protocol.js sasCode:
    // sha256(SAS_LABEL || fp bytes || nw bytes || nm bytes), first 4 bytes as BE uint32, mod 1e6.
    static func sasCode(fp: String, nwHex: String, nmHex: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(SAS_LABEL.utf8))
        hasher.update(data: Data(hex: normFingerprint(fp)))
        hasher.update(data: Data(hex: nwHex))
        hasher.update(data: Data(hex: nmHex))
        let digest = hasher.finalize()
        let bytes = Array(digest)
        let n = (UInt32(bytes[0]) << 24)
              | (UInt32(bytes[1]) << 16)
              | (UInt32(bytes[2]) << 8)
              |  UInt32(bytes[3])
        return String(format: "%06d", n % 1_000_000)
    }

    // Constant-time check of a token against a stored sha256 hex hash.
    static func tokenMatches(_ token: String, hashHex: String) -> Bool {
        let a = Data(hex: sha256Hex(Data(token.utf8)))
        let b = Data(hex: hashHex)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // Random hex string of `n` bytes (n*2 hex chars). Uses the system CSPRNG.
    static func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Hex helpers

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) {
                bytes.append(b)
            }
            idx = next
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
