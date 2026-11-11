import Foundation

/// What the user typically earns, spends and saves per month.
public struct SavingsBaseline: Sendable {
    public var months: Int
    public var avgIncome: Double
    public var avgSpend: Double
    public var categories: [CategoryKeyTotal]   // monthly averages
    public var avgSaved: Double { avgIncome - avgSpend }
}

public struct SavingsCut: Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var base: SpendCategory
    public var currentMonthly: Double
    public var targetMonthly: Double
    public var saving: Double { currentMonthly - targetMonthly }
    public var id: String { key }
}

public struct SavingsPlan: Sendable {
    public var baseline: SavingsBaseline
    public var target: Double
    public var gap: Double              // extra saving needed per month (0 if already on track)
    public var cuts: [SavingsCut]
    public var achievable: Bool         // can the flexible categories cover the gap?
    public var plannedSaving: Double { cuts.reduce(0) { $0 + $1.saving } }
}

public enum SavingsPlanner {
    /// How much of each category is realistically trimmable per month.
    /// Essentials (rent, insurance, utilities, health, education) are never cut.
    public static func flexibility(_ c: SpendCategory) -> Double {
        switch c {
        case .dining: return 0.45
        case .shopping: return 0.45
        case .entertainment: return 0.5
        case .subscriptions: return 0.5
        case .travel: return 0.5
        case .personalCare: return 0.3
        case .giftsDonations: return 0.3
        case .fees: return 0.9
        case .other: return 0.3
        case .transportation: return 0.2
        case .groceries: return 0.15
        case .fuel: return 0.15
        case .phoneInternet: return 0.25
        case .housing, .insurance, .utilities, .health, .education, .income, .transfer: return 0
        }
    }

    /// Averages over the last `months` complete months that have data
    /// (the current, partial month is excluded).
    public static func baseline(_ facts: [TxnFact], months: Int = 3, now: Date = Date(),
                                incomeOverride: Double? = nil) -> SavingsBaseline {
        let thisMonth = DateParsing.startOfMonth(now)
        var used: [Date] = []
        var back = 1
        while used.count < months && back <= 12 {
            let m = DateParsing.addMonths(-back, to: thisMonth)
            if !SpendingAnalytics.inMonth(facts, m).isEmpty { used.append(m) }
            back += 1
        }
        // Fall back to the current month if there is no complete month yet.
        if used.isEmpty && !SpendingAnalytics.inMonth(facts, thisMonth).isEmpty { used = [thisMonth] }
        let n = Double(max(used.count, 1))
        let window = used.flatMap { SpendingAnalytics.inMonth(facts, $0) }
        let income = incomeOverride ?? (SpendingAnalytics.totalIncome(window) / n)
        let cats = SpendingAnalytics.byCategoryKey(window).map { c -> CategoryKeyTotal in
            var c = c
            c.total /= n
            return c
        }
        return SavingsBaseline(months: used.count, avgIncome: income,
                               avgSpend: SpendingAnalytics.totalSpend(window) / n, categories: cats)
    }

    /// Spreads the needed saving over flexible categories in proportion to how
    /// much each can give, rounded to $5.
    public static func plan(_ baseline: SavingsBaseline, target: Double) -> SavingsPlan {
        let gap = max(0, target - baseline.avgSaved)
        guard gap > 0 else {
            return SavingsPlan(baseline: baseline, target: target, gap: 0, cuts: [], achievable: true)
        }
        let candidates = baseline.categories
            .map { ($0, $0.total * flexibility($0.base)) }
            .filter { $0.1 >= 5 }
        let capacity = candidates.reduce(0) { $0 + $1.1 }
        let share = capacity > 0 ? min(1, gap / capacity) : 0
        var cuts: [SavingsCut] = candidates.compactMap { pair in
            let (c, cap) = pair
            let saving = (cap * share / 5).rounded(.up) * 5
            guard saving >= 5 else { return nil }
            let target = max(0, ((c.total - saving) / 5).rounded() * 5)
            return SavingsCut(key: c.key, name: c.name, base: c.base, currentMonthly: c.total, targetMonthly: target)
        }
        cuts.sort { $0.saving > $1.saving }
        return SavingsPlan(baseline: baseline, target: target, gap: gap, cuts: cuts, achievable: capacity >= gap)
    }

    /// Plain-text facts for the on-device LLM.
    public static func brief(_ plan: SavingsPlan, facts: [TxnFact], now: Date = Date()) -> String {
        let b = plan.baseline
        var lines = [
            "Monthly savings goal: \(SpendingAnalytics.money(plan.target))",
            "Average monthly income: \(SpendingAnalytics.money(b.avgIncome)) (over \(b.months) months)",
            "Average monthly spending: \(SpendingAnalytics.money(b.avgSpend))",
            "Currently saving about: \(SpendingAnalytics.money(b.avgSaved)) per month",
            "Gap to close: \(SpendingAnalytics.money(plan.gap)) per month",
            "Planned cuts: " + plan.cuts.map {
                "\($0.name) \(SpendingAnalytics.money($0.currentMonthly)) -> \(SpendingAnalytics.money($0.targetMonthly))"
            }.joined(separator: "; ")
        ]
        // Top merchants in the categories being cut, so tips can be specific.
        let window = facts.filter { $0.date >= DateParsing.addMonths(-3, to: DateParsing.startOfMonth(now)) }
        for cut in plan.cuts.prefix(4) {
            let top = SpendingAnalytics.topMerchants(window.filter { $0.categoryKey == cut.key }, limit: 4)
            if !top.isEmpty {
                lines.append("\(cut.name) merchants (3 months): " + top.map {
                    "\($0.merchant) \(SpendingAnalytics.money($0.total)) x\($0.count)"
                }.joined(separator: ", "))
            }
        }
        let subs = SpendingAnalytics.recurring(facts, now: now).prefix(8)
        if !subs.isEmpty {
            lines.append("Subscriptions: " + subs.map { "\($0.merchant) \(SpendingAnalytics.money($0.typicalAmount))/\($0.cadence.rawValue)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
