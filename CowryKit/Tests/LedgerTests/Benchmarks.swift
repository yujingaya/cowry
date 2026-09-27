import Foundation
internal import GRDB
import Testing
@testable import Ledger
import LedgerCore

/// Timing of the reads a 100,000-entry list depends on (design.md §8.2). Run explicitly:
/// `COWRY_BENCHMARK=1 swift test --filter Benchmarks`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COWRY_BENCHMARK"] != nil))
struct Benchmarks {
    @Test func journalIndexAt100k() async throws {
        let f = try await Fixture()
        let clock = ContinuousClock()
        var rng = SeededGenerator(seed: 7)
        let posting = try await clock.measure {
            for chunk in 0 ..< 50 {
                let drafts = (0 ..< 2_000).map { i -> EntryDraft in
                    let day = LocalDate(ordinal: LocalDate("2026-01-01")!.ordinal + (chunk * 2_000 + i) / 14)!
                    let amount = Int64.random(in: 1_000...90_000, using: &rng)
                    return EntryDraft(date: day, payee: "payee \(i % 300)", postings: [
                        Posting(account: f.food.id, commodity: f.krw, amount: amount),
                        Posting(account: f.card.id, commodity: f.krw, amount: -amount),
                    ])
                }
                _ = try await f.ledger.post(drafts)
            }
        }
        print("[bench] post 100k: \(posting)")
        let snapshot = f.ledger.snapshot()
        let breakdown = try await f.ledger.pool.read { db in
            let sqlOnly = try clock.measure {
                let cursor = try Row.fetchCursor(db, sql: "SELECT id, date, created_at FROM entry ORDER BY date, created_at, id")
                while try cursor.next() != nil {}
            }
            let strings = try clock.measure {
                let cursor = try Row.fetchCursor(db, sql: "SELECT id, date, created_at FROM entry ORDER BY date, created_at, id")
                while let row = try cursor.next() { _ = (row[0] as String, row[1] as String, row[2] as String) }
            }
            let uuids = try clock.measure {
                let cursor = try Row.fetchCursor(db, sql: "SELECT id FROM entry ORDER BY date, created_at, id")
                while let row = try cursor.next() { _ = Entry.ID(row[0] as String) }
            }
            let hlcs = try clock.measure {
                let cursor = try Row.fetchCursor(db, sql: "SELECT created_at FROM entry ORDER BY date, created_at, id")
                while let row = try cursor.next() { _ = HLCTimestamp(row[0] as String) }
            }
            return "sql \(sqlOnly) · strings \(strings) · uuid parse \(uuids) · hlc parse \(hlcs)"
        }
        print("[bench] breakdown: \(breakdown)")
        for _ in 0 ..< 3 {
            let all = try clock.measure { _ = try snapshot.journal() }
            let text = try clock.measure { _ = try snapshot.journal(JournalFilter(text: "payee 1")) }
            let register = try clock.measure { _ = try snapshot.register(of: [f.card.id]) }
            let balances = try clock.measure { _ = try snapshot.balances() }
            print("[bench] journal all \(all) · text \(text) · register \(register) · balances \(balances)")
        }
    }
}
