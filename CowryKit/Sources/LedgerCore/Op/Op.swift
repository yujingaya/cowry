/// An immutable record of one change to the ledger. The op log is the ledger's source of truth;
/// every table is the result of replaying it.
public struct Op: Identifiable, Hashable, Sendable {
    public typealias ID = Identifier<Op>

    /// Format version written by this build. Ops with a higher version can't be applied.
    public static let currentVersion = 1

    public let version: Int
    public let id: ID
    public let device: DeviceID
    /// Hybrid logical time of authoring. Decides "the later edit" in merges; never orders the log.
    public let at: HLCTimestamp
    public let payload: OpPayload

    public init(version: Int = Op.currentVersion, id: ID, device: DeviceID, at: HLCTimestamp, payload: OpPayload) {
        self.version = version
        self.id = id
        self.device = device
        self.at = at
        self.payload = payload
    }

    public var kind: OpKind { payload.kind }
}

public enum OpKind: String, Codable, Sendable, CaseIterable {
    case createCommodity = "create_commodity"
    case updateCommodity = "update_commodity"
    case archiveCommodity = "archive_commodity"
    case openAccount = "open_account"
    case updateAccount = "update_account"
    case closeAccount = "close_account"
    case reopenAccount = "reopen_account"
    case archiveAccount = "archive_account"
    case mergeAccounts = "merge_accounts"
    case deleteAccount = "delete_account"
    case postEntry = "post_entry"
    case amendEntry = "amend_entry"
    case voidEntry = "void_entry"
    case setPrice = "set_price"
    case removePrice = "remove_price"
    case assertBalance = "assert_balance"
    case removeAssertion = "remove_assertion"
    case setSetting = "set_setting"
    case dismissConflict = "dismiss_conflict"
}

public enum OpPayload: Hashable, Sendable {
    case createCommodity(CreateCommodity)
    case updateCommodity(UpdateCommodity)
    case archiveCommodity(Revise<Commodity>)
    case openAccount(OpenAccount)
    case updateAccount(UpdateAccount)
    case closeAccount(CloseAccount)
    case reopenAccount(Revise<Account>)
    case archiveAccount(Revise<Account>)
    case mergeAccounts(MergeAccounts)
    case deleteAccount(Revise<Account>)
    case postEntry(PostEntry)
    case amendEntry(AmendEntry)
    case voidEntry(Revise<Entry>)
    case setPrice(SetPrice)
    case removePrice(Revise<Price>)
    case assertBalance(AssertBalance)
    case removeAssertion(Revise<BalanceAssertion>)
    case setSetting(SetSetting)
    case dismissConflict(DismissConflict)

    public var kind: OpKind {
        switch self {
        case .createCommodity: .createCommodity
        case .updateCommodity: .updateCommodity
        case .archiveCommodity: .archiveCommodity
        case .openAccount: .openAccount
        case .updateAccount: .updateAccount
        case .closeAccount: .closeAccount
        case .reopenAccount: .reopenAccount
        case .archiveAccount: .archiveAccount
        case .mergeAccounts: .mergeAccounts
        case .deleteAccount: .deleteAccount
        case .postEntry: .postEntry
        case .amendEntry: .amendEntry
        case .voidEntry: .voidEntry
        case .setPrice: .setPrice
        case .removePrice: .removePrice
        case .assertBalance: .assertBalance
        case .removeAssertion: .removeAssertion
        case .setSetting: .setSetting
        case .dismissConflict: .dismissConflict
        }
    }

    /// The entity this op changes, as stored in the op table's `target` column. Folding all ops
    /// with the same target reconstructs that entity's history.
    public var target: String {
        switch self {
        case .createCommodity(let p): p.id.string
        case .updateCommodity(let p): p.id.string
        case .archiveCommodity(let p): p.id.string
        case .openAccount(let p): p.id.string
        case .updateAccount(let p): p.id.string
        case .closeAccount(let p): p.id.string
        case .reopenAccount(let p): p.id.string
        case .archiveAccount(let p): p.id.string
        case .mergeAccounts(let p): p.from.string
        case .deleteAccount(let p): p.id.string
        case .postEntry(let p): p.id.string
        case .amendEntry(let p): p.id.string
        case .voidEntry(let p): p.id.string
        case .setPrice(let p): p.id.string
        case .removePrice(let p): p.id.string
        case .assertBalance(let p): p.id.string
        case .removeAssertion(let p): p.id.string
        case .setSetting(let p): "setting:\(p.key.rawValue)"
        case .dismissConflict(let p): p.op.string
        }
    }
}

// MARK: - Payloads

public struct CreateCommodity: Codable, Hashable, Sendable {
    public var id: Commodity.ID
    public var code: String
    public var kind: Commodity.Kind
    public var scale: Int
    public var name: String?
    public var quote: Commodity.ID?
    public var feed: String?

