// BLECentral.swift — the phone acts as a BLE central and connects outbound to a PC that
// advertises P.BLE.SERVICE. GATT layout (shared/blepipe.js):
//   INFO  (read)         : the host's beacon JSON
//   CTRL  (write + ind.) : {op:'hello'|'open'|'close'|'want'|'invite'|'closed'} JSON
//   UP    (write-no-rsp) : guest -> host bytes (the WSS session upstream)
//   DOWN  (notify)       : host -> guest bytes (the WSS session downstream)
//
// Writing / notifying UP/DOWN carries a transparent byte stream that we hand to Link.swift
// over a local 127.0.0.1 loopback (so Link.swift doesn't need to care which transport is
// under it). Phase 1 wires discovery and the INFO read only; the full byte-pipe comes with
// Phase 2's foldershare + files work.
//
// Needs NSBluetoothAlwaysUsageDescription and UIBackgroundModes = bluetooth-central.

import Foundation
import CoreBluetooth

struct BLEHost: Identifiable, Equatable {
    let id: String       // CBPeripheral.identifier.uuidString (not stable across sessions)
    var name: String
    var os: String
    var port: UInt16
    var fp: String
    var rssi: Int
    var seenAt: Date
}

@MainActor
final class BLECentral: NSObject, ObservableObject {
    @Published private(set) var authorized: Bool = false
    @Published private(set) var scanning: Bool = false
    @Published private(set) var hosts: [BLEHost] = []

    private var central: CBCentralManager!
    private let serviceUUID = CBUUID(string: P.BLE.SERVICE)
    private let infoUUID    = CBUUID(string: P.BLE.INFO)
    private var peripherals: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        // Deferred init: queue the manager on construction but don't start scanning until
        // state becomes .poweredOn (-didUpdateState).
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: NSNumber(value: true),
        ])
    }

    func startScan() {
        guard central.state == .poweredOn, !scanning else { return }
        scanning = true
        central.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: NSNumber(value: false),
        ])
    }

    func stopScan() {
        guard scanning else { return }
        scanning = false
        central.stopScan()
    }
}

extension BLECentral: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.authorized = (central.state == .poweredOn)
            if central.state == .poweredOn {
                self.startScan()
            } else {
                self.scanning = false
                self.hosts.removeAll()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        Task { @MainActor in
            self.peripherals[id] = peripheral
            peripheral.delegate = self
            self.central.connect(peripheral, options: nil)
            // Advertisement payload is opaque until we read INFO; just show the local name for now.
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? peripheral.name ?? "DuoDesk"
            let draft = BLEHost(
                id: id.uuidString, name: name, os: "unknown", port: P.PORT,
                fp: "", rssi: RSSI.intValue, seenAt: Date()
            )
            if let i = self.hosts.firstIndex(where: { $0.id == draft.id }) {
                self.hosts[i] = draft
            } else {
                self.hosts.append(draft)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.discoverServices([self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.hosts.removeAll { $0.id == peripheral.identifier.uuidString }
            self.peripherals.removeValue(forKey: peripheral.identifier)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.peripherals.removeValue(forKey: peripheral.identifier)
        }
    }
}

extension BLECentral: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString.lowercased() == P.BLE.SERVICE }) else { return }
        peripheral.discoverCharacteristics([
            CBUUID(string: P.BLE.INFO),
            CBUUID(string: P.BLE.CTRL),
            CBUUID(string: P.BLE.UP),
            CBUUID(string: P.BLE.DOWN),
        ], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        guard let info = service.characteristics?.first(where: { $0.uuid.uuidString.lowercased() == P.BLE.INFO }) else { return }
        peripheral.readValue(for: info)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid.uuidString.lowercased() == P.BLE.INFO,
              let data = characteristic.value,
              let any = try? JSONSerialization.jsonObject(with: data),
              let msg = any as? [String: Any] else { return }
        let name = (msg["name"] as? String) ?? "DuoDesk"
        let os   = (msg["os"] as? String) ?? "unknown"
        let port = UInt16((msg["port"] as? Int) ?? Int(P.PORT))
        let fp   = P.normFingerprint((msg["fp"] as? String) ?? "")
        let id   = peripheral.identifier.uuidString
        Task { @MainActor in
            guard let i = self.hosts.firstIndex(where: { $0.id == id }) else { return }
            self.hosts[i].name = name
            self.hosts[i].os = os
            self.hosts[i].port = port
            self.hosts[i].fp = fp
        }
    }
}
