import LedgerCore

/// Sort key of an entry in any journal-like list: by date, then by when it was posted.
public struct JournalKey: Hashable, Comparable, Sendable {
    public let date: LocalDate
    public let createdAt: HLCTimestamp
    public let id: Entry.ID

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.date, lhs.createdAt) < (rhs.date, rhs.createdAt)
            || ((lhs.date, lhs.createdAt) == (rhs.date, rhs.createdAt) && lhs.id < rhs.id)
    }
}

/// The ordered keys of a journal view. Holds only keys (about 40 bytes each), so the whole ledger
/// fits comfortably; rows are fetched on demand for what's on screen.
public struct JournalIndex: Sendable, RandomAccessCollection {
    public private(set) var keys: [JournalKey]

    public init(keys: [JournalKey]) {
        self.keys = keys
    }

    public var startIndex: Int { keys.startIndex }
    public var endIndex: Int { keys.endIndex }
    public subscript(position: Int) -> JournalKey { keys[position] }

    /// Position of `key`, or where it would be inserted.
    public func insertionIndex(of key: JournalKey) -> Int {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    public func index(of key: JournalKey) -> Int? {
        let index = insertionIndex(of: key)
        return index < keys.count && keys[index] == key ? index : nil
    }
}

public struct JournalFilter: Hashable, Sendable {
    /// Entries with a posting landing in any of these accounts. Nil means all entries.
    public var accounts: Set<Account.ID>?
    public var dates: ClosedRange<LocalDate>?
    /// Substring of payee or memo.
    public var text: String?

    public init(accounts: Set<Account.ID>? = nil, dates: ClosedRange<LocalDate>? = nil, text: String? = nil) {
        self.accounts = accounts
        self.dates = dates
        self.text = text
    }

    public static let all = JournalFilter()
}

/// One entry's effect on one account.
public struct RegisterRow: Hashable, Sendable {
    public let key: JournalKey
    /// Net amount this entry moved in the account, per commodity.
    public let amounts: Holdings
    /// Balance after this entry, per commodity.
    public let balance: Holdings
}

public struct Register: Sendable {
    public let accounts: Set<Account.ID>
    public let rows: [RegisterRow]
}

/// Accounts arranged as a tree. Merged-away and deleted accounts are kept for lookups but left
/// out of `roots` and `children`.
public struct AccountTree: Sendable {
    public let accounts: [Account.ID: Account]
    public let roots: [Account.ID]
    private let childMap: [Account.ID: [Account.ID]]

    init(_ all: [Account]) {
        var accounts: [Account.ID: Account] = [:]
        for account in all { accounts[account.id] = account }
        let live = all.filter { !$0.deleted && $0.mergedInto == nil }
        func order(_ a: Account, _ b: Account) -> Bool {
            let typeOrder = AccountType.allCases
            let (ta, tb) = (typeOrder.firstIndex(of: a.type)!, typeOrder.firstIndex(of: b.type)!)
            return (ta, a.sortOrder, a.name, a.id.string) < (tb, b.sortOrder, b.name, b.id.string)
        }
        var childMap: [Account.ID: [Account.ID]] = [:]
        for (parent, children) in Dictionary(grouping: live.filter { $0.parent != nil }, by: { $0.parent! }) {
            childMap[parent] = children.sorted(by: order).map(\.id)
        }
        self.accounts = accounts
        self.childMap = childMap
        self.roots = live.filter { $0.parent == nil }.sorted(by: order).map(\.id)
    }

    public subscript(id: Account.ID) -> Account? { accounts[id] }

    public func children(of id: Account.ID) -> [Account.ID] { childMap[id] ?? [] }

    /// The account itself and all live descendants.
    public func subtree(of id: Account.ID) -> Set<Account.ID> {
        var result: Set<Account.ID> = [id]
        var stack = [id]
        while let next = stack.popLast() {
            for child in children(of: next) where result.insert(child).inserted { stack.append(child) }
        }
        return result
    }

    /// "Assets:Bank:Checking" style path, following parents.
    public func path(of id: Account.ID, separator: String = ":") -> String {
        var names: [String] = []
        var current: Account.ID? = id
        while let next = current, let account = accounts[next], names.count < 64 {
            names.append(account.name)
            current = account.parent
        }
        return names.reversed().joined(separator: separator)
    }
}
