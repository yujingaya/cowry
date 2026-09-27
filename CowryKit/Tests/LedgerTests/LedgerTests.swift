import Foundation
internal import GRDB
import Testing
@testable import Ledger
import LedgerCore

@Suite struct BootstrapTests {
    @Test func newLedgerHasSystemAccountsAndPrimaryCurrency() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cowry-\(UUID().uuidString).cowry")
        let ledger = try Ledger(at: url, device: .named("d"), primaryCurrency: "krw")
        let snapshot = ledger.snapshot()
        let tree = try snapshot.accounts()
        #expect(tree[SystemAccount.conversion]?.role == .conversion)
        #expect(tree[SystemAccount.openingBalances]?.role == .openingBalance)
        #expect(try snapshot.primaryCommodity() == .iso4217("KRW"))
        #expect(try snapshot.commodity(.iso4217("KRW"))?.scale == 0)
        #expect(snapshot.head == 4)
        #expect(try ledger.verify().isValid)
    }

    @Test func reopeningKeepsStateAndDoesNotBootstrapAgain() async throws {
        let fixture = try await Fixture()
        try await fixture.spend(4_500, on: "2026-03-01")
        let head = fixture.ledger.snapshot().head
        let reopened = try Ledger(at: fixture.url, device: .named("test-device"))
        #expect(reopened.snapshot().head == head)
        #expect(try reopened.snapshot().journal().count == 1)
        #expect(try reopened.verify().isValid)
    }
}

@Suite struct EntryTests {
    @Test func postingUpdatesBalancesAndRegister() async throws {
        let f = try await Fixture()
        try await f.spend(4_500, on: "2026-03-02", at: "스타벅스")
        try await f.spend(12_000, on: "2026-03-01", at: "김밥천국")
        try await f.spend(3_000, on: "2026-03-05", from: f.cash)

        let snapshot = f.ledger.snapshot()
        let balances = try snapshot.balances()
        #expect(balances[f.food.id] == [f.krw: 19_500])
        #expect(balances[f.card.id] == [f.krw: -16_500])
        #expect(try snapshot.balances(asOf: LocalDate("2026-03-01")!)[f.card.id] == [f.krw: -12_000])

        let register = try snapshot.register(of: [f.card.id])
        #expect(register.rows.map { $0.balance[f.krw] } == [-12_000, -16_500])
        #expect(register.rows.map(\.key.date.description) == ["2026-03-01", "2026-03-02"])
    }

    @Test func journalIsOrderedByDateThenPostingTime() async throws {
        let f = try await Fixture()
        let late = try await f.spend(1, on: "2026-03-02")
        let first = try await f.spend(2, on: "2026-03-01")
        let second = try await f.spend(3, on: "2026-03-02")
        let index = try f.ledger.snapshot().journal()
        #expect(index.map(\.id) == [first.id, late.id, second.id])
        #expect(index.index(of: index[1]) == 1)
        #expect(try f.ledger.snapshot().entries(index.map(\.id)).map(\.id) == index.map(\.id))
    }

    @Test func mixedCurrenciesAreBalancedThroughConversion() async throws {
        let f = try await Fixture()
        let entry = try await f.ledger.post(f.draft("2026-09-20", "Apple Store",
                                                    (f.shopping, f.usd, 5_000), (f.card, f.krw, -68_650)))
        #expect(entry.postings.count == 4)
        #expect(entry.userPostings.count == 2)
        let balances = try f.ledger.snapshot().balances()
        #expect(balances[SystemAccount.conversion] == [f.usd: -5_000, f.krw: 68_650])
        #expect(balances[f.shopping.id] == [f.usd: 5_000])
    }

    @Test func amendKeepsPostingTimeAndRecordsHistory() async throws {
        let f = try await Fixture()
        let entry = try await f.spend(4_500, on: "2026-03-02", at: "스타벅스")
        var draft = EntryDraft(entry)
        draft.postings = [Posting(account: f.food.id, commodity: f.krw, amount: 5_000),
                          Posting(account: f.card.id, commodity: f.krw, amount: -5_000)]
        draft.memo = "사이즈업"
        let amended = try await f.ledger.amend(entry, to: draft)
        #expect(amended.createdAt == entry.createdAt)
        #expect(amended.rev != entry.rev)
        #expect(amended.memo == "사이즈업")
        #expect(try f.ledger.snapshot().history(of: entry.id).map(\.kind) == [.postEntry, .amendEntry])
    }

