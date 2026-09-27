internal import GRDB
import LedgerCore

/// What an op application touched, for change events.
struct ChangeCollector: Sendable {
    var entries: Set<Entry.ID> = []
    var accounts: Set<Account.ID> = []
    var commodities: Set<Commodity.ID> = []
    var prices = false
    var balanceAssertions = false
    var settings = false
    var conflicts = false

    mutating func merge(_ other: ChangeCollector) {
        entries.formUnion(other.entries)
        accounts.formUnion(other.accounts)
        commodities.formUnion(other.commodities)
        prices = prices || other.prices
        balanceAssertions = balanceAssertions || other.balanceAssertions
        settings = settings || other.settings
        conflicts = conflicts || other.conflicts
    }
}

/// Applies op payloads to the materialized tables.
///
/// Applying never decides anything (design principle 4): it writes exactly what the payload says.
/// Authoring validation or a recorded merge resolution has already made every decision. Every
/// record write also updates the running state digest by subtracting the old record's digest
/// and adding the new one.
struct Applier {
    let db: Database
    private(set) var digestDelta = StateDigest.zero
    private(set) var changes = ChangeCollector()

    init(db: Database) {
        self.db = db
    }

    private var reader: StoreReader { StoreReader(db: db) }

    mutating func apply(_ payload: OpPayload, of op: Op) throws {
        let rev = op.id
        switch payload {
        case .createCommodity(let p):
            try write(commodity: Commodity(
                id: p.id, code: p.code, kind: p.kind, scale: p.scale, name: p.name, quote: p.quote,
                feed: p.feed, archived: false, rev: rev))

        case .updateCommodity(let p):
            let c = try require(db.commodity(p.id), p.id)
            try write(commodity: Commodity(
                id: c.id, code: c.code, kind: c.kind, scale: c.scale, name: p.name, quote: p.quote,
                feed: p.feed, archived: c.archived, rev: rev))

        case .archiveCommodity(let p):
            let c = try require(db.commodity(p.id), p.id)
            try write(commodity: Commodity(
                id: c.id, code: c.code, kind: c.kind, scale: c.scale, name: c.name, quote: c.quote,
                feed: c.feed, archived: true, rev: rev))

        case .openAccount(let p):
            try write(account: Account(
                id: p.id, parent: p.parent, name: p.name, type: p.type, role: p.role, openedOn: p.openedOn,
                closedOn: nil, archived: false, deleted: false, mergedInto: nil, sortOrder: 0, note: nil, rev: rev))

        case .updateAccount(let p):
            let a = try require(db.account(p.id), p.id)
            try write(account: a.with(parent: p.parent, name: p.name, sortOrder: p.sortOrder, note: p.note, rev: rev))

        case .closeAccount(let p):
            let a = try require(db.account(p.id), p.id)
            try write(account: a.with(closedOn: .some(p.date), rev: rev))

        case .reopenAccount(let p):
            let a = try require(db.account(p.id), p.id)
            try write(account: a.with(closedOn: .some(nil), rev: rev))

        case .archiveAccount(let p):
            let a = try require(db.account(p.id), p.id)
            try write(account: a.with(archived: true, rev: rev))

        case .deleteAccount(let p):
            let a = try require(db.account(p.id), p.id)
            try write(account: a.with(deleted: true, rev: rev))

        case .mergeAccounts(let p):
            let from = try require(db.account(p.from), p.from)
            try write(account: from.with(mergedInto: .some(p.into), rev: rev))
            // Postings keep the account they were authored with; only where they land moves.
            let affected = try String.fetchAll(db, sql: """
                SELECT DISTINCT entry_id FROM posting WHERE resolved_account_id = ?
                """, arguments: [p.from.string])
            try db.execute(sql: "UPDATE posting SET resolved_account_id = ? WHERE resolved_account_id = ?",
                           arguments: [p.into.string, p.from.string])
            changes.entries.formUnion(affected.compactMap(Entry.ID.init))
            changes.accounts.insert(p.into)

        case .postEntry(let p):
            try write(entry: Entry(id: p.id, date: p.date, createdAt: op.at, payee: p.payee, memo: p.memo,
                                   postings: p.postings, rev: rev))

        case .amendEntry(let p):
            let createdAt = try db.entry(p.id)?.createdAt ?? op.at
            try write(entry: Entry(id: p.id, date: p.date, createdAt: createdAt, payee: p.payee, memo: p.memo,
                                   postings: p.postings, rev: rev))

        case .voidEntry(let p):
            if let old = try db.entry(p.id) {
                digestDelta -= RecordDigest.of(old)
                changes.accounts.formUnion(try postedAccounts(p.id))
                try db.deleteEntry(p.id)
                changes.entries.insert(p.id)
            }

        case .setPrice(let p):
            try write(price: Price(id: p.id, base: p.base, quote: p.quote, date: p.date, rate: p.rate, rev: rev))

        case .removePrice(let p):
            if let old = try db.price(p.id) {
                digestDelta -= RecordDigest.of(old)
                try db.deletePrice(p.id)
                changes.prices = true
            }

        case .assertBalance(let p):
            let assertion = BalanceAssertion(id: p.id, account: p.account, commodity: p.commodity, date: p.date,
                                             amount: p.amount, rev: rev)
            if let old = try db.balanceAssertion(p.id) { digestDelta -= RecordDigest.of(old) }
            try db.put(assertion)
            digestDelta += RecordDigest.of(assertion)
            changes.balanceAssertions = true

        case .removeAssertion(let p):
            if let old = try db.balanceAssertion(p.id) {
                digestDelta -= RecordDigest.of(old)
                try db.deleteBalanceAssertion(p.id)
                changes.balanceAssertions = true
            }

        case .setSetting(let p):
            let setting = Setting(key: p.key, value: p.value, rev: rev)
            if let old = try db.setting(p.key) { digestDelta -= RecordDigest.of(old) }
            try db.put(setting)
            digestDelta += RecordDigest.of(setting)
            changes.settings = true

        case .dismissConflict(let p):
            let inserted = try Bool.fetchOne(db, sql: """
                INSERT INTO conflict_dismissal (op_id) VALUES (?) ON CONFLICT DO NOTHING RETURNING 1
                """, arguments: [p.op.string]) ?? false
            if inserted { digestDelta += RecordDigest.ofConflictDismissal(p.op) }
            changes.conflicts = true
        }
    }

