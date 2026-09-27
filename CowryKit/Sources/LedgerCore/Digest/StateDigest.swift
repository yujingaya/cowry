import CryptoKit
import Foundation

/// A digest of the whole ledger state: the sum, modulo 2²⁵⁶, of one SHA-256 per record.
///
/// Two devices that replay the same log must reach the same digest; a mismatch means replay
/// diverged (a bug, or builds interpreting an op differently). Because it's a sum, applying an op
/// only needs to subtract the old digests of the records it touched and add the new ones.
///
/// A sum of hashes is not collision-resistant against a deliberate attacker. It doesn't need to
/// be: tampering is caught by the hash chain; this catches accidents.
public struct StateDigest: Hashable, Sendable {
    /// Big-endian 64-bit limbs, most significant first.
    private var limbs: (UInt64, UInt64, UInt64, UInt64)

    public static let zero = StateDigest(limbs: (0, 0, 0, 0))

    private init(limbs: (UInt64, UInt64, UInt64, UInt64)) {
        self.limbs = limbs
    }

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 32 else { return nil }
        let array = Array(bytes)
        func limb(_ index: Int) -> UInt64 {
            array[index * 8 ..< index * 8 + 8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        limbs = (limb(0), limb(1), limb(2), limb(3))
    }

    public init(hash: SHA256.Digest) {
        self.init(bytes: Array(hash))!
    }

    public var bytes: [UInt8] {
        [limbs.0, limbs.1, limbs.2, limbs.3].flatMap { limb in
            (0..<8).reversed().map { UInt8(truncatingIfNeeded: limb >> ($0 * 8)) }
        }
    }

    public var hex: String {
        bytes.map { String($0, radix: 16).leftPadded(to: 2) }.joined()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.limbs == rhs.limbs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(limbs.0)
        hasher.combine(limbs.1)
        hasher.combine(limbs.2)
        hasher.combine(limbs.3)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        let (d, c0) = lhs.limbs.3.addingReportingOverflow(rhs.limbs.3)
        let (c1a, o1a) = lhs.limbs.2.addingReportingOverflow(rhs.limbs.2)
        let (c, o1b) = c1a.addingReportingOverflow(c0 ? 1 : 0)
        let (b1a, o2a) = lhs.limbs.1.addingReportingOverflow(rhs.limbs.1)
        let (b, o2b) = b1a.addingReportingOverflow(o1a || o1b ? 1 : 0)
        let a = lhs.limbs.0 &+ rhs.limbs.0 &+ (o2a || o2b ? 1 : 0)
        return Self(limbs: (a, b, c, d))
    }

    public static prefix func - (value: Self) -> Self {
        // Two's complement: invert and add one.
        let inverted = Self(limbs: (~value.limbs.0, ~value.limbs.1, ~value.limbs.2, ~value.limbs.3))
        return inverted + Self(limbs: (0, 0, 0, 1))
    }

    public static func - (lhs: Self, rhs: Self) -> Self {
        lhs + -rhs
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    public static func -= (lhs: inout Self, rhs: Self) {
        lhs = lhs - rhs
    }
}

extension StateDigest: CustomStringConvertible {
    public var description: String { hex }
}

extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}
