import CryptoKit
import Foundation

/// The byte encoding digests are computed over (design doc §7.2). Every variable-length field is
/// length-prefixed so field boundaries are unambiguous. This encoding is frozen: changing any byte
/// it produces changes every digest ever recorded. Test vectors pin it.
package struct DigestWriter {
    package private(set) var bytes: [UInt8] = []

    package init(tag: String) {
        string(tag)
    }

    package mutating func uuid<Tag>(_ id: Identifier<Tag>) {
        bytes += id.bytes
    }

    package mutating func date(_ date: LocalDate) {
        bytes += Array(date.description.utf8)
    }

    package mutating func int64(_ value: Int64) {
        withUnsafeBytes(of: value.bigEndian) { bytes += $0 }
    }

    package mutating func int(_ value: Int) {
        int64(Int64(value))
    }

    package mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    package mutating func string(_ value: String) {
        blob(Array(value.precomposedStringWithCanonicalMapping.utf8))
    }

    package mutating func blob(_ value: some Collection<UInt8>) {
        withUnsafeBytes(of: UInt32(value.count).bigEndian) { bytes += $0 }
        bytes += value
    }

    package mutating func optional<T>(_ value: T?, _ write: (inout Self, T) -> Void) {
        if let value {
            bytes.append(1)
            write(&self, value)
        } else {
            bytes.append(0)
        }
    }

    package func sha256() -> SHA256.Digest {
        SHA256.hash(data: bytes)
    }

    package func digest() -> StateDigest {
        StateDigest(hash: sha256())
    }
}
