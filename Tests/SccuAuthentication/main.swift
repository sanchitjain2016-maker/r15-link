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
