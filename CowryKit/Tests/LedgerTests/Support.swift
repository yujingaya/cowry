import Foundation
@testable import Ledger
import LedgerCore

/// A ledger in a fresh temporary directory, with a few accounts most tests need.
struct Fixture {
    let url: URL
    let ledger: Ledger
    let krw = Commodity.ID.iso4217("KRW")
    let usd = Commodity.ID.iso4217("USD")
    var cash: Account!
    var card: Account!
    var food: Account!
    var shopping: Account!

    static let opened = LocalDate("2026-01-01")!

    init() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cowry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("ledger.cowry")
        ledger = try Ledger(at: url, device: .named("test-device"))
        try await ledger.currency("USD")
        cash = try await ledger.openAccount(name: "현금", type: .asset, openedOn: Self.opened)
        card = try await ledger.openAccount(name: "신한카드", type: .liability, openedOn: Self.opened)
        food = try await ledger.openAccount(name: "식비", type: .expense, openedOn: Self.opened)
        shopping = try await ledger.openAccount(name: "쇼핑", type: .expense, openedOn: Self.opened)
    }

    func draft(_ date: String, _ payee: String? = nil, _ postings: (Account, Commodity.ID, Int64)...) -> EntryDraft {
        EntryDraft(date: LocalDate(date)!, payee: payee,
                   postings: postings.map { Posting(account: $0.0.id, commodity: $0.1, amount: $0.2) })
    }

    /// Posts a single-currency KRW expense paid from `from`.
    @discardableResult
    func spend(_ amount: Int64, on date: String, at payee: String? = nil, from: Account? = nil, to: Account? = nil) async throws -> Entry {
        try await ledger.post(draft(date, payee, (to ?? food, krw, amount), (from ?? card, krw, -amount)))
    }
}
