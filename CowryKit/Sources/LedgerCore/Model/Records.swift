/// A price the user entered by hand. Fetched market prices are a local cache, not ledger data.
public struct Price: Identifiable, Hashable, Sendable {
    public typealias ID = Identifier<Price>

    public let id: ID
    public let base: Commodity.ID
    public let quote: Commodity.ID
    public let date: LocalDate
    /// Units of `quote` per one unit of `base`.
    public let rate: Rate
    public let rev: Op.ID

    package init(id: ID, base: Commodity.ID, quote: Commodity.ID, date: LocalDate, rate: Rate, rev: Op.ID) {
        self.id = id
        self.base = base
        self.quote = quote
        self.date = date
        self.rate = rate
        self.rev = rev
    }
}

/// "At the start of `date`, `account` held `amount` of `commodity`." Checked, never enforced.
public struct BalanceAssertion: Identifiable, Hashable, Sendable {
    public typealias ID = Identifier<BalanceAssertion>

    public let id: ID
    public let account: Account.ID
    public let commodity: Commodity.ID
    public let date: LocalDate
    public let amount: Int64
    public let rev: Op.ID

    package init(id: ID, account: Account.ID, commodity: Commodity.ID, date: LocalDate, amount: Int64, rev: Op.ID) {
        self.id = id
        self.account = account
        self.commodity = commodity
        self.date = date
        self.amount = amount
        self.rev = rev
    }
}

public struct Setting: Hashable, Sendable {
    public let key: SettingKey
    public let value: String
    public let rev: Op.ID

    package init(key: SettingKey, value: String, rev: Op.ID) {
        self.key = key
        self.value = value
        self.rev = rev
    }
}

public struct SettingKey: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Value: a `Commodity.ID` string.
    public static let primaryCommodity = SettingKey(rawValue: "primary_commodity")
}

/// Amounts per commodity, in minor units.
public typealias Holdings = [Commodity.ID: Int64]
