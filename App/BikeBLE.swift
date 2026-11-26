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

struct Found: Identifiable {
    let id: UUID              // peripheral.identifier
    var name: String
    var rssi: Int
    let peripheral: CBPeripheral
}

final class BikeBLE: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var ccuId: String = "0008040003FC92"
    @Published var passKey: String = "447848"
    @Published var passEncoding: String = "ascii"   // ascii | hex | int4 | int3

    @Published var status: String = "idle"
    @Published var connected = false
    @Published var autoReconnect = true
    @Published var log: [LogLine] = []
    @Published var found: [Found] = []               // discovered devices (tap to connect)

    @Published var lastOpcode: String = "-"
    @Published var rxCount: Int = 0

    private var central: CBCentralManager!
    private var bike: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private var scanning = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "r15link.central"])
    }

    func add(_ kind: String, _ text: String) {
        DispatchQueue.main.async {
            self.log.append(LogLine(kind: kind, text: text))
            if self.log.count > 800 { self.log.removeFirst(self.log.count - 800) }
        }
    }
    func clearLog() { DispatchQueue.main.async { self.log.removeAll() } }

    // MARK: scanning — scan for EVERYTHING, match the bike by name
    func start() {
        guard central.state == .poweredOn else { add("er", "Bluetooth not on — enable it"); return }
        found.removeAll()
        scanning = true
        status = "scanning"
        add("ev", "scanning (all devices)…")
        central.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func stop() {
        autoReconnect = false
        scanning = false
        central.stopScan()
        if let b = bike { central.cancelPeripheralConnection(b) }
        status = "stopped"
    }
    func connectTo(_ p: CBPeripheral) {
        central.stopScan(); scanning = false
        bike = p; p.delegate = self
        status = "connecting"
        add("ev", "connecting to \(p.name ?? p.identifier.uuidString)…")
        central.connect(p, options: nil)
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
        default:     return Array(passKey.utf8)
        }
    }
    func authFrame() -> Data {
        var f: [UInt8] = [0x01, 0x01]
        f += hexToBytes(ccuId)
        f += passBytes()
        return Data(f)
    }
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

    func sendAuth() { write(authFrame(), label: "AUTH") }
    func sendRaw(_ s: String) { write(Data(hexToBytes(s)), label: "RAW") }

    private func write(_ data: Data, label: String) {
        guard let p = bike, let c = rxChar else { add("er", "not connected"); return }
        let mtu = max(1, p.maximumWriteValueLength(for: .withoutResponse))
        let type: CBCharacteristicWriteType =
            c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        add("tx", "\(label) (\(data.count)B): \(hex(data))")
        var i = 0
        while i < data.count {
            let end = min(i + mtu, data.count)
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
        case .unauthorized: status = "no BT permission"; add("er", "Bluetooth permission denied — allow it in Settings")
        default: status = "bt: \(c.state.rawValue)"
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String : Any], rssi: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? p.name ?? ""
        // update the discovered list (dedup by identifier)
        if let idx = found.firstIndex(where: { $0.id == p.identifier }) {
            found[idx].rssi = rssi.intValue
            if !name.isEmpty { found[idx].name = name }
        } else {
            found.append(Found(id: p.identifier,
                               name: name.isEmpty ? "(unnamed)" : name,
                               rssi: rssi.intValue, peripheral: p))
            add("ev", "found: \(name.isEmpty ? "(unnamed)" : name)  rssi \(rssi)")
        }
        // auto-connect to anything that looks like the bike
        let adv = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if name.uppercased().contains("YCCU") || adv.contains(NUS) {
            add("ev", "that's the bike — connecting")
            connectTo(p)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "discovering"; connected = true
        add("ev", "connected, discovering services")
        p.discoverServices([NUS])
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected = false; status = "disconnected"
        add("er", "disconnected\(error != nil ? ": \(error!.localizedDescription)" : "")")
        if autoReconnect { add("ev", "reconnecting…"); central.connect(p, options: nil) }
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        add("er", "connect failed\(error != nil ? ": \(error!.localizedDescription)" : "")")
        if autoReconnect { central.connect(p, options: nil) }
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { add("er", "service discovery: \(e.localizedDescription)"); return }
        guard let svc = p.services?.first(where: { $0.uuid == NUS }) else {
            add("er", "NUS service not found on this device")
            if let all = p.services { add("ev", "services: " + all.map{$0.uuid.uuidString}.joined(separator: ", ")) }
            return
        }
        p.discoverCharacteristics([RX, TX], for: svc)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for ch in svc.characteristics ?? [] {
            if ch.uuid == RX { rxChar = ch }
            if ch.uuid == TX { txChar = ch; p.setNotifyValue(true, for: ch) }
        }
        status = "authenticating"
        add("ev", "characteristics ready — sending auth")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
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
        if status != "connected" { status = "connected" }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { add("er", "write error: \(e.localizedDescription)") }
    }
}
