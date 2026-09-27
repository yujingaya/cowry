public enum AccountType: String, Codable, Sendable, CaseIterable {
    case asset, liability, equity, income, expense
}

public struct Account: Identifiable, Hashable, Sendable {
    public typealias ID = Identifier<Account>

    public enum Role: String, Codable, Sendable {
        case conversion
        case openingBalance = "opening_balance"
    }

    public let id: ID
    public let parent: ID?
    /// This account's own name ("Checking"), not its full path.
    public let name: String
    /// Fixed at creation; children always share their parent's type.
    public let type: AccountType
    public let role: Role?
    public let openedOn: LocalDate
    public let closedOn: LocalDate?
    public let archived: Bool
    /// Tombstone. Deleted accounts stay in the table so references always resolve.
    public let deleted: Bool
    /// Set when this account was merged into another; references follow it.
    public let mergedInto: ID?
    public let sortOrder: Int
    public let note: String?
    public let rev: Op.ID

    package init(
        id: ID, parent: ID?, name: String, type: AccountType, role: Role?, openedOn: LocalDate,
        closedOn: LocalDate?, archived: Bool, deleted: Bool, mergedInto: ID?, sortOrder: Int,
        note: String?, rev: Op.ID
    ) {
        self.id = id
        self.parent = parent
        self.name = name
        self.type = type
        self.role = role
        self.openedOn = openedOn
        self.closedOn = closedOn
        self.archived = archived
        self.deleted = deleted
        self.mergedInto = mergedInto
        self.sortOrder = sortOrder
        self.note = note
        self.rev = rev
    }

    /// Whether a posting dated `date` falls within the account's open period.
    public func isOpen(on date: LocalDate) -> Bool {
        openedOn <= date && closedOn.map { date <= $0 } ?? true
    }

    /// Whether the account can take new postings when authoring.
    public var isActive: Bool { !archived && !deleted && mergedInto == nil }
}

/// System accounts, created with deterministic IDs so every device agrees on them.
public enum SystemAccount {
    public static let conversion = Account.ID.named("system-account:conversion")
    public static let openingBalances = Account.ID.named("system-account:opening-balances")
}
