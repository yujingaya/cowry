import Foundation
internal import GRDB
import LedgerCore

public struct VerificationReport: Sendable {
    public enum Problem: Sendable, Equatable {
        /// `prev_hash` or `hash` of this op doesn't chain from its predecessor.
        case brokenChain(seq: Int64)
        /// Replaying up to this op produced a different state than the log recorded.
        case replayDiverged(seq: Int64, recorded: StateDigest, replayed: StateDigest)
        /// The op can't be decoded or applied.
        case unreadable(seq: Int64, reason: String)
        /// The live tables don't match the digest the log says they should have.
        case liveStateMismatch(recorded: StateDigest, actual: StateDigest)
    }

    public let opsChecked: Int
    public let problems: [Problem]
    public var isValid: Bool { problems.isEmpty }
}

extension Ledger {
    /// Replays the whole log into a scratch database, checking the hash chain and every recorded
    /// state digest, then recomputes the live tables' digest from scratch.
    public func verify() throws -> VerificationReport {
        let (ops, head, liveDigest) = try pool.read { db in
            (try OpLog.mainOps(db), try Meta.head(db), try Self.fullDigest(db))
        }

        var problems: [VerificationReport.Problem] = []
        let scratch = try DatabaseQueue()
        try scratch.write { db in
            try Schema.createMaterialized(db)
            try db.execute(sql: "CREATE TABLE op (id TEXT PRIMARY KEY, status TEXT, target TEXT, seq INTEGER, body BLOB)")
            var previousHash = ChainHash.genesis
            var digest = StateDigest.zero
            for stored in ops {
                let expectedHash = ChainHash.next(previous: previousHash, stateDigest: stored.stateDigest,
                                                  body: stored.body, resolution: stored.resolution)
                if stored.prevHash != previousHash || stored.hash != expectedHash {
                    problems.append(.brokenChain(seq: stored.seq))
                }
                previousHash = stored.hash
                do {
                    let op = try OpCodec.decode(stored.body)
                    var applier = Applier(db: db)
                    try applier.apply(op.payload, of: op)
                    try db.execute(sql: "INSERT INTO op (id, status, target, seq, body) VALUES (?, 'main', ?, ?, ?)",
                                   arguments: [op.id.string, op.payload.target, stored.seq, stored.body])
                    digest += applier.digestDelta
                } catch {
                    problems.append(.unreadable(seq: stored.seq, reason: String(describing: error)))
                }
                if digest != stored.stateDigest {
                    problems.append(.replayDiverged(seq: stored.seq, recorded: stored.stateDigest, replayed: digest))
                    digest = stored.stateDigest
                }
            }
        }
        if liveDigest != head.digest {
            problems.append(.liveStateMismatch(recorded: head.digest, actual: liveDigest))
        }
        return VerificationReport(opsChecked: ops.count, problems: problems)
    }

    /// The state digest computed from every record, ignoring the running digest.
    static func fullDigest(_ db: Database) throws -> StateDigest {
        var digest = StateDigest.zero
        for commodity in try db.allCommodities() { digest += RecordDigest.of(commodity) }
        for account in try db.allAccounts() { digest += RecordDigest.of(account) }
        let entryIDs = try String.fetchAll(db, sql: "SELECT id FROM entry").compactMap(Entry.ID.init)
        for entry in try db.entries(entryIDs) { digest += RecordDigest.of(entry) }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM price") { digest += RecordDigest.of(try Rows.price(row)) }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM balance_assertion") {
            digest += RecordDigest.of(try Rows.balanceAssertion(row))
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM setting") { digest += RecordDigest.of(try Rows.setting(row)) }
        for id in try String.fetchAll(db, sql: "SELECT op_id FROM conflict_dismissal").compactMap(Op.ID.init) {
            digest += RecordDigest.ofConflictDismissal(id)
        }
        return digest
    }
}
