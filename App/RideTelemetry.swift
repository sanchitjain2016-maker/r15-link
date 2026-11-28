import Foundation

struct RideTelemetry: Equatable {
    var speed: Int?
    var rpm: Int?
    var odometer: Double?
    var coolant: Int?
    var battery: Double?
    var gear: Int?
    var throttle: Double?

    mutating func apply(identifier: UInt16, payload: ArraySlice<UInt8>) {
        let bytes = Array(payload)
        switch identifier {
        case 0x0001:
            if bytes.count >= 3 {
                let engineSpeed = Int(bytes[0]) << 8 | Int(bytes[1])
                rpm = engineSpeed <= 20_000 ? engineSpeed : nil
                speed = bytes[2] == 255 ? nil : Int(bytes[2])
            }
            if bytes.count > 6 {
                battery = bytes[6] == 255 ? nil : Double(bytes[6]) * 18.75 / 256
            }
            if bytes.count > 8 {
                throttle = bytes[8] == 255 ? nil : Double(bytes[8]) * 100 / 256
            }
            if bytes.count > 14 {
                coolant = bytes[14] == 255 ? nil : Int(bytes[14]) - 30
            }
            if bytes.count > 19 {
                let position = Int(bytes[19]) - 128
                gear = (0...6).contains(position) ? position : nil
            }
        case 0x0048:
            if let raw = mileageCounter(bytes) { odometer = raw / 10 }
        case 0xF702:
            if odometer == nil, let raw = mileageCounter(bytes) { odometer = raw / 100 }
        default:
            break
        }
    }

    private func mileageCounter(_ bytes: [UInt8]) -> Double? {
        guard bytes.count == 4 else { return nil }
        let raw = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return raw == .max ? nil : Double(raw)
    }
}

struct RideTelemetryStream {
    private static let messageTypes: Set<UInt8> = [0x55, 0x5A, 0x6A, 0x6B]
    private var pending: [UInt8] = []

    mutating func ingest(_ data: Data, into telemetry: inout RideTelemetry) -> Bool {
        pending += data
        var sampledSpeed = false
        while pending.count >= 2 {
            guard Self.messageTypes.contains(pending[0]), (1...32).contains(pending[1]) else {
                pending.removeFirst()
                continue
            }

            let count = Int(pending[1])
            var records: [(id: UInt16, start: Int, end: Int)] = []
            var offset = 2
            for _ in 0..<count {
                guard pending.count >= offset + 3 else { break }
                let length = Int(pending[offset + 2])
                let end = offset + 3 + length
                guard pending.count >= end else { break }
                let id = UInt16(pending[offset]) << 8 | UInt16(pending[offset + 1])
                records.append((id, offset + 3, end))
                offset = end
            }
            guard records.count == count, pending.count >= offset + 2 else {
                if pending.count > 1_024 {
                    pending.removeFirst()
                    continue
                }
                return sampledSpeed
            }
            let end = offset + 2
            guard pending.prefix(end).reduce(0, &+) == 0 else {
                pending.removeFirst()
                continue
            }
            for record in records {
                telemetry.apply(identifier: record.id, payload: pending[record.start..<record.end])
                if record.id == 0x0001, record.end - record.start >= 3 {
                    sampledSpeed = true
                }
            }
            pending.removeFirst(end)
        }
        return sampledSpeed
    }
}

struct RideSummary: Codable, Identifiable {
    var id = UUID()
    let started: Date
    let duration: TimeInterval
    let distance: Double?
    let averageSpeed: Double?
    let peakSpeed: Int?
}

struct ActiveRide {
    let started = Date()
    private var firstOdometer: Double?
    private var lastOdometer: Double?
    private var lastSample: Date?
    private var speedSum = 0
    private var samples = 0
    private var peakSpeed: Int?

    mutating func update(_ telemetry: RideTelemetry, sampledSpeed: Bool, at now: Date = Date()) {
        if let odometer = telemetry.odometer {
            if firstOdometer == nil { firstOdometer = odometer }
            lastOdometer = odometer
        }
        guard sampledSpeed, let speed = telemetry.speed,
              lastSample.map({ now.timeIntervalSince($0) >= 1 }) ?? true else { return }
        lastSample = now
        speedSum += speed
        samples += 1
        peakSpeed = max(peakSpeed ?? speed, speed)
    }

    func summary(at now: Date = Date()) -> RideSummary? {
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 30, samples > 0 || lastOdometer != nil else { return nil }
        let distance = firstOdometer.flatMap { first in lastOdometer.map { max(0, $0 - first) } }
        return RideSummary(started: started, duration: elapsed, distance: distance,
                           averageSpeed: samples > 0 ? Double(speedSum) / Double(samples) : nil, peakSpeed: peakSpeed)
    }
}
