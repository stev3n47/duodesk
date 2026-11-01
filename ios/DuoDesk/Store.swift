// Store.swift — persistent state.
// Identity + paired-host list in UserDefaults; the per-host reconnect token lives in Keychain
// because it is the one secret we hold.

import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

struct PairedHost: Codable, Identifiable, Equatable, Hashable {
    var id: String                 // peer's protocol id (opaque)
    var name: String
    var os: String                 // mac | win | linux | android | ios
    var address: String            // last known IP or hostname
    var port: UInt16               // usually P.PORT
    var fp: String                 // normalized sha256 fingerprint of the host's TLS cert
    var pairedAt: Date
    var lastSeen: Date?

    var osLabel: String {
        switch os {
        case "mac": return "Mac"
        case "win": return "Windows PC"
        case "linux": return "Linux"
        case "android": return "Android"
        case "ios": return "iPhone"
        default: return os.capitalized
        }
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let selfId = "duodesk.self.id"
        static let selfName = "duodesk.self.name"
        static let pairedHosts = "duodesk.paired.hosts.v1"
        static let discoveryEnabled = "duodesk.discovery.enabled"
    }
    private let keychainService = "com.twindesk.ios.tokens"

    @Published private(set) var selfId: String
    @Published var selfName: String
    @Published private(set) var hosts: [PairedHost] = []

    private init() {
        // Stable per-install opaque id. Not derivable from device data; just a random hex string.
        if let existing = UserDefaults.standard.string(forKey: Key.selfId), !existing.isEmpty {
            selfId = existing
        } else {
            let fresh = P.randomHex(16)
            UserDefaults.standard.set(fresh, forKey: Key.selfId)
            selfId = fresh
        }
        selfName = UserDefaults.standard.string(forKey: Key.selfName) ?? Store.defaultDeviceName()
        hosts = Store.loadHosts(from: UserDefaults.standard)
    }

    static func defaultDeviceName() -> String {
#if os(iOS)
        return UIDevice.current.name
#else
        return "iPhone"
#endif
    }

    // MARK: - Paired-host list

    func save(host: PairedHost, token: String) {
        var next = hosts.filter { $0.id != host.id }
        next.append(host)
        next.sort { $0.pairedAt > $1.pairedAt }
        hosts = next
        persistHosts()
        setKeychain(key: host.id, value: token)
    }

    func token(for hostId: String) -> String? {
        getKeychain(key: hostId)
    }

    func forget(hostId: String) {
        hosts.removeAll { $0.id == hostId }
        persistHosts()
        deleteKeychain(key: hostId)
    }

    func update(hostId: String, address: String? = nil, port: UInt16? = nil, lastSeen: Date? = nil) {
        guard let idx = hosts.firstIndex(where: { $0.id == hostId }) else { return }
        if let address { hosts[idx].address = address }
        if let port { hosts[idx].port = port }
        if let lastSeen { hosts[idx].lastSeen = lastSeen }
        persistHosts()
    }

    private func persistHosts() {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: Key.pairedHosts)
        }
    }

    private static func loadHosts(from defaults: UserDefaults) -> [PairedHost] {
        guard let data = defaults.data(forKey: Key.pairedHosts),
              let hosts = try? JSONDecoder().decode([PairedHost].self, from: data)
        else { return [] }
        return hosts
    }

    func setSelfName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selfName else { return }
        selfName = trimmed
        defaults.set(trimmed, forKey: Key.selfName)
    }

    // MARK: - Keychain

    private func setKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private func getKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func deleteKeychain(key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
