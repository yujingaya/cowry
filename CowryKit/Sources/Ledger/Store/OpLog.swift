import Foundation
internal import GRDB
import LedgerCore

/// Head of the main log: the last applied op's sequence number and chain hash, and the state
/// digest after it.
struct LogHead: Sendable, Equatable {
    var seq: Int64
    var hash: Data
    var digest: StateDigest

    static let genesis = LogHead(seq: 0, hash: ChainHash.genesis, digest: .zero)
}

/// Device-local values kept in the `meta` table.
enum Meta {
    static func head(_ db: Database) throws -> LogHead {
        guard let seq = try Int64.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'head_seq'") else {
            return .genesis
        }
        let hash = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'head_hash'") ?? ChainHash.genesis
        let digestBytes = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'state_digest'") ?? Data()
        guard let digest = StateDigest(bytes: digestBytes) else { throw StoreError.corrupt("state_digest") }
        return LogHead(seq: seq, hash: hash, digest: digest)
    }

    static func setHead(_ db: Database, _ head: LogHead) throws {
        try set(db, "head_seq", head.seq)
        try set(db, "head_hash", head.hash)
        try set(db, "state_digest", Data(head.digest.bytes))
    }

    static func clock(_ db: Database) throws -> HybridLogicalClock {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'hlc'") else {
            return HybridLogicalClock()
        }
        guard let last = HLCTimestamp(text) else { throw StoreError.corrupt("hlc = \(text)") }
        return HybridLogicalClock(last: last)
    }

    static func setClock(_ db: Database, _ clock: HybridLogicalClock) throws {
        try set(db, "hlc", clock.last.description)
    }

    private static func set(_ db: Database, _ key: String, _ value: some DatabaseValueConvertible) throws {
        try db.execute(sql: """
            INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
    }
}

/// An op as stored in the log.
struct StoredOp: Sendable {
    let seq: Int64
    let body: Data
    let resolution: Data?
    let prevHash: Data
    let stateDigest: StateDigest
    let hash: Data
}

enum OpLog {
    static func appendMain(
        _ db: Database, op: Op, body: Data, resolution: Data?, seq: Int64, prevHash: Data,
        stateDigest: StateDigest, hash: Data
    ) throws {
        try db.execute(sql: """
            INSERT INTO op (id, status, seq, body, resolution, kind, target, version, prev_hash, state_digest, hash)
            VALUES (?, 'main', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [op.id.string, seq, body, resolution, op.kind.rawValue, op.payload.target, op.version,
                             prevHash, Data(stateDigest.bytes), hash])
    }

    /// Main ops in log order.
    static func mainOps(_ db: Database) throws -> [StoredOp] {
        try Row.fetchAll(db, sql: """
            SELECT seq, body, resolution, prev_hash, state_digest, hash FROM op WHERE status = 'main' ORDER BY seq
            """).map { row in
            let digestBytes: Data = row["state_digest"]
            guard let digest = StateDigest(bytes: digestBytes) else { throw StoreError.corrupt("op state_digest") }
            return StoredOp(seq: row["seq"], body: row["body"], resolution: row["resolution"],
                            prevHash: row["prev_hash"], stateDigest: digest, hash: row["hash"])
        }
    }

    /// Decoded ops that changed `target`, in log order.
    static func history(_ db: Database, target: String) throws -> [(seq: Int64, op: Op)] {
        try Row.fetchAll(db, sql: """
            SELECT seq, body FROM op WHERE target = ? AND status = 'main' ORDER BY seq
            """, arguments: [target]).map { row in
            (row["seq"], try OpCodec.decode(row["body"]))
        }
    }
}
