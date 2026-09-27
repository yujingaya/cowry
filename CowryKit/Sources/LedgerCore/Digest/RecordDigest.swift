import CryptoKit
import Foundation

/// Per-record digests that sum to the state digest. Tags separate record kinds and carry the
/// format version; a new format gets a new tag and never replaces an old one.
package enum RecordDigest {
    package static func of(_ c: Commodity) -> StateDigest {
        var w = DigestWriter(tag: "cowry.commodity.v1")
        w.uuid(c.id)
        w.string(c.code)
        w.string(c.kind.rawValue)
        w.int(c.scale)
        w.optional(c.name) { $0.string($1) }
        w.optional(c.quote) { $0.uuid($1) }
        w.optional(c.feed) { $0.string($1) }
        w.bool(c.archived)
        w.uuid(c.rev)
        return w.digest()
    }

    package static func of(_ a: Account) -> StateDigest {
        var w = DigestWriter(tag: "cowry.account.v1")
        w.uuid(a.id)
        w.optional(a.parent) { $0.uuid($1) }
        w.string(a.name)
        w.string(a.type.rawValue)
        w.optional(a.role) { $0.string($1.rawValue) }
        w.date(a.openedOn)
        w.optional(a.closedOn) { $0.date($1) }
        w.bool(a.archived)
        w.bool(a.deleted)
        w.optional(a.mergedInto) { $0.uuid($1) }
        w.int(a.sortOrder)
        w.optional(a.note) { $0.string($1) }
        w.uuid(a.rev)
        return w.digest()
    }

    package static func of(_ e: Entry) -> StateDigest {
        var w = DigestWriter(tag: "cowry.entry.v1")
        w.uuid(e.id)
        w.date(e.date)
        w.string(e.createdAt.description)
        w.optional(e.payee) { $0.string($1) }
        w.optional(e.memo) { $0.string($1) }
        w.uuid(e.rev)
        w.int(e.postings.count)
        for posting in e.postings {
            w.uuid(posting.account)
            w.uuid(posting.commodity)
            w.int64(posting.amount)
        }
        return w.digest()
    }

    package static func of(_ p: Price) -> StateDigest {
        var w = DigestWriter(tag: "cowry.price.v1")
        w.uuid(p.id)
        w.uuid(p.base)
        w.uuid(p.quote)
        w.date(p.date)
        w.string(p.rate.string)
        w.uuid(p.rev)
        return w.digest()
    }

    package static func of(_ b: BalanceAssertion) -> StateDigest {
        var w = DigestWriter(tag: "cowry.balance_assertion.v1")
        w.uuid(b.id)
        w.uuid(b.account)
        w.uuid(b.commodity)
        w.date(b.date)
        w.int64(b.amount)
        w.uuid(b.rev)
        return w.digest()
    }

    package static func of(_ s: Setting) -> StateDigest {
        var w = DigestWriter(tag: "cowry.setting.v1")
        w.string(s.key.rawValue)
        w.string(s.value)
        w.uuid(s.rev)
        return w.digest()
    }

    package static func ofConflictDismissal(_ op: Op.ID) -> StateDigest {
        var w = DigestWriter(tag: "cowry.conflict_dismissal.v1")
        w.uuid(op)
        return w.digest()
    }
}

/// The main log's hash chain (design doc §7.2).
public enum ChainHash {
    public static let genesis = Data(repeating: 0, count: 32)

    /// `SHA-256(previous ‖ stateDigest ‖ enc(body) ‖ enc(resolution?))`
    public static func next(previous: Data, stateDigest: StateDigest, body: Data, resolution: Data?) -> Data {
        var w = DigestWriter()
        w.blob(body)
        w.optional(resolution) { $0.blob($1) }
        var bytes = [UInt8](previous)
        bytes += stateDigest.bytes
        bytes += w.bytes
        return Data(SHA256.hash(data: bytes))
    }
}

extension DigestWriter {
    /// A writer with no tag, for composing framed fields.
    package init() {}
}