    @Test func editingAStaleCopyIsRefused() async throws {
        let f = try await Fixture()
        let entry = try await f.spend(4_500, on: "2026-03-02")
        var draft = EntryDraft(entry)
        draft.memo = "first window"
        let amended = try await f.ledger.amend(entry, to: draft)
        draft.memo = "second window"
        await #expect(throws: ValidationError.staleRevision(current: amended.rev)) {
            _ = try await f.ledger.amend(entry, to: draft)
        }
    }

    @Test func voidRemovesTheEntry() async throws {
        let f = try await Fixture()
        let entry = try await f.spend(4_500, on: "2026-03-02")
        try await f.ledger.void(entry)
        let snapshot = f.ledger.snapshot()
        #expect(try snapshot.entry(entry.id) == nil)
        #expect(try snapshot.balances()[f.card.id] == nil)
        #expect(try snapshot.history(of: entry.id).map(\.kind) == [.postEntry, .voidEntry])
    }

    @Test func invalidDraftsAreRefused() async throws {
        let f = try await Fixture()
        await #expect(throws: ValidationError.unbalanced(f.krw, residual: 500)) {
            _ = try await f.ledger.post(f.draft("2026-03-01", nil, (f.food, f.krw, 5_000), (f.card, f.krw, -4_500)))
        }
        await #expect(throws: ValidationError.accountNotOpen(f.food.id, on: LocalDate("2025-12-31")!)) {
            _ = try await f.ledger.post(f.draft("2025-12-31", nil, (f.food, f.krw, 1), (f.card, f.krw, -1)))
        }
        #expect(f.ledger.snapshot().head == 9)
    }
}

@Suite struct AccountTests {
    @Test func mergeRedirectsBalancesButKeepsAuthoredPostings() async throws {
        let f = try await Fixture()
        let old = try await f.ledger.openAccount(name: "구 카드", type: .liability, openedOn: Fixture.opened)
        let entry = try await f.spend(10_000, on: "2026-03-01", from: old)
        try await f.spend(2_000, on: "2026-03-02")
        try await f.ledger.mergeAccounts(old.id, into: f.card.id)

        let snapshot = f.ledger.snapshot()
        #expect(try snapshot.balances()[f.card.id] == [f.krw: -12_000])
        #expect(try snapshot.balances()[old.id] == nil)
        #expect(try snapshot.entry(entry.id)?.postings[1].account == old.id)
        #expect(try snapshot.journal(JournalFilter(accounts: [f.card.id])).count == 2)
        #expect(try snapshot.accounts().roots.contains(old.id) == false)

        // New postings to the merged account land in the target.
        let later = try await f.spend(1_000, on: "2026-03-03", from: old)
        #expect(later.postings[1].account == f.card.id)
        #expect(try f.ledger.verify().isValid)
    }

    @Test func closingRefusesLaterPostingsInBothDirections() async throws {
        let f = try await Fixture()
        try await f.spend(1_000, on: "2026-03-10", from: f.cash)
        await #expect(throws: ValidationError.postingsAfterClose(f.cash.id, LocalDate("2026-03-01")!)) {
            try await f.ledger.closeAccount(f.cash, on: LocalDate("2026-03-01")!)
        }
        try await f.ledger.closeAccount(f.cash, on: LocalDate("2026-03-31")!)
        await #expect(throws: ValidationError.accountNotOpen(f.cash.id, on: LocalDate("2026-04-01")!)) {
            try await f.spend(1_000, on: "2026-04-01", from: f.cash)
        }
    }

    @Test func treeAndPaths() async throws {
        let f = try await Fixture()
        let bank = try await f.ledger.openAccount(name: "은행", type: .asset, openedOn: Fixture.opened)
        let shinhan = try await f.ledger.openAccount(name: "신한", type: .asset, parent: bank.id, openedOn: Fixture.opened)
        let tree = try f.ledger.snapshot().accounts()
        #expect(tree.path(of: shinhan.id) == "은행:신한")
        #expect(tree.subtree(of: bank.id) == [bank.id, shinhan.id])
        #expect(tree.children(of: bank.id) == [shinhan.id])
    }
}

@Suite struct JournalFilterTests {
    @Test func searchesPayeeAndMemoIncludingShortKoreanWords() async throws {
        let f = try await Fixture()
        try await f.spend(4_500, on: "2026-03-01", at: "스타벅스 커피")
        try await f.spend(3_000, on: "2026-03-02", at: "편의점")
        try await f.spend(100, on: "2026-03-03", at: "50%_할인")
        let snapshot = f.ledger.snapshot()
        #expect(try snapshot.journal(JournalFilter(text: "커피")).count == 1)
        #expect(try snapshot.journal(JournalFilter(text: "커피".decomposedStringWithCanonicalMapping)).count == 1)
        #expect(try snapshot.journal(JournalFilter(text: "%_")).count == 1)
        #expect(try snapshot.journal(JournalFilter(dates: LocalDate("2026-03-02")!...LocalDate("2026-03-03")!)).count == 2)
        #expect(try snapshot.journal(JournalFilter(accounts: [f.cash.id])).isEmpty)
    }

