import Foundation

/// A calendar date with no time or time zone. Ledger dates are days on a calendar, not instants:
/// a transaction recorded on 2026-09-20 stays on 2026-09-20 no matter where the device travels.
public struct LocalDate: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...Self.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses exactly `YYYY-MM-DD`.
    public init?(_ string: some StringProtocol) {
        let parts: (Int, Int, Int)? = ASCII.withBytes(string) { bytes in
            guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
                  let year = ASCII.digits(bytes, 0..<4),
                  let month = ASCII.digits(bytes, 5..<7),
                  let day = ASCII.digits(bytes, 8..<10)
            else { return nil }
            return (Int(year), Int(month), Int(day))
        }
        guard let (year, month, day) = parts else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

}

// MARK: - Day arithmetic

extension LocalDate {
    /// Days since 1970-01-01 (proleptic Gregorian), using Howard Hinnant's `days_from_civil`.
    public var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Inverse of `ordinal` (`civil_from_days`). Returns nil outside years 1...9999.
    public init?(ordinal: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        self.init(year: year, month: month, day: day)
    }

    public func adding(days: Int) -> LocalDate? {
        LocalDate(ordinal: ordinal + days)
    }

    /// Today's date on the device's current calendar day. Only for defaults in the UI layer;
    /// the ledger itself never asks for "today".
    public static func today(in timeZone: TimeZone = .current, now: Date = Date()) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return LocalDate(year: parts.year!, month: parts.month!, day: parts.day!)!
    }
}

// MARK: - Text form

extension LocalDate: CustomStringConvertible, LosslessStringConvertible {
    public var description: String {
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: width - digits.count) + digits
        }
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    public init?(_ description: String) {
        self.init(description[...])
    }
}

extension LocalDate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = LocalDate(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
