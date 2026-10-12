import Foundation

extension UUID {
    /// A version 7 UUID (RFC 9562): 48 bits of milliseconds since 1970, then the version
    /// and variant bits, then random bits. Sortable by creation time, as the server's
    /// `uuidv7()` ids are; Foundation's `UUID()` makes version 4.
    static func v7(now: Date = Date()) -> UUID {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8((millis >> (8 * UInt64(5 - index))) & 0xFF)
        }
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9],
                bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    /// The version nibble of this UUID (4 for Foundation's, 7 for `v7()`).
    var version: Int {
        Int(uuid.6 >> 4)
    }
}