    public init(id: Commodity.ID, code: String, kind: Commodity.Kind, scale: Int,
                name: String? = nil, quote: Commodity.ID? = nil, feed: String? = nil) {
        self.id = id
        self.code = code
        self.kind = kind
        self.scale = scale
        self.name = name
        self.quote = quote
        self.feed = feed
    }
}

/// Replaces all mutable fields of a commodity. Code and scale can't change.
public struct UpdateCommodity: Codable, Hashable, Sendable {
    public var id: Commodity.ID
    public var baseRev: Op.ID
    public var name: String?
    public var quote: Commodity.ID?
    public var feed: String?

    public init(id: Commodity.ID, baseRev: Op.ID, name: String?, quote: Commodity.ID?, feed: String?) {
        self.id = id
        self.baseRev = baseRev
        self.name = name
        self.quote = quote
        self.feed = feed
    }
}

public struct OpenAccount: Codable, Hashable, Sendable {
    public var id: Account.ID
    public var parent: Account.ID?
    public var name: String
    public var type: AccountType
    public var openedOn: LocalDate
    public var role: Account.Role?

    public init(id: Account.ID, parent: Account.ID?, name: String, type: AccountType,
                openedOn: LocalDate, role: Account.Role? = nil) {
        self.id = id
        self.parent = parent
        self.name = name
        self.type = type
        self.openedOn = openedOn
        self.role = role
    }
}

/// Replaces all mutable fields of an account. Type and role can't change.
public struct UpdateAccount: Codable, Hashable, Sendable {
    public var id: Account.ID
    public var baseRev: Op.ID
    public var parent: Account.ID?
    public var name: String
    public var sortOrder: Int
    public var note: String?

    public init(id: Account.ID, baseRev: Op.ID, parent: Account.ID?, name: String, sortOrder: Int, note: String?) {
        self.id = id
        self.baseRev = baseRev
        self.parent = parent
        self.name = name
        self.sortOrder = sortOrder
        self.note = note
    }
}

public struct CloseAccount: Codable, Hashable, Sendable {
    public var id: Account.ID
    public var baseRev: Op.ID
    public var date: LocalDate

    public init(id: Account.ID, baseRev: Op.ID, date: LocalDate) {
        self.id = id
        self.baseRev = baseRev
        self.date = date
    }
}

public struct MergeAccounts: Codable, Hashable, Sendable {
    public var from: Account.ID
    public var into: Account.ID

    public init(from: Account.ID, into: Account.ID) {
        self.from = from
        self.into = into
    }
}

/// An op that only names its target and the revision it was authored against.
public struct Revise<Tag>: Codable, Hashable, Sendable {
    public var id: Identifier<Tag>
    public var baseRev: Op.ID

    public init(id: Identifier<Tag>, baseRev: Op.ID) {
        self.id = id
        self.baseRev = baseRev
    }
}

public struct PostEntry: Codable, Hashable, Sendable {
    public var id: Entry.ID
    public var date: LocalDate
    public var payee: String?
    public var memo: String?
    /// Final, balanced postings (conversion postings included).
    public var postings: [Posting]

    public init(id: Entry.ID, date: LocalDate, payee: String?, memo: String?, postings: [Posting]) {
        self.id = id
        self.date = date
        self.payee = payee
        self.memo = memo
        self.postings = postings
    }
}

/// Replaces an entry's whole content.
public struct AmendEntry: Codable, Hashable, Sendable {
    public var id: Entry.ID
    public var baseRev: Op.ID
    public var date: LocalDate
    public var payee: String?
    public var memo: String?
    public var postings: [Posting]

    public init(id: Entry.ID, baseRev: Op.ID, date: LocalDate, payee: String?, memo: String?, postings: [Posting]) {
        self.id = id
        self.baseRev = baseRev
        self.date = date
        self.payee = payee
        self.memo = memo
        self.postings = postings
    }
}

public struct SetPrice: Codable, Hashable, Sendable {
    public var id: Price.ID
    public var base: Commodity.ID
    public var quote: Commodity.ID
    public var date: LocalDate
    public var rate: Rate

    public init(id: Price.ID, base: Commodity.ID, quote: Commodity.ID, date: LocalDate, rate: Rate) {
        self.id = id
        self.base = base
        self.quote = quote
        self.date = date
        self.rate = rate
    }
}

public struct AssertBalance: Codable, Hashable, Sendable {
    public var id: BalanceAssertion.ID
    public var account: Account.ID
    public var commodity: Commodity.ID
    public var date: LocalDate
    public var amount: Int64

    public init(id: BalanceAssertion.ID, account: Account.ID, commodity: Commodity.ID, date: LocalDate, amount: Int64) {
        self.id = id
        self.account = account
        self.commodity = commodity
        self.date = date
        self.amount = amount
    }
}

public struct SetSetting: Codable, Hashable, Sendable {
    public var key: SettingKey
    public var value: String

    public init(key: SettingKey, value: String) {
        self.key = key
        self.value = value
    }
}

public struct DismissConflict: Codable, Hashable, Sendable {
    public var op: Op.ID

    public init(op: Op.ID) {
        self.op = op
    }
}
