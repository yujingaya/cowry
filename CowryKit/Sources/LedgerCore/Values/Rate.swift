import Foundation

/// A positive decimal exchange rate or price, kept in canonical text form: plain digits, no
/// exponent, no leading zeros in the integer part, no trailing zeros in the fraction.
/// The text is what gets stored and digested; `decimal` is for arithmetic.
public struct Rate: Hashable, Sendable {
    public let string: String

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return nil }

        var integer = parts[0].drop { $0 == "0" }
        if integer.isEmpty { integer = "0" }
        var fraction = parts.count == 2 ? parts[1][...] : ""
        while fraction.last == "0" { fraction = fraction.dropLast() }

        guard integer != "0" || !fraction.isEmpty else { return nil }
        string = fraction.isEmpty ? String(integer) : "\(integer).\(fraction)"
    }

    public var decimal: Decimal {
        Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))!
    }
}

extension Rate: CustomStringConvertible {
    public var description: String { string }
}

extension Rate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let rate = Rate(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid rate: \(text)")
        }
        self = rate
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
