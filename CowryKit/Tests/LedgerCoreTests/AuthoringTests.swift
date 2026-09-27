import Testing
@testable import LedgerCore

/// In-memory ledger state for exercising authoring rules without a database.
final class FakeState: LedgerStateReading {
    var commodityRecords: [Commodity.ID: Commodity] = [:]
    var accountRecords: [Account.ID: Account] = [:]
    var entryRecords: [Entry.ID: Entry] = [:]
    var priceRecords: [Price.ID: Price] = [:]
    var assertionRecords: [BalanceAssertion.ID: BalanceAssertion] = [:]
    var ops: Set<Op.ID> = []

    static let rev = Op.ID.named("fake:rev")
    static let krw = Commodity.ID.iso4217("KRW")
    static let usd = Commodity.ID.iso4217("USD")

    init() {
        addCommodity(Self.krw, "KRW", scale: 0)
        addCommodity(Self.usd, "USD", scale: 2)
        addAccount(SystemAccount.conversion, "Conversion", .equity, role: .conversion)
        addAccount(SystemAccount.openingBalances, "Opening Balances", .equity, role: .openingBalance)
    }

    func addCommodity(_ id: Commodity.ID, _ code: String, scale: Int, archived: Bool = false) {
        commodityRecords[id] = Commodity(id: id, code: code, kind: .currency, scale: scale, name: nil,
                                         quote: nil, feed: nil, archived: archived, rev: Self.rev)
    }

    @discardableResult
    func addAccount(
        _ id: Account.ID, _ name: String, _ type: AccountType, parent: Account.ID? = nil,
        role: Account.Role? = nil, openedOn: String = "2020-01-01", closedOn: String? = nil,
        archived: Bool = false, deleted: Bool = false, mergedInto: Account.ID? = nil
    ) -> Account {
        let account = Account(
            id: id, parent: parent, name: name, type: type, role: role, openedOn: LocalDate(openedOn)!,
            closedOn: closedOn.flatMap { LocalDate($0) }, archived: archived, deleted: deleted,
            mergedInto: mergedInto, sortOrder: 0, note: nil, rev: Self.rev)
        accountRecords[id] = account
        return account
    }

    func addEntry(_ id: Entry.ID, date: String, postings: [Posting]) -> Entry {
        let entry = Entry(id: id, date: LocalDate(date)!, createdAt: .zero, payee: nil, memo: nil,
                          postings: postings, rev: Self.rev)
        entryRecords[id] = entry
        return entry
    }

    func commodity(_ id: Commodity.ID) -> Commodity? { commodityRecords[id] }
    func commodities(code: String) -> [Commodity] { commodityRecords.values.filter { $0.code == code } }
    func account(_ id: Account.ID) -> Account? { accountRecords[id] }
    func accounts(parent: Account.ID?) -> [Account] { accountRecords.values.filter { $0.parent == parent } }
    func entry(_ id: Entry.ID) -> Entry? { entryRecords[id] }
    func price(_ id: Price.ID) -> Price? { priceRecords[id] }
    func balanceAssertion(_ id: BalanceAssertion.ID) -> BalanceAssertion? { assertionRecords[id] }
    func opExists(_ id: Op.ID) -> Bool { ops.contains(id) }

    func hasPostings(account: Account.ID, after date: LocalDate?) -> Bool {
        entryRecords.values.contains { entry in
            (date.map { entry.date > $0 } ?? true)
                && entry.postings.contains { (try? resolvedAccount($0.account))??.id == account }
        }
    }

    func hasBalanceAssertions(account: Account.ID) -> Bool {
        assertionRecords.values.contains { $0.account == account }
    }
}

@Suite struct EntryAuthoringTests {
    let state = FakeState()
    let shopping = Account.ID.named("test:shopping")
    let card = Account.ID.named("test:card")
    let date = LocalDate("2026-09-20")!

    init() {
        state.addAccount(shopping, "쇼핑", .expense)
        state.addAccount(card, "신한카드", .liability)
    }

    func draft(_ postings: [Posting], payee: String? = nil) -> EntryDraft {
        EntryDraft(date: date, payee: payee, postings: postings)
    }

