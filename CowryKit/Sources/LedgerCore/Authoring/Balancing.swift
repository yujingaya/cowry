package enum Balancing {
    /// Turns draft postings into final postings.
    ///
    /// Conversion postings in the draft are dropped and regenerated. If exactly one commodity is
    /// left unbalanced the draft is wrong; if two or more are, the entry is a conversion and one
    /// `Equity:Conversion` posting per unbalanced commodity makes every commodity sum to zero.
    package static func balance(_ draft: [Posting]) throws(ValidationError) -> [Posting] {
        let postings = draft.filter { $0.account != SystemAccount.conversion }
        guard !postings.isEmpty else { throw .noPostings }
        if let index = postings.firstIndex(where: { $0.amount == 0 }) {
            throw .zeroAmount(posting: index)
        }

        let sums = try sumsByCommodity(postings)
        let unbalanced = sums.filter { $0.sum != 0 }
        switch unbalanced.count {
        case 0:
            return postings
        case 1:
            throw .unbalanced(unbalanced[0].commodity, residual: unbalanced[0].sum)
        default:
            var result = postings
            for (commodity, sum) in unbalanced {
                guard sum != .min else { throw .amountOverflow }
                result.append(Posting(account: SystemAccount.conversion, commodity: commodity, amount: -sum))
            }
            return result
        }
    }

    /// Whether every commodity sums to zero — the invariant every stored entry satisfies.
    package static func isBalanced(_ postings: [Posting]) -> Bool {
        guard postings.count >= 2, let sums = try? sumsByCommodity(postings) else { return false }
        return sums.allSatisfy { $0.sum == 0 }
    }

    /// Per-commodity sums in order of first appearance.
    private static func sumsByCommodity(
        _ postings: [Posting]
    ) throws(ValidationError) -> [(commodity: Commodity.ID, sum: Int64)] {
        var order: [Commodity.ID] = []
        var sums: [Commodity.ID: Int64] = [:]
        for posting in postings {
            let current = sums[posting.commodity] ?? { order.append(posting.commodity); return 0 }()
            let (sum, overflow) = current.addingReportingOverflow(posting.amount)
            guard !overflow else { throw .amountOverflow }
            sums[posting.commodity] = sum
        }
        return order.map { ($0, sums[$0]!) }
    }
}
