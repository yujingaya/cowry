import Foundation
import Testing
@testable import LedgerCore

@Suite struct OpCodecTests {
    static let krw = Commodity.ID.iso4217("KRW")
    static let usd = Commodity.ID.iso4217("USD")
    static let account = Account.ID.named("test:card")
    static let rev = Op.ID.named("test:rev")

    static let payloads: [OpPayload] = [
        .createCommodity(CreateCommodity(id: krw, code: "KRW", kind: .currency, scale: 0, name: "원")),
        .updateCommodity(UpdateCommodity(id: usd, baseRev: rev, name: "Dollar", quote: nil, feed: #"{"provider":"ecb"}"#)),
        .archiveCommodity(Revise(id: usd, baseRev: rev)),
        .openAccount(OpenAccount(id: account, parent: nil, name: "신한카드", type: .liability,
                                 openedOn: LocalDate("2026-01-01")!)),
        .updateAccount(UpdateAccount(id: account, baseRev: rev, parent: nil, name: "카드", sortOrder: 3, note: "메모")),
        .closeAccount(CloseAccount(id: account, baseRev: rev, date: LocalDate("2026-09-01")!)),
        .reopenAccount(Revise(id: account, baseRev: rev)),
        .archiveAccount(Revise(id: account, baseRev: rev)),
        .mergeAccounts(MergeAccounts(from: account, into: .named("test:other"))),
        .deleteAccount(Revise(id: account, baseRev: rev)),
        .postEntry(PostEntry(id: .named("test:entry"), date: LocalDate("2026-09-20")!, payee: "Apple Store",
                             memo: nil, postings: [
                                 Posting(account: account, commodity: krw, amount: -68_650),
                                 Posting(account: SystemAccount.conversion, commodity: krw, amount: 68_650),
                             ])),
        .amendEntry(AmendEntry(id: .named("test:entry"), baseRev: rev, date: LocalDate("2026-09-21")!,
                               payee: nil, memo: "수정", postings: [])),
        .voidEntry(Revise(id: .named("test:entry"), baseRev: rev)),
        .setPrice(SetPrice(id: .named("test:price"), base: usd, quote: krw, date: LocalDate("2026-09-20")!,
                           rate: Rate("1373.5")!)),
        .removePrice(Revise(id: .named("test:price"), baseRev: rev)),
        .assertBalance(AssertBalance(id: .named("test:assert"), account: account, commodity: krw,
                                     date: LocalDate("2026-10-01")!, amount: -68_650)),
        .removeAssertion(Revise(id: .named("test:assert"), baseRev: rev)),
        .setSetting(SetSetting(key: .primaryCommodity, value: krw.string)),
        .dismissConflict(DismissConflict(op: rev)),
    ]

    static func op(_ payload: OpPayload) -> Op {
        Op(id: .named("test:op"), device: .named("test:device"),
           at: HLCTimestamp(millis: 1_759_032_753_123, counter: 7), payload: payload)
    }

    @Test func coversEveryKind() {
        #expect(Set(Self.payloads.map(\.kind)) == Set(OpKind.allCases))
    }

    @Test(arguments: payloads)
    func roundTrips(_ payload: OpPayload) throws {
        let op = Self.op(payload)
        #expect(try OpCodec.decode(OpCodec.encode(op)) == op)
    }

    @Test func usesSnakeCaseAndPlainText() throws {
        let body = try OpCodec.encode(Self.op(Self.payloads[4]))
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""base_rev":"#))
        #expect(text.contains(#""sort_order":3"#))
        #expect(text.contains(#""kind":"update_account""#))
        #expect(text.contains("카드"))
    }

    @Test func largeAmountsSurviveExactly() throws {
        let amount = Int64.max - 12_345
        let payload = OpPayload.postEntry(PostEntry(
            id: .named("big"), date: LocalDate("2026-01-01")!, payee: nil, memo: nil,
            postings: [Posting(account: Self.account, commodity: Self.krw, amount: amount)]))
        let decoded = try OpCodec.decode(OpCodec.encode(Self.op(payload)))
        guard case .postEntry(let entry) = decoded.payload else { Issue.record("wrong kind"); return }
        #expect(entry.postings[0].amount == amount)
    }

    @Test func rejectsNewerVersion() throws {
        let body = #"{"v":2,"id":"\#(Op.ID.named("x").string)","device":"\#(DeviceID.named("d").string)","at":"0000000001000-0000","kind":"post_entry","payload":{}}"#
        #expect(throws: OpDecodingError.unsupportedVersion(2)) {
            try OpCodec.decode(Data(body.utf8))
        }
    }

    @Test func rejectsUnknownKind() throws {
        let body = #"{"v":1,"id":"\#(Op.ID.named("x").string)","device":"\#(DeviceID.named("d").string)","at":"0000000001000-0000","kind":"teleport","payload":{}}"#
        #expect(throws: OpDecodingError.unknownKind("teleport")) {
            try OpCodec.decode(Data(body.utf8))
        }
    }

    @Test func ignoresUnknownFields() throws {
        var object = try JSONSerialization.jsonObject(with: OpCodec.encode(Self.op(Self.payloads[0]))) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        payload["added_in_v2"] = "hello"
        object["payload"] = payload
        let body = try JSONSerialization.data(withJSONObject: object)
        #expect(try OpCodec.decode(body) == Self.op(Self.payloads[0]))
    }
}