    @Test func postsBalancedEntryWithNormalizedText() throws {
        let payload = try Authoring.postEntry(id: .named("e"), draft([
            Posting(account: shopping, commodity: FakeState.krw, amount: 4_500),
            Posting(account: card, commodity: FakeState.krw, amount: -4_500),
        ], payee: "  스타벅스 ".decomposedStringWithCanonicalMapping), in: state)
        #expect(payload.payee == "스타벅스")
        #expect(payload.memo == nil)
        #expect(payload.postings.count == 2)
    }

    @Test func generatesConversionPostings() throws {
        let payload = try Authoring.postEntry(id: .named("e"), draft([
            Posting(account: shopping, commodity: FakeState.usd, amount: 5_000),
            Posting(account: card, commodity: FakeState.krw, amount: -68_650),
        ]), in: state)
        #expect(payload.postings.count == 4)
        #expect(Balancing.isBalanced(payload.postings))
    }

    @Test func redirectsMergedAccounts() throws {
        let old = Account.ID.named("test:old-card")
        state.addAccount(old, "구 카드", .liability, mergedInto: card)
        let payload = try Authoring.postEntry(id: .named("e"), draft([
            Posting(account: shopping, commodity: FakeState.krw, amount: 1_000),
            Posting(account: old, commodity: FakeState.krw, amount: -1_000),
        ]), in: state)
        #expect(payload.postings[1].account == card)
    }

    @Test func refusesClosedArchivedAndUnknownAccounts() {
        let closed = Account.ID.named("closed"), archived = Account.ID.named("archived")
        state.addAccount(closed, "closed", .liability, closedOn: "2026-09-01")
        state.addAccount(archived, "archived", .liability, archived: true)
        func post(via account: Account.ID) throws {
            _ = try Authoring.postEntry(id: .named("e"), draft([
                Posting(account: shopping, commodity: FakeState.krw, amount: 1_000),
                Posting(account: account, commodity: FakeState.krw, amount: -1_000),
            ]), in: state)
        }
        #expect(throws: ValidationError.accountNotOpen(closed, on: date)) { try post(via: closed) }
        #expect(throws: ValidationError.inactiveAccount(archived)) { try post(via: archived) }
        #expect(throws: ValidationError.unknownAccount(.named("nope"))) { try post(via: .named("nope")) }
    }

    @Test func refusesArchivedCommodity() {
        let old = Commodity.ID.iso4217("DEM")
        state.addCommodity(old, "DEM", scale: 2, archived: true)
        #expect(throws: ValidationError.inactiveCommodity(old)) {
            _ = try Authoring.postEntry(id: .named("e"), draft([
                Posting(account: shopping, commodity: old, amount: 1),
                Posting(account: card, commodity: old, amount: -1),
            ]), in: state)
        }
    }

    @Test func amendCarriesTheRevisionItWasEditedFrom() throws {
        let entry = state.addEntry(.named("e"), date: "2026-09-20", postings: [
            Posting(account: shopping, commodity: FakeState.krw, amount: 1_000),
            Posting(account: card, commodity: FakeState.krw, amount: -1_000),
        ])
        var edited = EntryDraft(entry)
        edited.memo = "점심"
        let payload = try Authoring.amendEntry(entry, to: edited, in: state)
        #expect(payload.baseRev == entry.rev)
        #expect(payload.memo == "점심")
    }
}

@Suite struct AccountAuthoringTests {
    let state = FakeState()
    let assets = Account.ID.named("test:assets")
    let bank = Account.ID.named("test:bank")
    let date = LocalDate("2026-01-01")!

    init() {
        state.addAccount(assets, "자산", .asset)
        state.addAccount(bank, "은행", .asset, parent: assets)
    }

