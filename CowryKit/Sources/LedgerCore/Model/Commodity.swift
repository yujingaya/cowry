/// Anything an amount can be denominated in: a currency, a security, a crypto asset.
public struct Commodity: Identifiable, Hashable, Sendable {
    public typealias ID = Identifier<Commodity>

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case currency, security, crypto, other
    }

    public let id: ID
    public let code: String
    public let kind: Kind
    /// Decimal places of the minor unit (KRW 0, USD 2, BTC 8). Amounts are stored as integers
    /// of the minor unit, so this can never change after creation.
    public let scale: Int
    public let name: String?
    /// The commodity this one's prices are quoted in (AAPL → USD).
    public let quote: ID?
    /// Opaque price-feed descriptor, e.g. `{"provider":"ecb"}`.
    public let feed: String?
    public let archived: Bool
    public let rev: Op.ID

    package init(
        id: ID, code: String, kind: Kind, scale: Int, name: String?, quote: ID?, feed: String?,
        archived: Bool, rev: Op.ID
    ) {
        self.id = id
        self.code = code
        self.kind = kind
        self.scale = scale
        self.name = name
        self.quote = quote
        self.feed = feed
        self.archived = archived
        self.rev = rev
    }

    public static let scaleRange = 0...12
}

extension Identifier where Tag == Commodity {
    /// Deterministic ID for an ISO 4217 currency, identical on every device.
    public static func iso4217(_ code: String) -> Self {
        .named("iso4217:\(code.uppercased())")
    }
}

public enum ISO4217 {
    /// Minor units for currencies that don't use 2 decimal places.
    private static let exceptions: [String: Int] = [
        "BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0, "KRW": 0,
        "PYG": 0, "RWF": 0, "UGX": 0, "VND": 0, "VUV": 0, "XAF": 0, "XOF": 0, "XPF": 0,
        "BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
    ]

    public static func scale(for code: String) -> Int {
        exceptions[code.uppercased()] ?? 2
    }
}
