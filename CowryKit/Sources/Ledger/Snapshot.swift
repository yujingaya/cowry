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
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT e.id, e.date, e.created_at FROM entry e WHERE \(clause)
                ORDER BY e.date, e.created_at, e.id
                """, arguments: arguments)
            var keys: [JournalKey] = []
            while let row = try cursor.next() { keys.append(try Self.key(row)) }
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
            // Postings come off the covering index already in journal order; consecutive rows of
            // one entry are summed here rather than with GROUP BY, which would force a sort.
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT entry_id, date, created_at, commodity_id, amount FROM posting
                WHERE resolved_account_id IN (\(databaseQuestionMarks(count: accounts.count)))
                ORDER BY date, created_at, entry_id
                """, arguments: StatementArguments(accounts.map(\.string)))

            var result: [RegisterRow] = []
            var balance: Holdings = [:]
            var commodities: [String: Commodity.ID] = [:]
            var currentID: String?
            var current: (key: JournalKey, amounts: Holdings)?
            func finish() {
                guard let row = current else { return }
                let amounts = row.amounts.filter { $0.value != 0 }
                for (commodity, amount) in amounts { balance[commodity, default: 0] += amount }
                result.append(RegisterRow(key: row.key, amounts: amounts, balance: balance.filter { $0.value != 0 }))
            }
            while let row = try cursor.next() {
                let entryID: String = row[0]
                if entryID != currentID {
                    finish()
                    currentID = entryID
                    current = (try Self.key(id: entryID, date: row[1], createdAt: row[2]), [:])
                }
                let commodityText: String = row[3]
                let commodity: Commodity.ID
                if let known = commodities[commodityText] {
                    commodity = known
                } else {
                    guard let parsed = Commodity.ID(commodityText) else { throw StoreError.corrupt("commodity_id") }
                    commodities[commodityText] = parsed
                    commodity = parsed
                }
                let amount: Int64 = row[4]
                current!.amounts[commodity, default: 0] += amount
            }
            finish()
            return Register(accounts: accounts, rows: result)
        }
    }

    /// Balance of every account (after merges), optionally as of the end of `date`.
    public func balances(asOf date: LocalDate? = nil) throws -> [Account.ID: Holdings] {
        try reader.read { db in
            // Current balances are maintained by triggers; past ones are summed.
            let rows = if let date {
                try Row.fetchAll(db, sql: """
                    SELECT resolved_account_id, commodity_id, SUM(amount) FROM posting WHERE date <= ?
                    GROUP BY resolved_account_id, commodity_id
                    """, arguments: [date.description])
            } else {
                try Row.fetchAll(db, sql: "SELECT account_id, commodity_id, amount FROM balance WHERE amount != 0")
            }
            var result: [Account.ID: Holdings] = [:]
            for row in rows {
                let amount: Int64 = row[2]
                guard amount != 0 else { continue }
                guard let account = Account.ID(row[0] as String), let commodity = Commodity.ID(row[1] as String)
                else { throw StoreError.corrupt("balance") }
                result[account, default: [:]][commodity] = amount
            }
            return result
        }
    }

    /// Net amount posted to every account (after merges) between two dates, inclusive: what a
    /// category spent or earned over a period.
    public func activity(in dates: ClosedRange<LocalDate>) throws -> [Account.ID: Holdings] {
        try reader.read { db in
            var result: [Account.ID: Holdings] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT resolved_account_id, commodity_id, SUM(amount) AS amount FROM posting
                WHERE date BETWEEN ? AND ?
                GROUP BY resolved_account_id, commodity_id
                """, arguments: [dates.lowerBound.description, dates.upperBound.description]) {
                let amount: Int64 = row["amount"]
                guard amount != 0 else { continue }
                result[try row.id("resolved_account_id"), default: [:]][try row.id("commodity_id")] = amount
            }
            return result
        }
    }

    /// The most recent entry for each payee containing `text`, payees starting with it first.
    /// Used to autofill a new entry from the last one with the same payee.
    public func payeeSuggestions(matching text: String, limit: Int = 8) throws -> [Entry] {
        guard let text = Text.normalize(text) else { return [] }
        return try reader.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM (
                  SELECT id, payee, ROW_NUMBER() OVER (PARTITION BY payee ORDER BY date DESC, created_at DESC) AS n,
                         payee LIKE ?1 ESCAPE '\\' AS prefix, date, created_at
                  FROM entry WHERE payee LIKE ?2 ESCAPE '\\'
                ) WHERE n = 1
                ORDER BY prefix DESC, date DESC, created_at DESC
                LIMIT ?3
                """, arguments: ["\(Self.escapeLike(text))%", "%\(Self.escapeLike(text))%", limit])
            return try db.entries(ids.compactMap(Entry.ID.init))
        }
    }

    /// Every op that changed `target`, oldest first: the record's edit history.
    public func history(of target: some CustomStringConvertible) throws -> [Op] {
        try reader.read { try OpLog.history($0, target: target.description).map(\.op) }
    }

    // MARK: Helpers

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// A journal key from a row selecting `id, date, created_at` in that order.
    private static func key(_ row: Row) throws -> JournalKey {
        try key(id: row[0], date: row[1], createdAt: row[2])
    }

    private static func key(id: String, date: String, createdAt: String) throws -> JournalKey {
        guard let id = Entry.ID(id), let date = LocalDate(date), let createdAt = HLCTimestamp(createdAt) else {
            throw StoreError.corrupt("journal key \(id)")
        }
        return JournalKey(date: date, createdAt: createdAt, id: id)
    }

    private static func whereClause(_ filter: JournalFilter) -> (String, StatementArguments) {
        var clauses = ["1"]
        var arguments = StatementArguments()
        if let dates = filter.dates {
            clauses.append("e.date BETWEEN ? AND ?")
            arguments += [dates.lowerBound.description, dates.upperBound.description]
        }
        if let text = Text.normalize(filter.text) {
            let escaped = escapeLike(text)
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
