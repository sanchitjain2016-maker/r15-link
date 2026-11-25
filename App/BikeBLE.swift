import Foundation
import CoreBluetooth

// Nordic UART Service (the bike's "motoconsdk" transport)
private let NUS = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let RX  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write (app -> bike)
private let TX  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify (bike -> app)

struct LogLine: Identifiable {
    let id = UUID()
    let t = Date()
    let kind: String   // tx / rx / ev / er
    let text: String
}

final class BikeBLE: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // Credentials (from the Yamaha cloud fetch). Editable in the UI.
    @Published var ccuId: String = "0008040003FC92"
    @Published var passKey: String = "447848"
    @Published var passEncoding: String = "ascii"   // ascii | hex | int4 | int3

    @Published var status: String = "idle"
    @Published var connected = false
    @Published var autoReconnect = true
    @Published var log: [LogLine] = []

    // Decoded telemetry (filled in as we learn the LocalId formats)
    @Published var lastOpcode: String = "-"
    @Published var rxCount: Int = 0

    private var central: CBCentralManager!
    private var bike: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "r15link.central"])
    }

    // MARK: logging
    func add(_ kind: String, _ text: String) {
        DispatchQueue.main.async {
            self.log.append(LogLine(kind: kind, text: text))
            if self.log.count > 600 { self.log.removeFirst(self.log.count - 600) }
        }
    }
    func clearLog() { DispatchQueue.main.async { self.log.removeAll() } }

    // MARK: control
    func start() {
        guard central.state == .poweredOn else { add("er", "Bluetooth not on"); return }
        status = "scanning"
        add("ev", "scanning for the bike…")
        central.scanForPeripherals(withServices: [NUS], options: nil)
    }
    func stop() {
        autoReconnect = false
        if let b = bike { central.cancelPeripheralConnection(b) }
        central.stopScan()
        status = "stopped"
    }

    // MARK: frame building
    private func hexToBytes(_ s: String) -> [UInt8] {
        let clean = s.filter { $0.isHexDigit }
        var out = [UInt8](); var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let b = UInt8(clean[i..<j], radix: 16) { out.append(b) }
            i = j
        }
        return out
    }
    private func passBytes() -> [UInt8] {
        switch passEncoding {
        case "hex":  return hexToBytes(passKey)
        case "int4": let n = UInt32(passKey) ?? 0; return [UInt8(n>>24 & 255),UInt8(n>>16 & 255),UInt8(n>>8 & 255),UInt8(n & 255)]
        case "int3": let n = UInt32(passKey) ?? 0; return [UInt8(n>>16 & 255),UInt8(n>>8 & 255),UInt8(n & 255)]
        default:     return Array(passKey.utf8)   // ascii
        }
    }
    func authFrame() -> Data {
        var f: [UInt8] = [0x01, 0x01]            // opcode 257 (AuthenticationV2Request), big-endian
        f += hexToBytes(ccuId)                    // 7 bytes
        f += passBytes()
        return Data(f)
    }
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

    func sendAuth() { write(authFrame(), label: "AUTH") }
    func sendRaw(_ s: String) { write(Data(hexToBytes(s)), label: "RAW") }

    private func write(_ data: Data, label: String) {
        guard let p = bike, let c = rxChar else { add("er", "not connected"); return }
        let mtu = p.maximumWriteValueLength(for: .withoutResponse)
        let type: CBCharacteristicWriteType =
            c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        add("tx", "\(label) (\(data.count)B): \(hex(data))")
        var i = 0
        while i < data.count {
            let end = min(i + max(1, mtu), data.count)
            p.writeValue(data.subdata(in: i..<end), for: c, type: type)
            i = end
        }
    }

    // MARK: CBCentralManagerDelegate
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            bike = p; p.delegate = self
            add("ev", "restored peripheral in background")
        }
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: add("ev", "bluetooth on"); if autoReconnect { start() }
        case .poweredOff: status = "bluetooth off"; connected = false
        default: status = "bt: \(c.state.rawValue)"
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String : Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        add("ev", "found \(name) rssi \(rssi)")
        central.stopScan()
        bike = p; p.delegate = self
        status = "connecting"
        central.connect(p, options: nil)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "discovering"; connected = true
        add("ev", "connected, discovering services")
        p.discoverServices([NUS])
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected = false; status = "disconnected"
        add("er", "disconnected\(error != nil ? ": \(error!.localizedDescription)" : "")")
        if autoReconnect { add("ev", "reconnecting…"); central.connect(p, options: nil) } // persists in background
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        add("er", "connect failed\(error != nil ? ": \(error!.localizedDescription)" : "")")
        if autoReconnect { central.connect(p, options: nil) }
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == NUS }) else { add("er", "NUS not found"); return }
        p.discoverCharacteristics([RX, TX], for: svc)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for ch in svc.characteristics ?? [] {
            if ch.uuid == RX { rxChar = ch }
            if ch.uuid == TX { txChar = ch; p.setNotifyValue(true, for: ch) }
        }
        status = "authenticating"
        add("ev", "characteristics ready — sending auth")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.write(self.authFrame(), label: "AUTH")
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == TX, let d = ch.value else { return }
        rxCount += 1
        if d.count >= 2 { lastOpcode = String(format: "0x%02X%02X", d[0], d[1]) }
        let ascii = String(d.map { ($0 >= 32 && $0 < 127) ? Character(UnicodeScalar($0)) : "." })
        add("rx", "(\(d.count)B) \(hex(d))  | \(ascii)")
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { add("er", "write error: \(e.localizedDescription)") }
    }
}
