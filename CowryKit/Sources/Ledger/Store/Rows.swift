import Foundation
internal import GRDB
import LedgerCore

enum StoreError: Error, CustomStringConvertible {
    case corrupt(String)

    var description: String {
        switch self {
        case .corrupt(let detail): "Corrupt ledger database: \(detail)"
        }
    }
}

// MARK: - Decoding

extension Row {
    func id<Tag>(_ column: String) throws -> Identifier<Tag> {
        let text: String = self[column]
        guard let id = Identifier<Tag>(text) else { throw StoreError.corrupt("\(column) = \(text)") }
        return id
    }

    func optionalID<Tag>(_ column: String) throws -> Identifier<Tag>? {
        guard let text: String = self[column] else { return nil }
        guard let id = Identifier<Tag>(text) else { throw StoreError.corrupt("\(column) = \(text)") }
        return id
    }

    func date(_ column: String) throws -> LocalDate {
        let text: String = self[column]
        guard let date = LocalDate(text) else { throw StoreError.corrupt("\(column) = \(text)") }
        return date
    }

    func optionalDate(_ column: String) throws -> LocalDate? {
        guard let text: String = self[column] else { return nil }
        guard let date = LocalDate(text) else { throw StoreError.corrupt("\(column) = \(text)") }
        return date
    }

    func hlc(_ column: String) throws -> HLCTimestamp {
        let text: String = self[column]
        guard let value = HLCTimestamp(text) else { throw StoreError.corrupt("\(column) = \(text)") }
        return value
    }

    func enumValue<T: RawRepresentable>(_ column: String) throws -> T where T.RawValue == String {
        let text: String = self[column]
        guard let value = T(rawValue: text) else { throw StoreError.corrupt("\(column) = \(text)") }
        return value
    }
}

enum Rows {
    static func commodity(_ row: Row) throws -> Commodity {
        Commodity(
            id: try row.id("id"), code: row["code"], kind: try row.enumValue("kind"), scale: row["scale"],
            name: row["name"], quote: try row.optionalID("quote_id"), feed: row["feed"],
            archived: row["archived"], rev: try row.id("rev"))
    }

    static func account(_ row: Row) throws -> Account {
        let role: String? = row["role"]
        return Account(
            id: try row.id("id"), parent: try row.optionalID("parent_id"), name: row["name"],
            type: try row.enumValue("type"),
            role: try role.map { text in
                guard let role = Account.Role(rawValue: text) else { throw StoreError.corrupt("role = \(text)") }
                return role
            },
            openedOn: try row.date("opened_on"), closedOn: try row.optionalDate("closed_on"),
            archived: row["archived"], deleted: row["deleted"], mergedInto: try row.optionalID("merged_into"),
            sortOrder: row["sort_order"], note: row["note"], rev: try row.id("rev"))
    }

    static func entry(_ row: Row, postings: [Posting]) throws -> Entry {
        Entry(
            id: try row.id("id"), date: try row.date("date"), createdAt: try row.hlc("created_at"),
            payee: row["payee"], memo: row["memo"], postings: postings, rev: try row.id("rev"))
    }

    static func posting(_ row: Row) throws -> Posting {
        Posting(account: try row.id("account_id"), commodity: try row.id("commodity_id"), amount: row["amount"])
    }

    static func price(_ row: Row) throws -> Price {
        let text: String = row["rate"]
        guard let rate = Rate(text) else { throw StoreError.corrupt("rate = \(text)") }
        return Price(id: try row.id("id"), base: try row.id("base_id"), quote: try row.id("quote_id"),
                     date: try row.date("date"), rate: rate, rev: try row.id("rev"))
    }

    static func balanceAssertion(_ row: Row) throws -> BalanceAssertion {
        BalanceAssertion(id: try row.id("id"), account: try row.id("account_id"),
                         commodity: try row.id("commodity_id"), date: try row.date("date"),
                         amount: row["amount"], rev: try row.id("rev"))
    }

    static func setting(_ row: Row) throws -> Setting {
        Setting(key: SettingKey(rawValue: row["key"]), value: row["value"], rev: try row.id("rev"))
    }
}

// MARK: - Reading

extension Database {
    func commodity(_ id: Commodity.ID) throws -> Commodity? {
        try Row.fetchOne(self, sql: "SELECT * FROM commodity WHERE id = ?", arguments: [id.string])
            .map(Rows.commodity)
    }

    func allCommodities() throws -> [Commodity] {
        try Row.fetchAll(self, sql: "SELECT * FROM commodity ORDER BY code, id").map(Rows.commodity)
    }

    func account(_ id: Account.ID) throws -> Account? {
        try Row.fetchOne(self, sql: "SELECT * FROM account WHERE id = ?", arguments: [id.string])
            .map(Rows.account)
    }

    func allAccounts() throws -> [Account] {
        try Row.fetchAll(self, sql: "SELECT * FROM account").map(Rows.account)
    }

    func entry(_ id: Entry.ID) throws -> Entry? {
        try entries([id]).first
    }

