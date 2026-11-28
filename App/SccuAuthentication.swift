import Foundation

enum SccuAuthentication {
    static func request(ccuId: String, passKey: String, phoneID: String,
                        register: Bool, counter: UInt8) -> Data? {
        let ccu = Array(ccuId.utf8)
        let key = Array(passKey.utf8)
        let phone = Array(phoneID.utf8)
        let isHex: (UInt8) -> Bool = { (48...57).contains($0) || (65...70).contains($0) }
        guard ccu.count == 14, ccu.allSatisfy(isHex),
              key.count == 6, key.allSatisfy({ (48...57).contains($0) }),
              phone.count == 32, phone.allSatisfy(isHex) else { return nil }

        // One local record (7F00), followed by the UART message counter and checksum.
        var bytes: [UInt8] = [0xAA, 1, 0x7F, 0, 53]
        bytes += register ? ccu : Array(repeating: 0x30, count: 14)
        bytes += register ? key : Array(repeating: 0x30, count: 6)
        bytes += phone
        bytes.append(register ? 1 : 0)
        bytes.append(counter)
        bytes.append(0 &- bytes.reduce(0, &+))
        return Data(bytes)
    }

    struct ReplyParser {
        private var partial: [UInt8] = []
        private let prefix: [UInt8] = [0x5A, 1, 0x7F, 1, 1]

        // UART notifications can split a frame at any byte boundary.
        mutating func accept(_ data: Data) -> Bool? {
            partial += data
            let length = prefix.count + 3
            while partial.count >= length {
                if partial.starts(with: prefix), partial.prefix(length).reduce(0, &+) == 0 {
                    let accepted = partial[prefix.count] == 1
                    partial.removeFirst(length)
                    return accepted
                }
                partial.removeFirst()
            }
            return nil
        }
    }
}
