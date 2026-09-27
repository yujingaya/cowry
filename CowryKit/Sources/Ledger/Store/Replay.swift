import Foundation
internal import GRDB
import LedgerCore

/// Rebuilds the materialized tables from the op log (design.md §5.4).
enum Replay {
    /// Applies every main op in order to freshly created tables, checking each recorded state
    /// digest along the way. A mismatch means the log and this build disagree, so opening stops
    /// rather than showing a ledger that differs from the one that was recorded.
    static func run(_ db: Database) throws {
        var digest = StateDigest.zero
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT seq, body, resolution, state_digest FROM op WHERE status = 'main' ORDER BY seq
            """)
        while let row = try cursor.next() {
            let seq: Int64 = row[0]
            let op = try OpCodec.decode(row[1])
            // Phase 1 never records merge resolutions; applying them arrives with sync.
            guard (row[2] as Data?) == nil else { throw StoreError.corrupt("op \(seq) has a resolution this build can't apply") }
            var applier = Applier(db: db)
            try applier.apply(op.payload, of: op)
            digest += applier.digestDelta
            guard let recorded = StateDigest(bytes: row[3] as Data), recorded == digest else {
                throw StoreError.corrupt("replay diverged at op \(seq)")
            }
        }
    }
}
