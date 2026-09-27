import Foundation
import Ledger
import LedgerCore

/// Turns ledger values into display text, following the locale and each commodity's scale.
@MainActor
final class AmountFormatter {
    private var commodities: [Commodity.ID: Commodity] = [:]
    private var formatters: [Commodity.ID: NumberFormatter] = [:]

    func update(_ list: [Commodity]) {
        commodities = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        formatters = [:]
    }

    func commodity(_ id: Commodity.ID) -> Commodity? {
        commodities[id]
    }

    func scale(of id: Commodity.ID) -> Int {
        commodities[id]?.scale ?? 2
    }

    func string(_ units: Int64, _ id: Commodity.ID) -> String {
        let value = NSDecimalNumber(decimal: Decimal(units) / pow(10, scale(of: id)))
        return formatter(for: id).string(from: value) ?? "\(units)"
    }

    /// Holdings on one line, the primary commodity first.
    func string(_ holdings: Holdings, primary: Commodity.ID) -> String {
        let nonZero = holdings.filter { $0.value != 0 }
        guard !nonZero.isEmpty else { return string(0, primary) }
        let ordered = nonZero.sorted { lhs, rhs in
            if lhs.key == primary { return true }
            if rhs.key == primary { return false }
            return (commodities[lhs.key]?.code ?? "") < (commodities[rhs.key]?.code ?? "")
        }
        return ordered.map { string($0.value, $0.key) }.joined(separator: " · ")
    }

    /// Plain decimal text for editing, e.g. "50.00" or "4500".
    func editingString(_ units: Int64, _ id: Commodity.ID) -> String {
        let scale = scale(of: id)
        let value = NSDecimalNumber(decimal: Decimal(units) / pow(10, scale))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = scale
        formatter.maximumFractionDigits = scale
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: value) ?? "\(units)"
    }

    /// Parses text people type ("4,500", "50", "50.25") into minor units. Nil if it doesn't
    /// fit the commodity's scale.
    func parse(_ text: String, _ id: Commodity.ID) -> Int64? {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" || $0 == "−" }
            .replacingOccurrences(of: "−", with: "-")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        var scaled = value * pow(10, scale(of: id))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        return Int64(exactly: NSDecimalNumber(decimal: rounded).int64Value)
    }

    private func formatter(for id: Commodity.ID) -> NumberFormatter {
        if let cached = formatters[id] { return cached }
        let formatter = NumberFormatter()
        formatter.locale = .current
        let scale = scale(of: id)
        if let commodity = commodities[id], commodity.kind == .currency {
            formatter.numberStyle = .currency
            formatter.currencyCode = commodity.code
        } else {
            formatter.numberStyle = .decimal
            formatter.positiveSuffix = " " + (commodities[id]?.code ?? "")
            formatter.negativeSuffix = formatter.positiveSuffix
        }
        formatter.minimumFractionDigits = scale
        formatter.maximumFractionDigits = scale
        formatter.minusSign = "−"
        formatters[id] = formatter
        return formatter
    }
}

enum DateText {
    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdE")
        return formatter
    }()

    private static let shortWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMdE")
        return formatter
    }()

    private static let longFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    /// "Sun, Sep 20", with the year when it isn't this year.
    static func short(_ date: LocalDate) -> String {
        let formatter = date.year == LocalDate.today().year ? shortFormatter : shortWithYearFormatter
        return formatter.string(from: self.date(date))
    }

    static func long(_ date: LocalDate) -> String {
        longFormatter.string(from: self.date(date))
    }

    static func month(_ date: LocalDate) -> String {
        monthFormatter.string(from: self.date(date))
    }

    static func time(_ timestamp: HLCTimestamp) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp.millis) / 1000))
    }

    /// Noon on that calendar day in the current time zone, for date pickers and formatters.
    static func date(_ date: LocalDate) -> Date {
        Calendar.current.date(from: DateComponents(year: date.year, month: date.month, day: date.day, hour: 12))!
    }

    static func localDate(_ date: Date) -> LocalDate {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: parts.year!, month: parts.month!, day: parts.day!)!
    }

    static func currentMonth() -> ClosedRange<LocalDate> {
        let today = LocalDate.today()
        let first = LocalDate(year: today.year, month: today.month, day: 1)!
        let last = LocalDate(year: today.year, month: today.month,
                             day: LocalDate.daysInMonth(year: today.year, month: today.month))!
        return first...last
    }
}

/// How an entry reads in everyday terms: money leaving some accounts and arriving in others.
struct EntryFlow {
    /// Accounts money came from (credited), in posting order.
    let from: [Account.ID]
    /// Accounts money went to (debited), in posting order.
    let to: [Account.ID]
    /// What arrived, in the commodity of the first debit.
    let amount: Int64
    let commodity: Commodity.ID
    /// What left, when it was in a different commodity (a foreign purchase or an exchange).
    let counterAmount: Int64?
    let counterCommodity: Commodity.ID?
    /// Exactly one debit and one credit: editable in the simple entry form.
    let isSimple: Bool

    init(_ entry: Entry) {
        let postings = entry.userPostings
        let debits = postings.filter { $0.amount > 0 }
        let credits = postings.filter { $0.amount < 0 }
        from = Self.unique(credits.map(\.account))
        to = Self.unique(debits.map(\.account))
        // Every stored entry has a debit; the fallbacks only keep this total.
        let debitCommodity = debits.first?.commodity ?? credits.first?.commodity ?? Commodity.ID.iso4217("XXX")
        commodity = debitCommodity
        amount = debits.filter { $0.commodity == debitCommodity }.reduce(0) { $0 + $1.amount }
        if let creditCommodity = credits.first?.commodity, creditCommodity != debitCommodity {
            counterCommodity = creditCommodity
            counterAmount = -credits.filter { $0.commodity == creditCommodity }.reduce(0) { $0 + $1.amount }
        } else {
            counterCommodity = nil
            counterAmount = nil
        }
        isSimple = debits.count == 1 && credits.count == 1
    }

    private static func unique(_ ids: [Account.ID]) -> [Account.ID] {
        var seen = Set<Account.ID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
