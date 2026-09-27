/// Builds op payloads from user commands: normalizes values, resolves merged accounts, generates
/// conversion postings, and enforces every authoring rule against the current state.
///
/// These rules are strict on purpose. Ops arriving from other devices are never checked against
/// them; conflicts there are resolved by merge policy instead.
package enum Authoring {
    // MARK: Commodities

    package static func createCommodity(
        id: Commodity.ID, code: String, kind: Commodity.Kind, scale: Int,
        name: String?, quote: Commodity.ID?, feed: String?,
        in state: some LedgerStateReading
    ) throws -> CreateCommodity {
        guard let code = Text.normalize(code) else { throw ValidationError.emptyName }
        guard Commodity.scaleRange.contains(scale) else { throw ValidationError.invalidScale(scale) }
        guard try state.commodity(id) == nil else { throw ValidationError.alreadyExists(id.string) }
        if let existing = try state.commodities(code: code).first(where: { !$0.archived }) {
            throw ValidationError.duplicateCode(existing.id)
        }
        if let quote { _ = try activeCommodity(quote, in: state) }
        return CreateCommodity(id: id, code: code, kind: kind, scale: scale,
                               name: Text.normalize(name), quote: quote, feed: Text.normalize(feed))
    }

    package static func updateCommodity(
        _ commodity: Commodity, name: String?, quote: Commodity.ID?, feed: String?,
        in state: some LedgerStateReading
    ) throws -> UpdateCommodity {
        let current = try existingCommodity(commodity.id, in: state)
        try requireFresh(commodity.rev, current.rev)
        if let quote {
            guard quote != current.id else { throw ValidationError.samePair }
            _ = try activeCommodity(quote, in: state)
        }
        return UpdateCommodity(id: current.id, baseRev: commodity.rev,
                               name: Text.normalize(name), quote: quote, feed: Text.normalize(feed))
    }

    package static func archiveCommodity(
        _ commodity: Commodity, in state: some LedgerStateReading
    ) throws -> Revise<Commodity> {
        let current = try existingCommodity(commodity.id, in: state)
        try requireFresh(commodity.rev, current.rev)
        return Revise(id: commodity.id, baseRev: commodity.rev)
    }

    // MARK: Accounts

    package static func openAccount(
        id: Account.ID, parent: Account.ID?, name: String, type: AccountType, openedOn: LocalDate,
        role: Account.Role? = nil,
        in state: some LedgerStateReading
    ) throws -> OpenAccount {
        guard let name = Text.normalize(name) else { throw ValidationError.emptyName }
        guard try state.account(id) == nil else { throw ValidationError.alreadyExists(id.string) }
        if let parent {
            let parentAccount = try activeAccount(parent, in: state)
            guard parentAccount.type == type else { throw ValidationError.typeMismatch(parent) }
        }
        try requireUniqueName(name, under: parent, excluding: nil, in: state)
        return OpenAccount(id: id, parent: parent, name: name, type: type, openedOn: openedOn, role: role)
    }

    package static func updateAccount(
        _ account: Account, parent: Account.ID?, name: String, sortOrder: Int, note: String?,
        in state: some LedgerStateReading
    ) throws -> UpdateAccount {
        let current = try existingAccount(account.id, in: state)
        try requireFresh(account.rev, current.rev)
        guard let name = Text.normalize(name) else { throw ValidationError.emptyName }
        if parent != current.parent {
            guard current.role == nil else { throw ValidationError.systemAccount(current.id) }
            if let parent {
                let parentAccount = try activeAccount(parent, in: state)
                guard parentAccount.type == current.type else { throw ValidationError.typeMismatch(parent) }
                guard try !state.isSelfOrDescendant(parent, of: current.id) else { throw ValidationError.cycle }
            }
        }
        try requireUniqueName(name, under: parent, excluding: current.id, in: state)
        return UpdateAccount(id: current.id, baseRev: account.rev, parent: parent, name: name,
                             sortOrder: sortOrder, note: Text.normalize(note))
    }

    package static func closeAccount(
        _ account: Account, on date: LocalDate, in state: some LedgerStateReading
    ) throws -> CloseAccount {
        let current = try userAccount(account.id, in: state)
        try requireFresh(account.rev, current.rev)
        guard date >= current.openedOn else { throw ValidationError.closeBeforeOpen(current.id) }
        guard try !state.hasPostings(account: current.id, after: date) else {
            throw ValidationError.postingsAfterClose(current.id, date)
        }
        return CloseAccount(id: current.id, baseRev: account.rev, date: date)
    }

    package static func reopenAccount(
        _ account: Account, in state: some LedgerStateReading
    ) throws -> Revise<Account> {
        let current = try userAccount(account.id, in: state)
        try requireFresh(account.rev, current.rev)
        guard current.closedOn != nil else { throw ValidationError.notClosed(current.id) }
        return Revise(id: current.id, baseRev: account.rev)
    }

    package static func archiveAccount(
        _ account: Account, in state: some LedgerStateReading
    ) throws -> Revise<Account> {
        let current = try userAccount(account.id, in: state)
        try requireFresh(account.rev, current.rev)
        return Revise(id: current.id, baseRev: account.rev)
    }

    package static func mergeAccounts(
        from: Account.ID, into: Account.ID, in state: some LedgerStateReading
    ) throws -> MergeAccounts {
        guard from != into else { throw ValidationError.mergeIntoSelf }
        let source = try userAccount(from, in: state)
        guard source.isActive else { throw ValidationError.inactiveAccount(from) }
        let target = try activeAccount(into, in: state)
        guard source.type == target.type else { throw ValidationError.typeMismatch(into) }
        guard try state.liveChildren(of: from).isEmpty else { throw ValidationError.hasChildren(from) }
        guard try !state.isSelfOrDescendant(into, of: from) else { throw ValidationError.cycle }
        return MergeAccounts(from: from, into: into)
    }

    package static func deleteAccount(
        _ account: Account, in state: some LedgerStateReading
    ) throws -> Revise<Account> {
        let current = try userAccount(account.id, in: state)
        try requireFresh(account.rev, current.rev)
        guard try state.liveChildren(of: current.id).isEmpty else { throw ValidationError.hasChildren(current.id) }
        guard try !state.hasPostings(account: current.id, after: nil) else { throw ValidationError.hasPostings(current.id) }
        guard try !state.hasBalanceAssertions(account: current.id) else {
            throw ValidationError.hasBalanceAssertions(current.id)
        }
        return Revise(id: current.id, baseRev: account.rev)
    }

    // MARK: Entries

    package static func postEntry(
        id: Entry.ID, _ draft: EntryDraft, in state: some LedgerStateReading
    ) throws -> PostEntry {
        guard try state.entry(id) == nil else { throw ValidationError.alreadyExists(id.string) }
        let postings = try finalPostings(draft, in: state)
        return PostEntry(id: id, date: draft.date, payee: Text.normalize(draft.payee),
                         memo: Text.normalize(draft.memo), postings: postings)
    }

    package static func amendEntry(
        _ entry: Entry, to draft: EntryDraft, in state: some LedgerStateReading
    ) throws -> AmendEntry {
        guard let current = try state.entry(entry.id) else { throw ValidationError.unknownEntry(entry.id) }
        try requireFresh(entry.rev, current.rev)
        let postings = try finalPostings(draft, in: state)
        return AmendEntry(id: entry.id, baseRev: entry.rev, date: draft.date,
                          payee: Text.normalize(draft.payee), memo: Text.normalize(draft.memo),
                          postings: postings)
    }

    package static func voidEntry(_ entry: Entry, in state: some LedgerStateReading) throws -> Revise<Entry> {
        guard let current = try state.entry(entry.id) else { throw ValidationError.unknownEntry(entry.id) }
        try requireFresh(entry.rev, current.rev)
        return Revise(id: entry.id, baseRev: entry.rev)
    }

    // MARK: Prices, assertions, settings

    package static func setPrice(
        id: Price.ID, base: Commodity.ID, quote: Commodity.ID, date: LocalDate, rate: Rate,
        in state: some LedgerStateReading
    ) throws -> SetPrice {
        guard base != quote else { throw ValidationError.samePair }
        _ = try existingCommodity(base, in: state)
        _ = try existingCommodity(quote, in: state)
        guard try state.price(id) == nil else { throw ValidationError.alreadyExists(id.string) }
        return SetPrice(id: id, base: base, quote: quote, date: date, rate: rate)
    }

    package static func removePrice(_ price: Price, in state: some LedgerStateReading) throws -> Revise<Price> {
        guard let current = try state.price(price.id) else { throw ValidationError.unknownPrice(price.id) }
        try requireFresh(price.rev, current.rev)
        return Revise(id: price.id, baseRev: price.rev)
    }

    package static func assertBalance(
        id: BalanceAssertion.ID, account: Account.ID, commodity: Commodity.ID, date: LocalDate, amount: Int64,
        in state: some LedgerStateReading
    ) throws -> AssertBalance {
        guard let resolved = try state.resolvedAccount(account) else { throw ValidationError.unknownAccount(account) }
        _ = try existingCommodity(commodity, in: state)
        guard try state.balanceAssertion(id) == nil else { throw ValidationError.alreadyExists(id.string) }
        return AssertBalance(id: id, account: resolved.id, commodity: commodity, date: date, amount: amount)
    }

    package static func removeAssertion(
        _ assertion: BalanceAssertion, in state: some LedgerStateReading
    ) throws -> Revise<BalanceAssertion> {
        guard let current = try state.balanceAssertion(assertion.id) else {
            throw ValidationError.unknownBalanceAssertion(assertion.id)
        }
        try requireFresh(assertion.rev, current.rev)
        return Revise(id: assertion.id, baseRev: assertion.rev)
    }

    package static func setSetting(
        _ key: SettingKey, _ value: String, in state: some LedgerStateReading
    ) throws -> SetSetting {
        if key == .primaryCommodity {
            guard let id = Commodity.ID(value), try state.commodity(id) != nil else {
                throw ValidationError.invalidSettingValue(key)
            }
            return SetSetting(key: key, value: id.string)
        }
        return SetSetting(key: key, value: value)
    }

    package static func dismissConflict(_ op: Op.ID, in state: some LedgerStateReading) throws -> DismissConflict {
        guard try state.opExists(op) else { throw ValidationError.unknownOp(op) }
        return DismissConflict(op: op)
    }

    // MARK: Helpers

    /// Refuses edits made from an outdated copy. Locally that means another window or command
    /// changed the record first; the UI reloads and the user edits again.
    private static func requireFresh(_ edited: Op.ID, _ current: Op.ID) throws {
        guard edited == current else { throw ValidationError.staleRevision(current: current) }
    }

    /// Balances the draft, then checks every posting's account and commodity. Postings to
    /// merged accounts are redirected to where they were merged.
    private static func finalPostings(
        _ draft: EntryDraft, in state: some LedgerStateReading
    ) throws -> [Posting] {
        var resolved: [Posting] = []
        for posting in draft.postings where posting.account != SystemAccount.conversion {
            guard let account = try state.resolvedAccount(posting.account) else {
                throw ValidationError.unknownAccount(posting.account)
            }
            guard !account.archived, !account.deleted else { throw ValidationError.inactiveAccount(account.id) }
            guard account.isOpen(on: draft.date) else { throw ValidationError.accountNotOpen(account.id, on: draft.date) }
            _ = try activeCommodity(posting.commodity, in: state)
            resolved.append(Posting(account: account.id, commodity: posting.commodity, amount: posting.amount))
        }
        return try Balancing.balance(resolved)
    }

    private static func requireUniqueName(
        _ name: String, under parent: Account.ID?, excluding id: Account.ID?, in state: some LedgerStateReading
    ) throws {
        if let sibling = try state.liveChildren(of: parent).first(where: { $0.name == name && $0.id != id }) {
            throw ValidationError.duplicateName(sibling: sibling.id)
        }
    }

    private static func existingCommodity(_ id: Commodity.ID, in state: some LedgerStateReading) throws -> Commodity {
        guard let commodity = try state.commodity(id) else { throw ValidationError.unknownCommodity(id) }
        return commodity
    }

    private static func activeCommodity(_ id: Commodity.ID, in state: some LedgerStateReading) throws -> Commodity {
        let commodity = try existingCommodity(id, in: state)
        guard !commodity.archived else { throw ValidationError.inactiveCommodity(id) }
        return commodity
    }

    private static func existingAccount(_ id: Account.ID, in state: some LedgerStateReading) throws -> Account {
        guard let account = try state.account(id), !account.deleted else { throw ValidationError.unknownAccount(id) }
        return account
    }

    private static func activeAccount(_ id: Account.ID, in state: some LedgerStateReading) throws -> Account {
        let account = try existingAccount(id, in: state)
        guard account.isActive else { throw ValidationError.inactiveAccount(id) }
        return account
    }

    /// An existing account that isn't a system account.
    private static func userAccount(_ id: Account.ID, in state: some LedgerStateReading) throws -> Account {
        let account = try existingAccount(id, in: state)
        guard account.role == nil else { throw ValidationError.systemAccount(id) }
        return account
    }
}
