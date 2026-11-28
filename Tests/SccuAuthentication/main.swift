import Foundation

let bike = "1234ABCDEF5678"
let passKey = "012345"
let phone = "0123456789ABCDEF0123456789ABCDEF"
let registration = SccuAuthentication.request(ccuId: bike, passKey: passKey, phoneID: phone, register: true, counter: 7)
let reconnect = SccuAuthentication.request(ccuId: bike, passKey: passKey, phoneID: phone, register: false, counter: 7)

func hex(_ data: Data?) -> String? {
    data?.map { String(format: "%02x", $0) }.joined()
}

precondition(hex(registration) == "aa017f0035313233344142434445463536373830313233343530313233343536373839414243444546303132333435363738394142434445460107ed")
precondition(hex(reconnect) == "aa017f003530303030303030303030303030303030303030303031323334353637383941424344454630313233343536373839414243444546000796")
precondition(SccuAuthentication.request(ccuId: bike, passKey: "000O00", phoneID: phone, register: true, counter: 0) == nil)

let accepted: [UInt8] = [0x5A, 1, 0x7F, 1, 1, 1, 4, 0x1F]
let rejected: [UInt8] = [0x5A, 1, 0x7F, 1, 1, 0, 4, 0x20]
for split in 1..<accepted.count {
    var parser = SccuAuthentication.ReplyParser()
    precondition(parser.accept(Data([7, 8]) + Data(accepted.prefix(split))) == nil)
    precondition(parser.accept(Data(accepted.dropFirst(split))) == true)
}
var parser = SccuAuthentication.ReplyParser()
precondition(parser.accept(Data(accepted.dropLast()) + Data([0])) == nil)
precondition(parser.accept(Data(rejected)) == false)
precondition(parser.accept(Data(accepted)) == true)
print("SCCU registration, reconnect, and reply validation checks passed.")

func uartFrame(_ records: [UInt8]) -> Data {
    var bytes: [UInt8] = [0x6B] + records + [7]
    bytes.append(0 &- bytes.reduce(0, &+))
    return Data(bytes)
}
var measurements = [UInt8](repeating: 0, count: 20)
measurements[0] = 0x0B
measurements[1] = 0xB8
measurements[2] = 42
measurements[6] = 184
measurements[8] = 64
measurements[14] = 108
measurements[19] = 131
let rideFrame = uartFrame([2, 0, 1, 20] + measurements + [0, 0x48, 4, 0, 0, 0x30, 0x39])
for split in 1..<rideFrame.count {
    var stream = RideTelemetryStream()
    var data = RideTelemetry()
    precondition(!stream.ingest(Data(rideFrame.prefix(split)), into: &data))
    precondition(data.speed == nil)
    precondition(stream.ingest(Data(rideFrame.dropFirst(split)), into: &data))
    precondition(data.speed == 42 && data.rpm == 3_000 && data.gear == 3)
    precondition(data.coolant == 78 && data.throttle == 25 && data.odometer == 1_234.5)
    precondition(abs((data.battery ?? 0) - 13.4765625) < 0.00001)
}
var stream = RideTelemetryStream()
var reading = RideTelemetry()
var invalidRideFrame = rideFrame
invalidRideFrame[invalidRideFrame.count - 1] ^= 1
precondition(!stream.ingest(invalidRideFrame, into: &reading))
precondition(reading.speed == nil)
print("Ride telemetry, fragmentation, checksum, and unit checks passed.")
