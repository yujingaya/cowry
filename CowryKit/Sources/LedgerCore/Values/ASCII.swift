/// Allocation-free parsing of the fixed-width ASCII forms the ledger stores (dates, HLC readings,
/// UUIDs). Reading 100,000 journal keys parses 300,000 of these, so it matters.
enum ASCII {
    /// Runs `body` over the string's UTF-8 bytes without copying when possible.
    static func withBytes<S: StringProtocol, R>(_ string: S, _ body: (UnsafeBufferPointer<UInt8>) -> R?) -> R? {
        if let result = string.utf8.withContiguousStorageIfAvailable(body) { return result }
        return Array(string.utf8).withUnsafeBufferPointer(body)
    }

    static func digits(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int64? {
        var value: Int64 = 0
        for index in range {
            let digit = bytes[index] &- 48
            guard digit < 10 else { return nil }
            value = value * 10 + Int64(digit)
        }
        return value
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 97...102: byte - 87
        case 65...70: byte - 55
        default: nil
        }
    }
}
