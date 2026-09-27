import Foundation
internal import GRDB
import LedgerCore

/// A read-only view of the ledger fixed at one point in time. Every method is synchronous and
/// cheap enough to call from a table view's data source on the main thread: reads run on a WAL
/// snapshot and never wait for writes.
///
/// Holding a snapshot pins that version of the database and delays WAL checkpoints, so drop old
/// snapshots once a newer one arrives.
public struct LedgerSnapshot: Sendable {
    let reader: any DatabaseReader
    /// Sequence number of the last op visible in this snapshot.
    public let head: Int64

    init(reader: any DatabaseReader, head: Int64) {
        self.reader = reader
        self.head = head
    }

    public func accounts() throws -> AccountTree {
        try reader.read { AccountTree(try $0.allAccounts()) }
    }

    public func commodities() throws -> [Commodity] {
        try reader.read { try $0.allCommodities() }
    }

    public func commodity(_ id: Commodity.ID) throws -> Commodity? {
        try reader.read { try $0.commodity(id) }
    }

    public func setting(_ key: SettingKey) throws -> String? {
        try reader.read { try $0.setting(key)?.value }
    }

    public func primaryCommodity() throws -> Commodity.ID? {
        try setting(.primaryCommodity).flatMap(Commodity.ID.init)
    }

    public func entry(_ id: Entry.ID) throws -> Entry? {
        try reader.read { try $0.entry(id) }
    }

    /// Entries in the order of `ids`. IDs not in this snapshot are skipped.
    public func entries(_ ids: [Entry.ID]) throws -> [Entry] {
        try reader.read { try $0.entries(ids) }
    }

    public func journal(_ filter: JournalFilter = .all) throws -> JournalIndex {
        try reader.read { db in
            let (clause, arguments) = Self.whereClause(filter)
            let keys = try Row.fetchAll(db, sql: """
                SELECT e.id, e.date, e.created_at FROM entry e WHERE \(clause)
                ORDER BY e.date, e.created_at, e.id
                """, arguments: arguments).map(Self.key)
            return JournalIndex(keys: keys)
        }
    }

    /// Keys of those `ids` that exist in this snapshot and match `filter`. After a change event,
    /// this is all a list needs to move, insert or remove the changed rows.
    public func journalKeys(of ids: some Collection<Entry.ID>, matching filter: JournalFilter) throws -> [JournalKey] {
        guard !ids.isEmpty else { return [] }
        return try reader.read { db in
            var result: [JournalKey] = []
            for chunk in Array(ids).chunked(into: 500) {
                var (clause, arguments) = Self.whereClause(filter)
                clause += " AND e.id IN (\(databaseQuestionMarks(count: chunk.count)))"
                arguments += StatementArguments(chunk.map(\.string))
                result += try Row.fetchAll(db, sql: "SELECT e.id, e.date, e.created_at FROM entry e WHERE \(clause)",
                                           arguments: arguments).map(Self.key)
            }
            return result.sorted()
        }
    }

    /// Every entry that posts to any of `accounts`, with running balances.
    public func register(of accounts: Set<Account.ID>) throws -> Register {
        guard !accounts.isEmpty else { return Register(accounts: accounts, rows: []) }
        return try reader.read { db in
            let marks = databaseQuestionMarks(count: accounts.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id, e.date, e.created_at, p.commodity_id, SUM(p.amount) AS amount
                FROM posting p JOIN entry e ON e.id = p.entry_id
                WHERE p.resolved_account_id IN (\(marks))
                GROUP BY e.id, p.commodity_id
                ORDER BY e.date, e.created_at, e.id
                """, arguments: StatementArguments(accounts.map(\.string)))

            var result: [RegisterRow] = []
            var balance: Holdings = [:]
            var current: (key: JournalKey, amounts: Holdings)?
            func finish() {
                guard let row = current else { return }
                for (commodity, amount) in row.amounts { balance[commodity, default: 0] += amount }
                result.append(RegisterRow(key: row.key, amounts: row.amounts, balance: balance))
            }
            for row in rows {
                let key = try Self.key(row)
                if current?.key != key {
                    finish()
                    current = (key, [:])
                }
                let amount: Int64 = row["amount"]
                if amount != 0 { current!.amounts[try row.id("commodity_id")] = amount }
            }
            finish()
            return Register(accounts: accounts, rows: result)
        }
    }

    /// Balance of every account (after merges), optionally as of the end of `date`.
    public func balances(asOf date: LocalDate? = nil) throws -> [Account.ID: Holdings] {
        try reader.read { db in
            var result: [Account.ID: Holdings] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT resolved_account_id, commodity_id, SUM(amount) AS amount FROM posting
                WHERE ?1 IS NULL OR date <= ?1
                GROUP BY resolved_account_id, commodity_id
                """, arguments: [date?.description]) {
                let amount: Int64 = row["amount"]
                guard amount != 0 else { continue }
                result[try row.id("resolved_account_id"), default: [:]][try row.id("commodity_id")] = amount
            }
            return result
        }
    }

    /// Every op that changed `target`, oldest first: the record's edit history.
    public func history(of target: some CustomStringConvertible) throws -> [Op] {
        try reader.read { try OpLog.history($0, target: target.description).map(\.op) }
    }

    // MARK: Helpers

    private static func key(_ row: Row) throws -> JournalKey {
        JournalKey(date: try row.date("date"), createdAt: try row.hlc("created_at"), id: try row.id("id"))
    }

    private static func whereClause(_ filter: JournalFilter) -> (String, StatementArguments) {
        var clauses = ["1"]
        var arguments = StatementArguments()
        if let dates = filter.dates {
            clauses.append("e.date BETWEEN ? AND ?")
            arguments += [dates.lowerBound.description, dates.upperBound.description]
        }
        if let text = Text.normalize(filter.text) {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            clauses.append(#"(e.payee LIKE ? ESCAPE '\' OR e.memo LIKE ? ESCAPE '\')"#)
            arguments += ["%\(escaped)%", "%\(escaped)%"]
        }
        if let accounts = filter.accounts {
            clauses.append("""
                EXISTS (SELECT 1 FROM posting p WHERE p.entry_id = e.id
                        AND p.resolved_account_id IN (\(databaseQuestionMarks(count: max(accounts.count, 1)))))
                """)
            arguments += StatementArguments(accounts.isEmpty ? [""] : accounts.map(\.string))
        }
        return (clauses.joined(separator: " AND "), arguments)
    }
}