    /// Entries in the order of `ids`; missing IDs are skipped.
    func entries(_ ids: some Collection<Entry.ID>) throws -> [Entry] {
        guard !ids.isEmpty else { return [] }
        var postings: [String: [Posting]] = [:]
        var rows: [String: Row] = [:]
        // Chunk to stay well under SQLite's bound-parameter limit.
        for chunk in Array(ids).chunked(into: 500) {
            let marks = databaseQuestionMarks(count: chunk.count)
            let arguments = StatementArguments(chunk.map(\.string))
            for row in try Row.fetchAll(self, sql: "SELECT * FROM entry WHERE id IN (\(marks))", arguments: arguments) {
                rows[row["id"]] = row
            }
            for row in try Row.fetchAll(
                self,
                sql: "SELECT entry_id, account_id, commodity_id, amount FROM posting WHERE entry_id IN (\(marks)) ORDER BY entry_id, idx",
                arguments: arguments
            ) {
                postings[row["entry_id"], default: []].append(try Rows.posting(row))
            }
        }
        return try ids.compactMap { id in
            try rows[id.string].map { try Rows.entry($0, postings: postings[id.string] ?? []) }
        }
    }

    func price(_ id: Price.ID) throws -> Price? {
        try Row.fetchOne(self, sql: "SELECT * FROM price WHERE id = ?", arguments: [id.string]).map(Rows.price)
    }

    func balanceAssertion(_ id: BalanceAssertion.ID) throws -> BalanceAssertion? {
        try Row.fetchOne(self, sql: "SELECT * FROM balance_assertion WHERE id = ?", arguments: [id.string])
            .map(Rows.balanceAssertion)
    }

    func setting(_ key: SettingKey) throws -> Setting? {
        try Row.fetchOne(self, sql: "SELECT * FROM setting WHERE key = ?", arguments: [key.rawValue])
            .map(Rows.setting)
    }
}

// MARK: - Writing

extension Database {
    func put(_ c: Commodity) throws {
        try execute(sql: """
            INSERT INTO commodity (id, code, kind, scale, name, quote_id, feed, archived, rev)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              code = excluded.code, kind = excluded.kind, scale = excluded.scale, name = excluded.name,
              quote_id = excluded.quote_id, feed = excluded.feed, archived = excluded.archived, rev = excluded.rev
            """, arguments: [c.id.string, c.code, c.kind.rawValue, c.scale, c.name, c.quote?.string, c.feed,
                             c.archived, c.rev.string])
    }

    func put(_ a: Account) throws {
        try execute(sql: """
            INSERT INTO account (id, parent_id, name, type, role, opened_on, closed_on, archived, deleted,
                                 merged_into, sort_order, note, rev)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              parent_id = excluded.parent_id, name = excluded.name, type = excluded.type, role = excluded.role,
              opened_on = excluded.opened_on, closed_on = excluded.closed_on, archived = excluded.archived,
              deleted = excluded.deleted, merged_into = excluded.merged_into, sort_order = excluded.sort_order,
              note = excluded.note, rev = excluded.rev
            """, arguments: [a.id.string, a.parent?.string, a.name, a.type.rawValue, a.role?.rawValue,
                             a.openedOn.description, a.closedOn?.description, a.archived, a.deleted,
                             a.mergedInto?.string, a.sortOrder, a.note, a.rev.string])
    }

    /// Writes an entry and replaces its postings. `resolve` maps an authored account to the account
    /// its balance lands in.
    func put(_ e: Entry, resolve: (Account.ID) throws -> Account.ID) throws {
        try execute(sql: """
            INSERT INTO entry (id, date, created_at, payee, memo, rev) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              date = excluded.date, created_at = excluded.created_at, payee = excluded.payee,
              memo = excluded.memo, rev = excluded.rev
            """, arguments: [e.id.string, e.date.description, e.createdAt.description, e.payee, e.memo, e.rev.string])
        try execute(sql: "DELETE FROM posting WHERE entry_id = ?", arguments: [e.id.string])
        for (index, posting) in e.postings.enumerated() {
            try execute(sql: """
                INSERT INTO posting (entry_id, idx, date, account_id, resolved_account_id, commodity_id, amount)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [e.id.string, index, e.date.description, posting.account.string,
                                 try resolve(posting.account).string, posting.commodity.string, posting.amount])
        }
    }

    func deleteEntry(_ id: Entry.ID) throws {
        try execute(sql: "DELETE FROM entry WHERE id = ?", arguments: [id.string])
    }

    func put(_ p: Price) throws {
        try execute(sql: """
            INSERT INTO price (id, base_id, quote_id, date, rate, rev) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              base_id = excluded.base_id, quote_id = excluded.quote_id, date = excluded.date,
              rate = excluded.rate, rev = excluded.rev
            """, arguments: [p.id.string, p.base.string, p.quote.string, p.date.description, p.rate.string, p.rev.string])
    }

    func deletePrice(_ id: Price.ID) throws {
        try execute(sql: "DELETE FROM price WHERE id = ?", arguments: [id.string])
    }

    func put(_ b: BalanceAssertion) throws {
        try execute(sql: """
            INSERT INTO balance_assertion (id, account_id, commodity_id, date, amount, rev) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              account_id = excluded.account_id, commodity_id = excluded.commodity_id, date = excluded.date,
              amount = excluded.amount, rev = excluded.rev
            """, arguments: [b.id.string, b.account.string, b.commodity.string, b.date.description, b.amount, b.rev.string])
    }

    func deleteBalanceAssertion(_ id: BalanceAssertion.ID) throws {
        try execute(sql: "DELETE FROM balance_assertion WHERE id = ?", arguments: [id.string])
    }

    func put(_ s: Setting) throws {
        try execute(sql: """
            INSERT INTO setting (key, value, rev) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, rev = excluded.rev
            """, arguments: [s.key.rawValue, s.value, s.rev.string])
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}
