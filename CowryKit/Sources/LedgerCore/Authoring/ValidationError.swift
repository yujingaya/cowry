/// Why a command was refused when authoring an op locally. Merging never refuses; see the design
/// doc §6.3.
public enum ValidationError: Error, Hashable, Sendable {
    // Entries
    case noPostings
    case zeroAmount(posting: Int)
    case unbalanced(Commodity.ID, residual: Int64)
    case amountOverflow
    case accountNotOpen(Account.ID, on: LocalDate)

    // References
    case unknownCommodity(Commodity.ID)
    case unknownAccount(Account.ID)
    case unknownEntry(Entry.ID)
    case unknownPrice(Price.ID)
    case unknownBalanceAssertion(BalanceAssertion.ID)
    case unknownOp(Op.ID)
    case inactiveCommodity(Commodity.ID)
    case inactiveAccount(Account.ID)
    /// The record changed since the copy being edited was read.
    case staleRevision(current: Op.ID)

    // Identity and naming
    case alreadyExists(String)
    case emptyName
    case duplicateCode(Commodity.ID)
    case duplicateName(sibling: Account.ID)
    case invalidScale(Int)

    // Account structure
    case typeMismatch(Account.ID)
    case cycle
    case systemAccount(Account.ID)
    case hasChildren(Account.ID)
    case hasPostings(Account.ID)
    case hasBalanceAssertions(Account.ID)
    case postingsAfterClose(Account.ID, LocalDate)
    case closeBeforeOpen(Account.ID)
    case notClosed(Account.ID)
    case mergeIntoSelf

    // Prices and settings
    case samePair
    case invalidSettingValue(SettingKey)
}
