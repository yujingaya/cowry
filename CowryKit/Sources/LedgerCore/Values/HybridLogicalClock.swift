import Foundation

/// A hybrid logical clock reading: physical milliseconds plus a counter. Once a device has seen
/// another device's op, everything it writes afterwards reads later, even if its wall clock is
/// behind. Used to decide "the later edit" in merge policies — never to order the main log.
public struct HLCTimestamp: Hashable, Comparable, Sendable {
    public let millis: Int64
    public let counter: UInt16

    public init(millis: Int64, counter: UInt16) {
        self.millis = millis
        self.counter = counter
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.millis, lhs.counter) < (rhs.millis, rhs.counter)
    }

    public static let zero = HLCTimestamp(millis: 0, counter: 0)
}

extension HLCTimestamp: CustomStringConvertible, LosslessStringConvertible {
    /// Fixed width (`13 digits-4 digits`) so text order equals time order.
    public var description: String {
        let m = String(millis), c = String(counter)
        return String(repeating: "0", count: max(0, 13 - m.count)) + m + "-"
            + String(repeating: "0", count: max(0, 4 - c.count)) + c
    }

    public init?(_ description: String) {
        let parts: (Int64, UInt16)? = ASCII.withBytes(description) { bytes in
            guard bytes.count == 18, bytes[13] == UInt8(ascii: "-"),
                  let millis = ASCII.digits(bytes, 0..<13),
                  let counter = ASCII.digits(bytes, 14..<18)
            else { return nil }
            return (millis, UInt16(counter))
        }
        guard let (millis, counter) = parts else { return nil }
        self.init(millis: millis, counter: counter)
    }
}

extension HLCTimestamp: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = HLCTimestamp(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid HLC: \(text)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct HybridLogicalClock: Sendable {
    public private(set) var last: HLCTimestamp

    public init(last: HLCTimestamp = .zero) {
        self.last = last
    }

    /// A reading strictly later than every reading issued or observed so far.
    public mutating func now(physicalMillis: Int64) -> HLCTimestamp {
        if physicalMillis > last.millis {
            last = HLCTimestamp(millis: physicalMillis, counter: 0)
        } else if last.counter < 9999 {
            last = HLCTimestamp(millis: last.millis, counter: last.counter + 1)
        } else {
            last = HLCTimestamp(millis: last.millis + 1, counter: 0)
        }
        return last
    }

    public mutating func now(at date: Date = Date()) -> HLCTimestamp {
        now(physicalMillis: Int64(date.timeIntervalSince1970 * 1000))
    }

    /// Records a reading from another device so later local readings sort after it.
    public mutating func observe(_ remote: HLCTimestamp) {
        last = max(last, remote)
    }
}
