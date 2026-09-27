/// One leg of an entry. Debit is positive, credit is negative; `amount` is in the commodity's
/// minor unit.
public struct Posting: Hashable, Sendable, Codable {
    public var account: Account.ID
    public var commodity: Commodity.ID
    public var amount: Int64

    public init(account: Account.ID, commodity: Commodity.ID, amount: Int64) {
        self.account = account
        self.commodity = commodity
        self.amount = amount
    }
}

/// A balanced journal entry. Only the runtime can construct one, after validation, so an
/// unbalanced entry can't exist anywhere in the app.
public struct Entry: Identifiable, Hashable, Sendable {
    public typealias ID = Identifier<Entry>

    public let id: ID
    public let date: LocalDate
    /// When the entry was first posted; orders entries within a day.
    public let createdAt: HLCTimestamp
    public let payee: String?
    public let memo: String?
    /// Final postings, including generated conversion postings.
    public let postings: [Posting]
    public let rev: Op.ID

    package init(
        id: ID, date: LocalDate, createdAt: HLCTimestamp, payee: String?, memo: String?,
        postings: [Posting], rev: Op.ID
    ) {
        self.id = id
        self.date = date
        self.createdAt = createdAt
        self.payee = payee
        self.memo = memo
        self.postings = postings
        self.rev = rev
    }

    /// Postings a user sees and edits; conversion postings are implied by these.
    public var userPostings: [Posting] {
        postings.filter { $0.account != SystemAccount.conversion }
    }
}

/// What the UI builds and hands to the runtime. It may be unbalanced across commodities (the
/// runtime adds conversion postings) but must balance within a single commodity.
public struct EntryDraft: Hashable, Sendable {
    public var date: LocalDate
    public var payee: String?
    public var memo: String?
    public var postings: [Posting]

    public init(date: LocalDate, payee: String? = nil, memo: String? = nil, postings: [Posting]) {
        self.date = date
        self.payee = payee
        self.memo = memo
        self.postings = postings
    }

    public init(_ entry: Entry) {
        self.init(date: entry.date, payee: entry.payee, memo: entry.memo, postings: entry.userPostings)
    }
}
