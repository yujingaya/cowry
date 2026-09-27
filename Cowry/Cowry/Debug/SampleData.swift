#if DEBUG
import Foundation
import Ledger
import LedgerCore

/// Generates a realistic ledger for trying the app and measuring list performance
/// (design.md §8.2). Debug builds only.
enum SampleData {
    @MainActor
    static func add(to model: AppModel, years: Int, perDay: Int) async {
        do {
            let accounts = try await ensureAccounts(model)
            let today = LocalDate.today()
            let start = LocalDate(year: today.year - years, month: today.month, day: 1)!
            var rng = SplitMix(seed: UInt64(years * 1_000 + perDay))
            var drafts: [EntryDraft] = []
            let krw = model.primary
            let usd = try await model.ledger.currency("USD").id

            func draft(_ date: LocalDate, _ payee: String, _ to: Account.ID, _ from: Account.ID, _ amount: Int64) -> EntryDraft {
                EntryDraft(date: date, payee: payee, postings: [
                    Posting(account: to, commodity: krw, amount: amount),
                    Posting(account: from, commodity: krw, amount: -amount),
                ])
            }

            var ordinal = start.ordinal
            while ordinal <= today.ordinal {
                let date = LocalDate(ordinal: ordinal)!
                if date.day == 25 {
                    drafts.append(draft(date, "급여", accounts["checking"]!, accounts["salary"]!, 3_500_000))
                    drafts.append(draft(date, "월세", accounts["housing"]!, accounts["checking"]!, 568_000))
                }
                if date.day == 15 { drafts.append(draft(date, "관리비", accounts["housing"]!, accounts["checking"]!, Int64.random(in: 150...220, using: &rng) * 1_000)) }
                if date.day == 18 { drafts.append(draft(date, "적금 이체", accounts["savings"]!, accounts["checking"]!, 500_000)) }
                for _ in 0 ..< Int.random(in: max(0, perDay - 3)...(perDay + 2), using: &rng) {
                    let pick = Int.random(in: 0..<100, using: &rng)
                    let card = Bool.random(using: &rng) ? accounts["card"]! : accounts["cash"]!
                    switch pick {
                    case 0..<30:
                        let (payee, price) = [("스타벅스", 4_500), ("블루보틀", 6_800), ("메가커피", 2_000), ("폴바셋", 6_200)]
                            .randomElement(using: &rng)!
                        drafts.append(draft(date, payee, accounts["cafe"]!, card, Int64(price)))
                    case 30..<55:
                        let payee = ["김밥천국", "성수 파스타", "을지로 국밥", "동네 분식"].randomElement(using: &rng)!
                        drafts.append(draft(date, payee, accounts["dining"]!, card, Int64.random(in: 8...45, using: &rng) * 1_000))
                    case 55..<70:
                        let payee = ["이마트", "쿠팡", "홈플러스"].randomElement(using: &rng)!
                        drafts.append(draft(date, payee, accounts["groceries"]!, card, Int64.random(in: 20...140, using: &rng) * 1_000))
                    case 70..<90:
                        let payee = ["지하철", "버스", "택시"].randomElement(using: &rng)!
                        drafts.append(draft(date, payee, accounts["transport"]!, card, Int64.random(in: 14...200, using: &rng) * 100))
                    case 90..<97:
                        let payee = ["교보문고", "다이소", "무신사"].randomElement(using: &rng)!
                        drafts.append(draft(date, payee, accounts["shopping"]!, card, Int64.random(in: 5...90, using: &rng) * 1_000))
                    default:
                        let dollars = Int64.random(in: 10...120, using: &rng)
                        drafts.append(EntryDraft(date: date, payee: "Apple Store", postings: [
                            Posting(account: accounts["shopping"]!, commodity: usd, amount: dollars * 100),
                            Posting(account: accounts["card"]!, commodity: krw, amount: -dollars * Int64.random(in: 1_300...1_420, using: &rng)),
                        ]))
                    }
                }
                ordinal += 1
                if drafts.count >= 2_000 {
                    _ = try await model.ledger.post(drafts)
                    drafts.removeAll()
                }
            }
            if !drafts.isEmpty { _ = try await model.ledger.post(drafts) }
        } catch {
            model.present(error)
        }
    }

    @MainActor
    private static func ensureAccounts(_ model: AppModel) async throws -> [String: Account.ID] {
        let opened = LocalDate(year: 1990, month: 1, day: 1)!
        var result: [String: Account.ID] = [:]
        func find(_ name: String, _ type: AccountType, parent: Account.ID?) -> Account.ID? {
            model.tree.accounts.values.first {
                $0.name == name && $0.type == type && $0.parent == parent && !$0.deleted && $0.mergedInto == nil
            }?.id
        }
        func ensure(_ key: String, _ name: String, _ type: AccountType, parent: Account.ID? = nil) async throws -> Account.ID {
            if let id = find(name, type, parent: parent) {
                result[key] = id
                return id
            }
            let account = try await model.ledger.openAccount(name: name, type: type, parent: parent, openedOn: opened)
            result[key] = account.id
            return account.id
        }
        let bank = try await ensure("bank", "은행", .asset)
        _ = try await ensure("checking", "신한 입출금", .asset, parent: bank)
        _ = try await ensure("savings", "카카오 적금", .asset, parent: bank)
        _ = try await ensure("cash", "현금", .asset)
        let cards = try await ensure("cards", "카드", .liability)
        _ = try await ensure("card", "신한카드", .liability, parent: cards)
        let food = try await ensure("food", "식비", .expense)
        _ = try await ensure("cafe", "카페", .expense, parent: food)
        _ = try await ensure("dining", "외식", .expense, parent: food)
        _ = try await ensure("groceries", "장보기", .expense, parent: food)
        _ = try await ensure("housing", "주거", .expense)
        _ = try await ensure("transport", "교통", .expense)
        _ = try await ensure("shopping", "쇼핑", .expense)
        _ = try await ensure("salary", "급여", .income)
        return result
    }
}

/// Deterministic generator so sample ledgers are reproducible.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
