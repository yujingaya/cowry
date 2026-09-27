/// Read access to the current ledger state, implemented by the runtime's store. Authoring
/// validation and merge policies are written against this so they stay free of storage code.
package protocol LedgerStateReading {
    func commodity(_ id: Commodity.ID) throws -> Commodity?
    func commodities(code: String) throws -> [Commodity]
    func account(_ id: Account.ID) throws -> Account?
    func accounts(parent: Account.ID?) throws -> [Account]
    func entry(_ id: Entry.ID) throws -> Entry?
    func price(_ id: Price.ID) throws -> Price?
    func balanceAssertion(_ id: BalanceAssertion.ID) throws -> BalanceAssertion?
    /// Whether any posting (after resolving merges) hits the account, optionally only after `date`.
    func hasPostings(account: Account.ID, after date: LocalDate?) throws -> Bool
    func hasBalanceAssertions(account: Account.ID) throws -> Bool
    func opExists(_ id: Op.ID) throws -> Bool
}

extension LedgerStateReading {
    /// The account that postings to `id` end up in, following merges.
    package func resolvedAccount(_ id: Account.ID) throws -> Account? {
        var current = try account(id)
        var hops = 0
        while let account = current, let next = account.mergedInto, hops < 64 {
            current = try self.account(next)
            hops += 1
        }
        return current
    }

    /// Whether `candidate` is `account` itself or one of its descendants.
    package func isSelfOrDescendant(_ candidate: Account.ID, of account: Account.ID) throws -> Bool {
        var current: Account.ID? = candidate
        var hops = 0
        while let id = current, hops < 1024 {
            if id == account { return true }
            current = try self.account(id)?.parent
            hops += 1
        }
        return false
    }

    /// Live siblings under `parent`: not deleted, not merged away.
    package func liveChildren(of parent: Account.ID?) throws -> [Account] {
        try accounts(parent: parent).filter { !$0.deleted && $0.mergedInto == nil }
    }
}
