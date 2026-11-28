import Foundation
import CoreBluetooth
import Combine

// Nordic UART used by Yamaha SCCU.
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

    @Published var status: String = "idle"
    @Published var connected = false
    @Published var autoReconnect = true {
        didSet {
            if !autoReconnect {
                retry?.cancel()
                if waitingForBike {
                    clearLink()
                    status = "automatic reconnect off"
                } else if let failure = lastFailure, bike == nil, !central.isScanning {
                    status = failure
                }
            }
        }
    }
    @Published var log: [LogLine] = []
    @Published var found: [Found] = []               // discovered devices (tap to connect)

    @Published var lastOpcode: String = "-"
    @Published var rxCount: Int = 0

    private var central: CBCentralManager!
    private var bike: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private var deadline: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var attempts = 0
    private var allowAutomaticSelection = false
    private var waitingForAuth = false
    private var registeringPhone = false
    private var authCounter: UInt8 = 0
    private var replyParser = SccuAuthentication.ReplyParser()
    private var pendingWrite = Data()
    private var writeInFlight = false
    private var retryRegistrationAfterWrite = false
    private var waitingForBike = false
    private var linkReadyAt: Date?
    private var linkOpenedAt: Date?
    private var wantsConnection = false
    private var lastFailure: String?
    private let savedBikeKey = "r15link.knownBike"
    private let phoneIDKey = "r15link.sccu.phoneID"
    private var normalizedCCU: String {
        ccuId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    private var registrationKey: String { "r15link.sccu.registered." + normalizedCCU }
    private var savedBikeID: UUID? {
        UserDefaults.standard.string(forKey: savedBikeKey).flatMap(UUID.init(uuidString:))
    }
    private var expectedName: String {
        "YCCU_" + normalizedCCU
    }

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

    var diagnosticLog: String {
        let clock = ISO8601DateFormatter()
        return log.map { line in
            let detail = ["tx", "rx"].contains(line.kind)
                ? "[packet contents omitted]"
                : line.text
            return "\(clock.string(from: line.t)) \(line.kind.uppercased()) \(detail)"
        }.joined(separator: "\n")
    }

    func start() {
        guard central.state == .poweredOn else {
            status = bluetoothStatus(central.state)
            add("er", status)
            return
        }
        if waitingForBike {
            add("ev", "reconnect already pending for the saved bike")
            return
        }
        guard bike == nil, !central.isScanning else { return }
        retry?.cancel()
        wantsConnection = true
        attempts = 0
        lastFailure = nil
        beginScan(automatic: true)
    }

    private func beginScan(automatic: Bool) {
        allowAutomaticSelection = automatic
        status = "scanning"
        found.removeAll()
        add("ev", "scanning (all devices)…")
        central.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        setDeadline(seconds: 15) { manager in
            manager.central.stopScan()
            let sawBike = manager.found.contains {
                $0.id == manager.savedBikeID || $0.name.uppercased() == manager.expectedName
            }
            if (!sawBike || !automatic), manager.autoReconnect, manager.wantsConnection,
               manager.waitForSavedBike() {
                return
            }
            if let failure = manager.lastFailure {
                manager.status = "connection failed — tap to retry"
                manager.add("er", "last failure: \(failure)")
            } else {
                manager.status = manager.found.isEmpty ? "no Bluetooth devices found" : "bike not found — select it or retry"
                manager.add("er", "\(manager.status) (\(manager.found.count) devices)")
            }
        }
    }

    func stop() {
        wantsConnection = false
        retry?.cancel()
        deadline?.cancel()
        central.stopScan()
        clearLink()
        status = "stopped"
    }

    func connectTo(_ p: CBPeripheral) {
        guard central.state == .poweredOn, bike == nil else { return }
        wantsConnection = true
        lastFailure = nil
        attempts = 0
        beginConnection(p)
    }

    private func waitForSavedBike() -> Bool {
        guard let id = savedBikeID,
              let saved = central.retrievePeripherals(withIdentifiers: [id]).first else { return false }
        waitForBike(saved)
        return true
    }

    private func waitForBike(_ p: CBPeripheral) {
        retry?.cancel()
        deadline?.cancel()
        central.stopScan()
        bike = p
        p.delegate = self
        waitingForBike = true
        status = "waiting for bike ignition"
        add("ev", "iOS reconnect pending for the saved bike")
        switch p.state {
        case .connected:
            discover(p)
        case .connecting:
            break
        default:
            central.connect(p, options: nil)
        }
    }

    private func beginConnection(_ p: CBPeripheral) {
        retry?.cancel()
        central.stopScan()
        attempts += 1
        bike = p
        p.delegate = self
        status = "connecting"
        add("ev", "connecting to \(p.name ?? p.identifier.uuidString) (attempt \(attempts) of 3)")
        if p.state == .connected {
            discover(p)
        } else {
            central.connect(p, options: nil)
            setDeadline(seconds: 12) { $0.fail("Bluetooth connection timed out") }
        }
    }

    private func discover(_ p: CBPeripheral) {
        waitingForBike = false
        linkOpenedAt = Date()
        if p.name?.uppercased() == expectedName {
            UserDefaults.standard.set(p.identifier.uuidString, forKey: savedBikeKey)
        }
        status = "discovering services"
        add("ev", "Bluetooth connected, discovering the bike service")
        p.discoverServices([NUS])
        setDeadline(seconds: 10) { $0.fail("service discovery timed out", retryable: false) }
    }

    private func setDeadline(seconds: Double, action: @escaping (BikeBLE) -> Void) {
        deadline?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            action(self)
        }
        deadline = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    private func clearLink() {
        let current = bike
        bike = nil
        rxChar = nil
        txChar = nil
        waitingForAuth = false
        waitingForBike = false
        replyParser = SccuAuthentication.ReplyParser()
        pendingWrite.removeAll()
        writeInFlight = false
        retryRegistrationAfterWrite = false
        linkReadyAt = nil
        linkOpenedAt = nil
        connected = false
        if let current = current, current.state != .disconnected {
            central.cancelPeripheralConnection(current)
        }
    }

    private func fail(_ reason: String, retryable: Bool = true) {
        guard bike != nil else { return }
        deadline?.cancel()
        clearLink()
        lastFailure = reason
        status = reason
        add("er", reason)
        guard retryable, autoReconnect, wantsConnection, central.state == .poweredOn else { return }
        let delay = attempts >= 3 ? 4 : Double(max(1, attempts) * 2)
        status = attempts >= 3 ? "retry limit reached — checking nearby devices" : "retrying in \(Int(delay))s"
        add("ev", status)
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.autoReconnect, self.wantsConnection,
                  self.central.state == .poweredOn, self.bike == nil else { return }
            self.beginScan(automatic: self.attempts < 3)
        }
        retry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func bluetoothStatus(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "Bluetooth ready"
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied — allow it in Settings"
        case .unsupported: return "Bluetooth LE unavailable"
        case .resetting: return "Bluetooth is restarting"
        default: return "Bluetooth is starting"
        }
    }

    private func connectionError(_ error: Error?) -> String {
        guard let failure = error as NSError? else { return "" }
        return ": \(failure.localizedDescription) [\(failure.domain) \(failure.code)]"
    }

    private func pairingWasRemoved(_ error: Error?) -> Bool {
        guard let failure = error as NSError? else { return false }
        return failure.domain == CBErrorDomain && failure.code == CBError.Code.peerRemovedPairingInformation.rawValue
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
    func sendAuth() {
        guard !waitingForAuth, !connected else { return }
        beginAuthentication(register: !UserDefaults.standard.bool(forKey: registrationKey))
    }

    private func beginAuthentication(register: Bool) {
        let defaults = UserDefaults.standard
        let phoneID = defaults.string(forKey: phoneIDKey)
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        defaults.set(phoneID, forKey: phoneIDKey)
        let key = passKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let frame = SccuAuthentication.request(ccuId: normalizedCCU, passKey: key,
                                                     phoneID: phoneID, register: register,
                                                     counter: authCounter) else {
            status = "check bike ID and six-digit passkey"
            add("er", status)
            return
        }
        guard let p = bike, let c = rxChar, linkReadyAt != nil, p.state == .connected,
              pendingWrite.isEmpty, !writeInFlight else {
            add("er", "bike Bluetooth write is not ready")
            return
        }
        authCounter &+= 1
        registeringPhone = register
        waitingForAuth = true
        replyParser = SccuAuthentication.ReplyParser()
        status = register ? "registering phone with Yamaha SCCU" : "resuming Yamaha SCCU session"
        add("ev", status)
        pendingWrite = frame
        setDeadline(seconds: 8) { manager in
            let reason = manager.pendingWrite.isEmpty && !manager.writeInFlight
                ? "no Yamaha SCCU authentication reply"
                : "Yamaha SCCU Bluetooth write timed out"
            manager.finishAuthentication(accepted: false, reason: reason)
        }
        sendNextChunk(to: p, on: c)
    }

    private func finishAuthentication(accepted: Bool, reason: String) {
        deadline?.cancel()
        waitingForAuth = false
        pendingWrite.removeAll()
        connected = accepted
        status = reason
        add(accepted ? "ev" : "er", reason)
        if accepted {
            UserDefaults.standard.set(true, forKey: registrationKey)
        }
    }

    func sendRaw(_ s: String) {
        guard let p = bike, let c = rxChar, connected, !waitingForAuth,
              pendingWrite.isEmpty, !writeInFlight else { return }
        pendingWrite = Data(hexToBytes(s))
        sendNextChunk(to: p, on: c)
    }

    private func sendNextChunk(to p: CBPeripheral, on c: CBCharacteristic) {
        let type: CBCharacteristicWriteType =
            c.properties.contains(.write) ? .withResponse : .withoutResponse
        let mtu = max(1, min(p.maximumWriteValueLength(for: type),
                             p.maximumWriteValueLength(for: .withoutResponse)))
        while !pendingWrite.isEmpty, !writeInFlight,
              type == .withResponse || p.canSendWriteWithoutResponse {
            let count = min(mtu, pendingWrite.count)
            let chunk = Data(pendingWrite.prefix(count))
            pendingWrite.removeFirst(count)
            writeInFlight = type == .withResponse
            p.writeValue(chunk, for: c, type: type)
            add("tx", "Yamaha UART write (\(count) bytes)")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        guard bike === p, let c = rxChar else { return }
        sendNextChunk(to: p, on: c)
    }

    // MARK: CBCentralManagerDelegate
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = ps.first(where: { $0.identifier == savedBikeID }) {
            bike = p; p.delegate = self
            wantsConnection = true
            add("ev", "restored known bike")
        }
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        status = bluetoothStatus(c.state)
        add(c.state == .poweredOn ? "ev" : "er", status)
        if c.state == .poweredOn {
            if let restored = bike {
                waitForBike(restored)
            } else if autoReconnect {
                wantsConnection = true
                if !waitForSavedBike() { start() }
            }
        } else if c.state != .unknown {
            retry?.cancel()
            deadline?.cancel()
            clearLink()
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String : Any], rssi: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? p.name ?? ""
        guard c.isScanning, bike == nil else { return }
        // update the discovered list (dedup by identifier)
        if let idx = found.firstIndex(where: { $0.id == p.identifier }) {
            found[idx].rssi = rssi.intValue
            if !name.isEmpty { found[idx].name = name }
        } else {
            found.append(Found(id: p.identifier,
                               name: name.isEmpty ? "(unnamed)" : name,
                               rssi: rssi.intValue, peripheral: p))
            if name.uppercased() == expectedName || p.identifier == savedBikeID {
                add("ev", "found bike: \(name.isEmpty ? "(unnamed)" : name) — RSSI \(rssi)")
            }
        }
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        if allowAutomaticSelection, isConnectable,
           name.uppercased() == expectedName || p.identifier == savedBikeID {
            if name.uppercased() == expectedName {
                UserDefaults.standard.set(p.identifier.uuidString, forKey: savedBikeKey)
            }
            beginConnection(p)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard bike === p, waitingForBike || status == "connecting" else { return }
        discover(p)
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard bike === p else { return }
        if pairingWasRemoved(error) {
            fail("bike removed the saved Bluetooth pairing" + connectionError(error), retryable: false)
            return
        }
        let duration = linkOpenedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        let reason = "Bluetooth disconnected" + (duration.map { " after \($0) ms" } ?? "") + connectionError(error)
        let transportWasReady = linkReadyAt != nil
        if transportWasReady, error == nil || (duration ?? 0) >= 15_000,
           autoReconnect, wantsConnection, central.state == .poweredOn, p.identifier == savedBikeID {
            add("er", reason)
            clearLink()
            attempts = 0
            lastFailure = nil
            waitForBike(p)
            return
        }
        if attempts == 0 { attempts = 1 }
        fail(reason)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard bike === p else { return }
        if pairingWasRemoved(error) {
            fail("bike removed the saved Bluetooth pairing" + connectionError(error), retryable: false)
            return
        }
        if attempts == 0 { attempts = 1 }
        fail("Bluetooth connection failed" + connectionError(error))
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard bike === p else { return }
        if let e = error { fail("service discovery: \(e.localizedDescription)", retryable: false); return }
        guard let svc = p.services?.first(where: { $0.uuid == NUS }) else {
            if let all = p.services { add("ev", "services: " + all.map{$0.uuid.uuidString}.joined(separator: ", ")) }
            fail("bike Bluetooth service missing", retryable: false)
            return
        }
        status = "discovering bike characteristics"
        add("ev", status)
        p.discoverCharacteristics([RX, TX], for: svc)
        setDeadline(seconds: 10) { $0.fail("characteristic discovery timed out", retryable: false) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        guard bike === p, svc.uuid == NUS else { return }
        if let error = error {
            fail("characteristic discovery: \(error.localizedDescription)", retryable: false)
            return
        }
        guard let write = svc.characteristics?.first(where: { $0.uuid == RX }),
              write.properties.contains(.write) || write.properties.contains(.writeWithoutResponse),
              let notify = svc.characteristics?.first(where: { $0.uuid == TX }),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            fail("bike write or notification characteristic missing", retryable: false)
            return
        }
        rxChar = write
        txChar = notify
        status = "enabling bike notifications"
        add("ev", status)
        p.setNotifyValue(true, for: notify)
        setDeadline(seconds: 10) { $0.fail("bike notification subscription timed out", retryable: false) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard bike === p, txChar === ch else { return }
        guard error == nil, ch.isNotifying else {
            fail("bike notification subscription failed" + (error.map { ": \($0.localizedDescription)" } ?? ""), retryable: false)
            return
        }
        guard linkReadyAt == nil else { return }
        deadline?.cancel()
        linkReadyAt = Date()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedBikeKey)
        status = "Bluetooth ready — authenticating"
        add("ev", "bike notifications enabled")
        sendAuth()
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard bike === p, txChar === ch else { return }
        if let error = error { add("er", "bike notification: \(error.localizedDescription)"); return }
        guard let d = ch.value, !d.isEmpty else { return }
        rxCount += 1
        if d.count >= 2 { lastOpcode = String(format: "0x%02X%02X", d[0], d[1]) }
        let hex = d.map { String(format: "%02x", $0) }.joined(separator: " ")
        add("rx", "(\(d.count)B) \(hex)")
        if waitingForAuth, let accepted = replyParser.accept(d) {
            let retryRegistration = !accepted && !registeringPhone
            finishAuthentication(accepted: accepted,
                                 reason: accepted ? "Yamaha SCCU authenticated" : "Yamaha SCCU rejected authentication")
            if retryRegistration {
                UserDefaults.standard.removeObject(forKey: registrationKey)
                if writeInFlight { retryRegistrationAfterWrite = true }
                else { beginAuthentication(register: true) }
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard bike === p, rxChar === ch, writeInFlight else { return }
        writeInFlight = false
        let retryRegistration = retryRegistrationAfterWrite
        retryRegistrationAfterWrite = false
        if let error = error {
            pendingWrite.removeAll()
            let reason = "Yamaha UART write failed" + connectionError(error)
            if waitingForAuth { finishAuthentication(accepted: false, reason: reason) }
            else { add("er", reason) }
            return
        }
        if retryRegistration {
            beginAuthentication(register: true)
            return
        }
        if waitingForAuth, pendingWrite.isEmpty {
            add("ev", "iOS acknowledged all authentication writes")
        }
        sendNextChunk(to: p, on: ch)
    }
}
