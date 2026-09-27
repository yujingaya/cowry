import CryptoKit
import Foundation

/// A UUID tagged with the kind of thing it identifies, so an `Account.ID` can't be passed where an
/// `Entry.ID` is expected. Encoded as a lowercase UUID string.
public struct Identifier<Tag>: Hashable, Comparable, Sendable {
    public let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    public init?(_ string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    /// A new time-ordered (v7) identifier.
    public static func generate(at date: Date = Date()) -> Self {
        Self(UUID.v7(at: date))
    }

    /// A deterministic (v5) identifier. Devices that derive the same name get the same ID, so
    /// creating e.g. the KRW commodity on two devices doesn't produce two commodities.
    public static func named(_ name: String) -> Self {
        Self(UUID.v5(namespace: UUID.cowryNamespace, name: name))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    /// Canonical text form used in the database and in op bodies.
    public var string: String { uuid.uuidString.lowercased() }

    /// The 16 raw bytes, used in digests.
    public var bytes: [UInt8] { uuid.bytes }
}

extension Identifier: CustomStringConvertible {
    public var description: String { string }
}

extension Identifier: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = Self(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid UUID: \(string)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

/// Tag for device identifiers.
public enum Device {}
public typealias DeviceID = Identifier<Device>

// MARK: - UUID versions

extension UUID {
    /// Fixed namespace for Cowry's deterministic identifiers. Never change it.
    static let cowryNamespace = UUID(uuidString: "6f1c9a52-3d0e-4b8a-9f57-2c64e1d3a8b0")!

    var bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }

    init(bytes: [UInt8]) {
        precondition(bytes.count == 16)
        var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: bytes) }
        self.init(uuid: raw)
    }

    /// RFC 9562 version 7: 48-bit Unix milliseconds followed by random bits.
    static func v7(at date: Date) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in 6..<16 { bytes[index] = generator.next() }
        let millis = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - index)))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(bytes: bytes)
    }

    /// RFC 9562 version 5: SHA-1 of namespace and name.
    static func v5(namespace: UUID, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        hasher.update(data: namespace.bytes)
        hasher.update(data: Array(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(bytes: bytes)
    }
}