    // MARK: Record writes

    private mutating func write(commodity: Commodity) throws {
        if let old = try db.commodity(commodity.id) { digestDelta -= RecordDigest.of(old) }
        try db.put(commodity)
        digestDelta += RecordDigest.of(commodity)
        changes.commodities.insert(commodity.id)
    }

    private mutating func write(account: Account) throws {
        if let old = try db.account(account.id) { digestDelta -= RecordDigest.of(old) }
        try db.put(account)
        digestDelta += RecordDigest.of(account)
        changes.accounts.insert(account.id)
    }

    private mutating func write(entry: Entry) throws {
        if let old = try db.entry(entry.id) {
            digestDelta -= RecordDigest.of(old)
            changes.accounts.formUnion(try postedAccounts(entry.id))
        }
        let reader = self.reader
        try db.put(entry) { try reader.resolvedAccount($0)?.id ?? $0 }
        digestDelta += RecordDigest.of(entry)
        changes.entries.insert(entry.id)
        changes.accounts.formUnion(try postedAccounts(entry.id))
    }

    /// Accounts whose balances an entry's postings land in.
    private func postedAccounts(_ entry: Entry.ID) throws -> [Account.ID] {
        try String.fetchAll(db, sql: "SELECT DISTINCT resolved_account_id FROM posting WHERE entry_id = ?",
                            arguments: [entry.string]).compactMap(Account.ID.init)
    }

    private mutating func write(price: Price) throws {
        if let old = try db.price(price.id) { digestDelta -= RecordDigest.of(old) }
        try db.put(price)
        digestDelta += RecordDigest.of(price)
        changes.prices = true
    }

    private func require<T, Tag>(_ value: T?, _ id: Identifier<Tag>) throws -> T {
        guard let value else { throw StoreError.corrupt("op targets missing record \(id)") }
        return value
    }
}

extension Account {
    /// A copy with some fields replaced. Double optionals distinguish "keep" from "set to nil".
    func with(
        parent: Account.ID?? = nil, name: String? = nil, closedOn: LocalDate?? = nil, archived: Bool? = nil,
        deleted: Bool? = nil, mergedInto: Account.ID?? = nil, sortOrder: Int? = nil, note: String?? = nil,
        rev: Op.ID
    ) -> Account {
        Account(
            id: id, parent: parent ?? self.parent, name: name ?? self.name, type: type, role: role,
            openedOn: openedOn, closedOn: closedOn ?? self.closedOn, archived: archived ?? self.archived,
            deleted: deleted ?? self.deleted, mergedInto: mergedInto ?? self.mergedInto,
            sortOrder: sortOrder ?? self.sortOrder, note: note ?? self.note, rev: rev)
    }
}