    @Test func opensUnderMatchingParent() throws {
        let payload = try Authoring.openAccount(id: .named("new"), parent: bank, name: " 신한 ", type: .asset,
                                                openedOn: date, in: state)
        #expect(payload.name == "신한")
        #expect(throws: ValidationError.typeMismatch(bank)) {
            _ = try Authoring.openAccount(id: .named("new"), parent: bank, name: "x", type: .expense,
                                          openedOn: date, in: state)
        }
    }

    @Test func refusesDuplicateSiblingNamesAcrossUnicodeForms() {
        #expect(throws: ValidationError.duplicateName(sibling: bank)) {
            _ = try Authoring.openAccount(id: .named("new"), parent: assets,
                                          name: "은행".decomposedStringWithCanonicalMapping,
                                          type: .asset, openedOn: date, in: state)
        }
    }

    @Test func refusesCycles() {
        let account = state.accountRecords[assets]!
        #expect(throws: ValidationError.cycle) {
            _ = try Authoring.updateAccount(account, parent: bank, name: "자산", sortOrder: 0, note: nil, in: state)
        }
    }

    @Test func protectsSystemAccounts() {
        let conversion = state.accountRecords[SystemAccount.conversion]!
        #expect(throws: ValidationError.systemAccount(SystemAccount.conversion)) {
            _ = try Authoring.deleteAccount(conversion, in: state)
        }
        #expect(throws: ValidationError.systemAccount(SystemAccount.conversion)) {
            _ = try Authoring.closeAccount(conversion, on: date, in: state)
        }
    }

    @Test func closeRefusesLaterPostings() throws {
        let card = Account.ID.named("card")
        let account = state.addAccount(card, "카드", .asset)
        _ = state.addEntry(.named("e"), date: "2026-09-15", postings: [
            Posting(account: card, commodity: FakeState.krw, amount: 1),
            Posting(account: bank, commodity: FakeState.krw, amount: -1),
        ])
        let september = LocalDate("2026-09-01")!
        #expect(throws: ValidationError.postingsAfterClose(card, september)) {
            _ = try Authoring.closeAccount(account, on: september, in: state)
        }
        _ = try Authoring.closeAccount(account, on: LocalDate("2026-09-15")!, in: state)
    }

    @Test func deleteRequiresAnUnusedLeaf() throws {
        let parent = state.accountRecords[assets]!
        #expect(throws: ValidationError.hasChildren(assets)) {
            _ = try Authoring.deleteAccount(parent, in: state)
        }
        _ = try Authoring.deleteAccount(state.accountRecords[bank]!, in: state)
    }

    @Test func mergeRules() throws {
        let other = Account.ID.named("other")
        state.addAccount(other, "다른 은행", .asset, parent: assets)
        #expect(throws: ValidationError.mergeIntoSelf) {
            _ = try Authoring.mergeAccounts(from: bank, into: bank, in: state)
        }
        #expect(throws: ValidationError.hasChildren(assets)) {
            _ = try Authoring.mergeAccounts(from: assets, into: other, in: state)
        }
        #expect(try Authoring.mergeAccounts(from: bank, into: other, in: state) == MergeAccounts(from: bank, into: other))
    }
}

@Suite struct OtherAuthoringTests {
    let state = FakeState()

    @Test func commodityCodesAreUniqueAndScalesBounded() {
        #expect(throws: ValidationError.duplicateCode(FakeState.krw)) {
            _ = try Authoring.createCommodity(id: .named("x"), code: "KRW", kind: .currency, scale: 0,
                                              name: nil, quote: nil, feed: nil, in: state)
        }
        #expect(throws: ValidationError.invalidScale(19)) {
            _ = try Authoring.createCommodity(id: .named("x"), code: "ETH", kind: .crypto, scale: 19,
                                              name: nil, quote: nil, feed: nil, in: state)
        }
    }

    @Test func primaryCommodityMustExist() throws {
        #expect(throws: ValidationError.invalidSettingValue(.primaryCommodity)) {
            _ = try Authoring.setSetting(.primaryCommodity, "not-a-uuid", in: state)
        }
        let payload = try Authoring.setSetting(.primaryCommodity, FakeState.krw.string.uppercased(), in: state)
        #expect(payload.value == FakeState.krw.string)
    }

    @Test func pricesNeedTwoDifferentCommodities() {
        #expect(throws: ValidationError.samePair) {
            _ = try Authoring.setPrice(id: .named("p"), base: FakeState.usd, quote: FakeState.usd,
                                       date: LocalDate("2026-01-01")!, rate: Rate("1")!, in: state)
        }
    }
}
