import CryptoKit
import Foundation
import Testing
@testable import LedgerCore

@Suite struct StateDigestTests {
    func random() -> StateDigest {
        var generator = SystemRandomNumberGenerator()
        return StateDigest(bytes: (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })!
    }

    @Test func additionIsCommutativeAndInvertible() {
        for _ in 0..<200 {
            let a = random(), b = random(), c = random()
            #expect(a + b == b + a)
            #expect((a + b) + c == a + (b + c))
            #expect(a + b - b == a)
            #expect(a - a == .zero)
        }
    }

    @Test func carriesAcrossLimbsAndWraps() {
        let max = StateDigest(bytes: [UInt8](repeating: 0xFF, count: 32))!
        let one = StateDigest(bytes: [UInt8](repeating: 0, count: 31) + [1])!
        #expect(max + one == .zero)
        #expect(StateDigest.zero - one == max)
    }

    @Test func bytesRoundTrip() {
        let digest = random()
        #expect(StateDigest(bytes: digest.bytes) == digest)
    }
}

/// Pinned vectors. If one of these fails, the digest encoding changed — which would make every
/// recorded state digest unverifiable. Don't update the expected values; add a new versioned tag.
@Suite struct DigestVectorTests {
    let rev = Op.ID.named("vector:rev")
    let krw = Commodity.ID.iso4217("KRW")
    let usd = Commodity.ID.iso4217("USD")
    let card = Account.ID.named("vector:card")

    @Test func writerEncoding() {
        var w = DigestWriter(tag: "t")
        w.int64(-2)
        w.bool(true)
        w.optional(nil as String?) { $0.string($1) }
        w.optional("가") { $0.string($1) }
        w.date(LocalDate("2026-09-27")!)
        #expect(w.bytes == [
            0, 0, 0, 1, 0x74,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
            1,
            0,
            1, 0, 0, 0, 3, 0xEA, 0xB0, 0x80,
        ] + Array("2026-09-27".utf8))
    }

    @Test func entry() {
        let entry = Entry(
            id: .named("vector:entry"), date: LocalDate("2026-09-20")!,
            createdAt: HLCTimestamp(millis: 1_758_326_400_000, counter: 1),
            payee: "Apple Store", memo: nil,
            postings: [
                Posting(account: .named("vector:shopping"), commodity: usd, amount: 5_000),
                Posting(account: card, commodity: krw, amount: -68_650),
                Posting(account: SystemAccount.conversion, commodity: usd, amount: -5_000),
                Posting(account: SystemAccount.conversion, commodity: krw, amount: 68_650),
            ],
            rev: rev)
        #expect(RecordDigest.of(entry).hex == Self.expected["entry"])
    }

    @Test func account() {
        let account = Account(
            id: card, parent: nil, name: "신한카드", type: .liability, role: nil,
            openedOn: LocalDate("2020-01-01")!, closedOn: nil, archived: false, deleted: false,
            mergedInto: nil, sortOrder: 0, note: nil, rev: rev)
        #expect(RecordDigest.of(account).hex == Self.expected["account"])
    }

    @Test func commodity() {
        let commodity = Commodity(id: krw, code: "KRW", kind: .currency, scale: 0, name: nil,
                                  quote: nil, feed: #"{"provider":"ecb"}"#, archived: false, rev: rev)
        #expect(RecordDigest.of(commodity).hex == Self.expected["commodity"])
    }

    @Test func chainHash() {
        let next = ChainHash.next(previous: ChainHash.genesis, stateDigest: .zero,
                                  body: Data("{}".utf8), resolution: nil)
        #expect(next.map { String($0, radix: 16).leftPadded(to: 2) }.joined() == Self.expected["chain"])
    }

    /// `entry`, `commodity` and `chain` were cross-checked against an independent Python
    /// implementation of the spec.
    static let expected: [String: String] = [
        "entry": "a67ed0bd0f3acc4d25ebd34de646e9ad2ab361b40df18034ff7f360a108415b5",
        "account": "a57e239500a61538587f8ab40f4621786bb7e92601457d13ff8583e337740e8e",
        "commodity": "dff454d06edc71d69f4d29b459d9e581445a0c78b97cb0e7c3eb48d4de555d01",
        "chain": "0a9e4944e6131fa309f6c9e750e28976cba1f9fd4e7481c56723ea7d42b8c861",
    ]
}

@Suite struct RecordDigestTests {
    @Test func unicodeFormsDigestIdentically() {
        let rev = Op.ID.named("rev")
        func account(_ name: String) -> Account {
            Account(id: .named("a"), parent: nil, name: name, type: .asset, role: nil,
                    openedOn: LocalDate("2020-01-01")!, closedOn: nil, archived: false, deleted: false,
                    mergedInto: nil, sortOrder: 0, note: nil, rev: rev)
        }
        #expect(RecordDigest.of(account("통장")) == RecordDigest.of(account("통장".decomposedStringWithCanonicalMapping)))
    }

    @Test func everyFieldMatters() {
        let rev = Op.ID.named("rev")
        let base = BalanceAssertion(id: .named("b"), account: .named("a"), commodity: .iso4217("KRW"),
                                    date: LocalDate("2026-01-01")!, amount: 100, rev: rev)
        let variants = [
            BalanceAssertion(id: .named("b2"), account: base.account, commodity: base.commodity, date: base.date, amount: 100, rev: rev),
            BalanceAssertion(id: base.id, account: .named("a2"), commodity: base.commodity, date: base.date, amount: 100, rev: rev),
            BalanceAssertion(id: base.id, account: base.account, commodity: .iso4217("USD"), date: base.date, amount: 100, rev: rev),
            BalanceAssertion(id: base.id, account: base.account, commodity: base.commodity, date: LocalDate("2026-01-02")!, amount: 100, rev: rev),
            BalanceAssertion(id: base.id, account: base.account, commodity: base.commodity, date: base.date, amount: 101, rev: rev),
            BalanceAssertion(id: base.id, account: base.account, commodity: base.commodity, date: base.date, amount: 100, rev: .named("rev2")),
        ]
        for variant in variants {
            #expect(RecordDigest.of(variant) != RecordDigest.of(base))
        }
    }
}
