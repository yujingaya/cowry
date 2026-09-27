import Testing
@testable import LedgerCore

@Suite struct BalancingTests {
    let krw = Commodity.ID.iso4217("KRW")
    let usd = Commodity.ID.iso4217("USD")
    let shopping = Account.ID.named("test:shopping")
    let card = Account.ID.named("test:card")

    @Test func singleCommodityPassesThrough() throws {
        let postings = [
            Posting(account: shopping, commodity: krw, amount: 4_500),
            Posting(account: card, commodity: krw, amount: -4_500),
        ]
        #expect(try Balancing.balance(postings) == postings)
    }

    @Test func singleCommodityImbalanceIsAnError() {
        #expect(throws: ValidationError.unbalanced(krw, residual: 500)) {
            try Balancing.balance([
                Posting(account: shopping, commodity: krw, amount: 5_000),
                Posting(account: card, commodity: krw, amount: -4_500),
            ])
        }
    }

    @Test func mixedCommoditiesGetConversionPostings() throws {
        let draft = [
            Posting(account: shopping, commodity: usd, amount: 5_000),
            Posting(account: card, commodity: krw, amount: -68_650),
        ]
        let result = try Balancing.balance(draft)
        #expect(result == draft + [
            Posting(account: SystemAccount.conversion, commodity: usd, amount: -5_000),
            Posting(account: SystemAccount.conversion, commodity: krw, amount: 68_650),
        ])
        #expect(Balancing.isBalanced(result))
    }

    @Test func staleConversionPostingsAreRegenerated() throws {
        // An amended draft that still carries the old conversion postings.
        let draft = [
            Posting(account: shopping, commodity: usd, amount: 5_000),
            Posting(account: card, commodity: krw, amount: -70_000),
            Posting(account: SystemAccount.conversion, commodity: usd, amount: -5_000),
            Posting(account: SystemAccount.conversion, commodity: krw, amount: 68_650),
        ]
        let result = try Balancing.balance(draft)
        #expect(result.filter { $0.account == SystemAccount.conversion }.map(\.amount) == [-5_000, 70_000])
    }

    @Test func rejectsZeroAndEmpty() {
        #expect(throws: ValidationError.noPostings) { try Balancing.balance([]) }
        #expect(throws: ValidationError.zeroAmount(posting: 1)) {
            try Balancing.balance([
                Posting(account: shopping, commodity: krw, amount: 1),
                Posting(account: card, commodity: krw, amount: 0),
            ])
        }
    }

    @Test func detectsOverflow() {
        #expect(throws: ValidationError.amountOverflow) {
            try Balancing.balance([
                Posting(account: shopping, commodity: krw, amount: .max),
                Posting(account: shopping, commodity: krw, amount: 1),
            ])
        }
    }

    @Test func isBalancedNeedsTwoPostings() {
        #expect(!Balancing.isBalanced([]))
        #expect(!Balancing.isBalanced([Posting(account: card, commodity: krw, amount: 0)]))
    }
}
