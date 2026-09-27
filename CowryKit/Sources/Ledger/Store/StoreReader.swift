internal import GRDB
import LedgerCore

/// `LedgerStateReading` over a database connection, for authoring and applying ops.
struct StoreReader: LedgerStateReading {
    let db: Database

    func commodity(_ id: Commodity.ID) throws -> Commodity? {
        try db.commodity(id)
    }

    func commodities(code: String) throws -> [Commodity] {
        try Row.fetchAll(db, sql: "SELECT * FROM commodity WHERE code = ?", arguments: [code]).map(Rows.commodity)
    }

    func account(_ id: Account.ID) throws -> Account? {
        try db.account(id)
    }

    func accounts(parent: Account.ID?) throws -> [Account] {
        try Row.fetchAll(db, sql: "SELECT * FROM account WHERE parent_id IS ?", arguments: [parent?.string])
            .map(Rows.account)
    }

    func entry(_ id: Entry.ID) throws -> Entry? {
        try db.entry(id)
    }

    func price(_ id: Price.ID) throws -> Price? {
        try db.price(id)
    }

    func balanceAssertion(_ id: BalanceAssertion.ID) throws -> BalanceAssertion? {
        try db.balanceAssertion(id)
    }

    func hasPostings(account: Account.ID, after date: LocalDate?) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM posting WHERE resolved_account_id = ? AND (?2 IS NULL OR date > ?2))
            """, arguments: [account.string, date?.description]) ?? false
    }

    func hasBalanceAssertions(account: Account.ID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM balance_assertion WHERE account_id = ?)",
                          arguments: [account.string]) ?? false
    }

    func opExists(_ id: Op.ID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM op WHERE id = ?)", arguments: [id.string]) ?? false
    }
}
