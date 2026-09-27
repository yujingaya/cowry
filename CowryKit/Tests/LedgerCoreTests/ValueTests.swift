import Foundation
import Testing
@testable import LedgerCore

@Suite struct LocalDateTests {
    @Test func parsesAndFormats() throws {
        let date = try #require(LocalDate("2026-09-27"))
        #expect(date.year == 2026 && date.month == 9 && date.day == 27)
        #expect(date.description == "2026-09-27")
        #expect(LocalDate(year: 5, month: 1, day: 2)?.description == "0005-01-02")
    }

    @Test(arguments: ["2026-02-29", "2026-13-01", "2026-00-10", "26-09-27", "2026/09/27", "2026-9-27", "", "abcd-ef-gh"])
    func rejectsInvalid(_ text: String) {
        #expect(LocalDate(text) == nil)
    }

    @Test func leapYears() {
        #expect(LocalDate("2024-02-29") != nil)
        #expect(LocalDate("2000-02-29") != nil)
        #expect(LocalDate("1900-02-29") == nil)
    }

    @Test func ordinalRoundTrips() throws {
        #expect(LocalDate("1970-01-01")?.ordinal == 0)
        #expect(LocalDate("2000-03-01")?.ordinal == 11_017)
        let start = try #require(LocalDate("1999-12-01")).ordinal
        var previous: LocalDate?
        for ordinal in start ..< start + 3000 {
            let date = try #require(LocalDate(ordinal: ordinal))
            #expect(date.ordinal == ordinal)
            if let previous { #expect(previous < date) }
            previous = date
        }
    }

    @Test func codesAsString() throws {
        let data = try JSONEncoder().encode([LocalDate("2026-01-05")!])
        #expect(String(decoding: data, as: UTF8.self) == #"["2026-01-05"]"#)
    }
}

@Suite struct IdentifierTests {
    @Test func v5MatchesRFC9562Vector() throws {
        let dns = try #require(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        #expect(UUID.v5(namespace: dns, name: "www.example.com").uuidString.lowercased()
            == "2ed6657d-e927-568b-95e1-2665a8aea6a2")
    }

    @Test func namedIsDeterministic() {
        #expect(Commodity.ID.iso4217("KRW") == Commodity.ID.iso4217("krw"))
        #expect(Commodity.ID.iso4217("KRW") != Commodity.ID.iso4217("USD"))
    }

    @Test func v7IsVersionedAndTimeOrdered() {
        let earlier = Entry.ID.generate(at: Date(timeIntervalSince1970: 1_000))
        let later = Entry.ID.generate(at: Date(timeIntervalSince1970: 2_000))
        #expect(earlier.bytes[6] >> 4 == 7)
        #expect(earlier.bytes[8] >> 6 == 0b10)
        #expect(earlier < later)
    }

    @Test func fastParserAgreesWithFoundation() {
        for _ in 0 ..< 500 {
            let uuid = UUID()
            #expect(Entry.ID(uuid.uuidString)?.uuid == uuid)
            #expect(Entry.ID(uuid.uuidString.lowercased())?.uuid == uuid)
        }
        for bad in ["", "not-a-uuid", "6ba7b810-9dad-11d1-80b4-00c04fd430cg", "6ba7b810x9dad-11d1-80b4-00c04fd430c8",
                    "6ba7b810-9dad-11d1-80b4-00c04fd430c"] {
            #expect(Entry.ID(bad) == nil)
        }
    }

    @Test func stringIsLowercase() {
        let id = Entry.ID.generate()
        #expect(id.string == id.string.lowercased())
        #expect(Entry.ID(id.string) == id)
    }
}

@Suite struct TextTests {
    @Test func normalizesToNFC() {
        let decomposed = "신한카드".decomposedStringWithCanonicalMapping
        #expect(Array(decomposed.utf8) != Array("신한카드".utf8))
        #expect(Array(Text.normalize(decomposed)!.utf8) == Array("신한카드".utf8))
    }

    @Test func trimsAndDropsEmpty() {
        #expect(Text.normalize("  커피 \n") == "커피")
        #expect(Text.normalize("   ") == nil)
        #expect(Text.normalize(nil) == nil)
    }
}

@Suite struct RateTests {
    @Test(arguments: [
        ("1369.86", "1369.86"), ("01369.860", "1369.86"), ("100", "100"), ("100.000", "100"),
        ("0.0001", "0.0001"), (".5", nil), ("5.", nil), ("0", nil), ("0.000", nil), ("1e5", nil),
        ("-1", nil), ("1,000", nil),
    ] as [(String, String?)])
    func canonicalizes(_ input: String, _ expected: String?) {
        #expect(Rate(input)?.string == expected)
    }

    @Test func decimalValue() {
        #expect(Rate("1369.86")?.decimal == Decimal(string: "1369.86"))
    }
}

@Suite struct HLCTests {
    @Test func advancesMonotonically() {
        var clock = HybridLogicalClock()
        let a = clock.now(physicalMillis: 1_000)
        let b = clock.now(physicalMillis: 1_000)
        let c = clock.now(physicalMillis: 900)
        let d = clock.now(physicalMillis: 2_000)
        #expect(a < b && b < c && c < d)
        #expect(d == HLCTimestamp(millis: 2_000, counter: 0))
    }

    @Test func observedRemoteTimeIsExceeded() {
        var clock = HybridLogicalClock()
        let remote = HLCTimestamp(millis: 5_000, counter: 3)
        clock.observe(remote)
        #expect(clock.now(physicalMillis: 1_000) > remote)
    }

    @Test func textOrderMatchesTimeOrder() throws {
        let a = HLCTimestamp(millis: 999, counter: 12)
        let b = HLCTimestamp(millis: 1_759_032_753_123, counter: 3)
        #expect(a.description == "0000000000999-0012")
        #expect(a.description < b.description)
        #expect(HLCTimestamp(b.description) == b)
    }
}
