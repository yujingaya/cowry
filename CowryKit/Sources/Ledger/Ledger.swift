import Foundation
internal import GRDB
import LedgerCore

/// The ledger runtime: the only way to change a ledger, and the source of snapshots and change
/// events for the UI.
///
/// Every command authors one op against the current state (refusing invalid input), applies it,
/// and appends it to the log with its state digest and chain hash — all in one transaction.
public final class Ledger: Sendable {
    public let device: DeviceID
    let pool: DatabasePool
    private let publisher: ChangePublisher

    /// Opens (creating if needed) the ledger file at `url`. A new file starts with the system
    /// accounts and `primaryCurrency` as its primary commodity.
    public init(at url: URL, device: DeviceID, primaryCurrency: String = "KRW") throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try Schema.migrator().migrate(pool)
        self.device = device
        publisher = ChangePublisher(head: try pool.read { try Meta.head($0).seq })

        let isEmpty = try pool.read { try Meta.head($0).seq == 0 }
        if isEmpty { try bootstrap(primaryCurrency: primaryCurrency) }
    }

    deinit {
        publisher.finish()
    }

    public func snapshot() -> LedgerSnapshot {
        let reader = ChangePublisher.snapshotReader(pool)
        let head = (try? reader.read { try Meta.head($0).seq }) ?? 0
        return LedgerSnapshot(reader: reader, head: head)
    }

    /// Changes from now on, in log order.
    public func changes() -> AsyncStream<LedgerChange> {
        publisher.stream()
    }

    // MARK: Commodities

    /// The ISO 4217 currency `code`, creating it if the ledger doesn't have it yet.
    @discardableResult
    public func currency(_ code: String) async throws -> Commodity {
        let id = Commodity.ID.iso4217(code)
        if let existing = try await pool.read({ try $0.commodity(id) }) { return existing }
        return try await commit { state in
            .createCommodity(try Authoring.createCommodity(
                id: id, code: code.uppercased(), kind: .currency, scale: ISO4217.scale(for: code),
                name: nil, quote: nil, feed: #"{"provider":"ecb"}"#, in: state))
        } result: { db, _ in try db.commodity(id)! }
    }

    public func createCommodity(
        code: String, kind: Commodity.Kind, scale: Int, name: String? = nil, quote: Commodity.ID? = nil,
        feed: String? = nil
    ) async throws -> Commodity {
        let id = Commodity.ID.generate()
        return try await commit { state in
            .createCommodity(try Authoring.createCommodity(
                id: id, code: code, kind: kind, scale: scale, name: name, quote: quote, feed: feed, in: state))
        } result: { db, _ in try db.commodity(id)! }
    }

    public func updateCommodity(
        _ commodity: Commodity, name: String?, quote: Commodity.ID?, feed: String?
    ) async throws -> Commodity {
        try await commit { state in
            .updateCommodity(try Authoring.updateCommodity(commodity, name: name, quote: quote, feed: feed, in: state))
        } result: { db, _ in try db.commodity(commodity.id)! }
    }

    public func archiveCommodity(_ commodity: Commodity) async throws {
        try await commit { .archiveCommodity(try Authoring.archiveCommodity(commodity, in: $0)) } result: { _, _ in }
    }

    // MARK: Accounts

    public func openAccount(
        name: String, type: AccountType, parent: Account.ID? = nil, openedOn: LocalDate
    ) async throws -> Account {
        let id = Account.ID.generate()
        return try await commit { state in
            .openAccount(try Authoring.openAccount(id: id, parent: parent, name: name, type: type,
                                                   openedOn: openedOn, in: state))
        } result: { db, _ in try db.account(id)! }
    }

    public func updateAccount(
        _ account: Account, name: String, parent: Account.ID?, sortOrder: Int, note: String?
    ) async throws -> Account {
        try await commit { state in
            .updateAccount(try Authoring.updateAccount(account, parent: parent, name: name, sortOrder: sortOrder,
                                                       note: note, in: state))
        } result: { db, _ in try db.account(account.id)! }
    }

    public func closeAccount(_ account: Account, on date: LocalDate) async throws {
        try await commit { .closeAccount(try Authoring.closeAccount(account, on: date, in: $0)) } result: { _, _ in }
    }

    public func reopenAccount(_ account: Account) async throws {
        try await commit { .reopenAccount(try Authoring.reopenAccount(account, in: $0)) } result: { _, _ in }
    }

    public func archiveAccount(_ account: Account) async throws {
        try await commit { .archiveAccount(try Authoring.archiveAccount(account, in: $0)) } result: { _, _ in }
    }

    public func deleteAccount(_ account: Account) async throws {
        try await commit { .deleteAccount(try Authoring.deleteAccount(account, in: $0)) } result: { _, _ in }
    }

    public func mergeAccounts(_ from: Account.ID, into: Account.ID) async throws {
        try await commit { .mergeAccounts(try Authoring.mergeAccounts(from: from, into: into, in: $0)) } result: { _, _ in }
    }

    // MARK: Entries

    public func post(_ draft: EntryDraft) async throws -> Entry {
        let id = Entry.ID.generate()
        return try await commit { .postEntry(try Authoring.postEntry(id: id, draft, in: $0)) }
            result: { db, _ in try db.entry(id)! }
    }

    public func amend(_ entry: Entry, to draft: EntryDraft) async throws -> Entry {
        try await commit { .amendEntry(try Authoring.amendEntry(entry, to: draft, in: $0)) }
            result: { db, _ in try db.entry(entry.id)! }
    }

    public func void(_ entry: Entry) async throws {
        try await commit { .voidEntry(try Authoring.voidEntry(entry, in: $0)) } result: { _, _ in }
    }

    // MARK: Prices, assertions, settings

    public func setPrice(
        base: Commodity.ID, quote: Commodity.ID, date: LocalDate, rate: Rate
    ) async throws -> Price {
        let id = Price.ID.generate()
        return try await commit { state in
            .setPrice(try Authoring.setPrice(id: id, base: base, quote: quote, date: date, rate: rate, in: state))
        } result: { db, _ in try db.price(id)! }
    }

    public func removePrice(_ price: Price) async throws {
        try await commit { .removePrice(try Authoring.removePrice(price, in: $0)) } result: { _, _ in }
    }

    public func assertBalance(
        account: Account.ID, commodity: Commodity.ID, date: LocalDate, amount: Int64
    ) async throws -> BalanceAssertion {
        let id = BalanceAssertion.ID.generate()
        return try await commit { state in
            .assertBalance(try Authoring.assertBalance(id: id, account: account, commodity: commodity, date: date,
                                                       amount: amount, in: state))
        } result: { db, _ in try db.balanceAssertion(id)! }
    }

    public func removeAssertion(_ assertion: BalanceAssertion) async throws {
        try await commit { .removeAssertion(try Authoring.removeAssertion(assertion, in: $0)) } result: { _, _ in }
    }

    public func setPrimaryCommodity(_ commodity: Commodity.ID) async throws {
        try await commit { .setSetting(try Authoring.setSetting(.primaryCommodity, commodity.string, in: $0)) }
            result: { _, _ in }
    }

    public func dismissConflict(_ op: Op.ID) async throws {
        try await commit { .dismissConflict(try Authoring.dismissConflict(op, in: $0)) } result: { _, _ in }
    }

    // MARK: Commit

    /// Authors, applies and logs one op in a single write transaction, then publishes the change.
    private func commit<T: Sendable>(
        _ author: @escaping @Sendable (StoreReader) throws -> OpPayload,
        result: @escaping @Sendable (Database, Op) throws -> T
    ) async throws -> T {
        let device = self.device
        let publisher = self.publisher
        let value = try await pool.write { db in
            try Self.commit(db, device: device, publisher: publisher, author: author, result: result)
        }
        publisher.flush(pool)
        return value
    }

    private static func commit<T>(
        _ db: Database, device: DeviceID, publisher: ChangePublisher,
        author: (StoreReader) throws -> OpPayload, result: (Database, Op) throws -> T
    ) throws -> T {
        let payload = try author(StoreReader(db: db))
        var clock = try Meta.clock(db)
        let op = Op(id: .generate(), device: device, at: clock.now(), payload: payload)
        try Meta.setClock(db, clock)
        let body = try OpCodec.encode(op)

        var applier = Applier(db: db)
        try applier.apply(payload, of: op)

        let head = try Meta.head(db)
        let digest = head.digest + applier.digestDelta
        let hash = ChainHash.next(previous: head.hash, stateDigest: digest, body: body, resolution: nil)
        let next = LogHead(seq: head.seq + 1, hash: hash, digest: digest)
        try OpLog.appendMain(db, op: op, body: body, resolution: nil, seq: next.seq, prevHash: head.hash,
                             stateDigest: digest, hash: hash)
        try Meta.setHead(db, next)
        publisher.record(seq: next.seq, applier.changes)
        return try result(db, op)
    }

    private func bootstrap(primaryCurrency: String) throws {
        let code = primaryCurrency.uppercased()
        let primary = Commodity.ID.iso4217(code)
        let genesis: [(StoreReader) throws -> OpPayload] = [
            { .createCommodity(try Authoring.createCommodity(
                id: primary, code: code, kind: .currency, scale: ISO4217.scale(for: code), name: nil, quote: nil,
                feed: #"{"provider":"ecb"}"#, in: $0)) },
            { .openAccount(try Authoring.openAccount(
                id: SystemAccount.conversion, parent: nil, name: "Conversion", type: .equity,
                openedOn: Self.beginningOfTime, role: .conversion, in: $0)) },
            { .openAccount(try Authoring.openAccount(
                id: SystemAccount.openingBalances, parent: nil, name: "Opening Balances", type: .equity,
                openedOn: Self.beginningOfTime, role: .openingBalance, in: $0)) },
            { .setSetting(try Authoring.setSetting(.primaryCommodity, primary.string, in: $0)) },
        ]
        try pool.write { db in
            for author in genesis {
                try Self.commit(db, device: device, publisher: publisher, author: author, result: { _, _ in })
            }
        }
        publisher.flush(pool)
    }

    static let beginningOfTime = LocalDate(year: 1900, month: 1, day: 1)!
}