    @Test func journalKeysReportsWhichChangedIDsStillMatch() async throws {
        let f = try await Fixture()
        let a = try await f.spend(1, on: "2026-03-01", at: "커피")
        let b = try await f.spend(2, on: "2026-03-02", at: "밥")
        let keys = try f.ledger.snapshot().journalKeys(of: [a.id, b.id, .named("missing")],
                                                       matching: JournalFilter(text: "커피"))
        #expect(keys.map(\.id) == [a.id])
    }
}

@Suite struct ChangeStreamTests {
    @Test func publishesChangedIDsWithASnapshotThatContainsThem() async throws {
        let f = try await Fixture()
        var changes = f.ledger.changes().makeAsyncIterator()
        let entry = try await f.spend(4_500, on: "2026-03-01")
        let change = try #require(await changes.next())
        #expect(change.entries == [entry.id])
        #expect(change.accounts.isSuperset(of: [f.food.id, f.card.id]))
        #expect(try change.snapshot.entry(entry.id) != nil)
    }

    @Test func snapshotsAreStable() async throws {
        let f = try await Fixture()
        let before = f.ledger.snapshot()
        try await f.spend(4_500, on: "2026-03-01")
        #expect(try before.journal().isEmpty)
        #expect(try f.ledger.snapshot().journal().count == 1)
    }
}

@Suite struct IntegrityTests {
    @Test func detectsTamperedLiveState() async throws {
        let f = try await Fixture()
        let entry = try await f.spend(4_500, on: "2026-03-01")
        try await f.ledger.pool.write { db in
            try db.execute(sql: "UPDATE entry SET payee = 'forged' WHERE id = ?", arguments: [entry.id.string])
        }
        let report = try f.ledger.verify()
        #expect(report.problems.count == 1)
        guard case .liveStateMismatch = report.problems.first else { Issue.record("\(report.problems)"); return }
    }

    @Test func detectsTamperedLog() async throws {
        let f = try await Fixture()
        let entry = try await f.spend(4_500, on: "2026-03-01")
        try await f.ledger.pool.write { db in
            let body: Data = try Data.fetchOne(db, sql: "SELECT body FROM op WHERE target = ?", arguments: [entry.id.string])!
            let forged = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "4500", with: "450")
            try db.execute(sql: "UPDATE op SET body = ? WHERE target = ?", arguments: [Data(forged.utf8), entry.id.string])
        }
        let problems = try f.ledger.verify().problems
        #expect(problems.contains(.brokenChain(seq: 10)))
        #expect(problems.contains { if case .replayDiverged(seq: 10, _, _) = $0 { true } else { false } })
    }

    /// Random commands; afterwards replay must reproduce every recorded digest, the live tables
    /// must match the running digest, and every entry must balance per commodity.
    @Test func randomHistoryReplaysExactly() async throws {
        let f = try await Fixture()
        var rng = SeededGenerator(seed: 42)
        var live: [Entry] = []
        let accounts = [f.cash!, f.card!, f.food!, f.shopping!]
        for step in 0..<300 {
            let date = "2026-\(String(format: "%02d", Int.random(in: 1...12, using: &rng)))-\(String(format: "%02d", Int.random(in: 1...28, using: &rng)))"
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<6:
                let from = accounts.randomElement(using: &rng)!, to = accounts.randomElement(using: &rng)!
                let amount = Int64.random(in: 1...1_000_000, using: &rng)
                let draft = Bool.random(using: &rng)
                    ? f.draft(date, "p\(step)", (to, f.krw, amount), (from, f.krw, -amount))
                    : f.draft(date, "fx\(step)", (to, f.usd, amount / 1000 + 1), (from, f.krw, -amount))
                live.append(try await f.ledger.post(draft))
            case 6..<8 where !live.isEmpty:
                let index = Int.random(in: 0..<live.count, using: &rng)
                var draft = EntryDraft(live[index])
                draft.memo = "edit \(step)"
                draft.date = LocalDate(date)!
                live[index] = try await f.ledger.amend(live[index], to: draft)
            case 8 where !live.isEmpty:
                try await f.ledger.void(live.remove(at: Int.random(in: 0..<live.count, using: &rng)))
            default:
                _ = try await f.ledger.setPrice(base: f.usd, quote: f.krw, date: LocalDate(date)!,
                                                rate: Rate("\(Int.random(in: 1200...1500, using: &rng)).\(Int.random(in: 0...99, using: &rng))")!)
            }
        }
        let report = try f.ledger.verify()
        #expect(report.isValid, "\(report.problems)")
        #expect(report.opsChecked > 300)
        let unbalanced = try await f.ledger.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (SELECT entry_id FROM posting GROUP BY entry_id, commodity_id HAVING SUM(amount) != 0)
                """)!
        }
        #expect(unbalanced == 0)
        #expect(try f.ledger.snapshot().journal().count == live.count)
    }
}

/// Deterministic generator so failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
