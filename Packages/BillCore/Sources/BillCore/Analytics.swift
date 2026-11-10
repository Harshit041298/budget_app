import Foundation

/// A lightweight, Sendable snapshot of a stored transaction used for analytics
/// and for the LLM's tools.
public struct TxnFact: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var merchant: String
    public var amount: Double        // positive magnitude
    public var isCredit: Bool
    public var category: SpendCategory
    public var countsAsSpending: Bool
    public var items: [String]
    /// Set when the user filed this under one of their own categories
    /// (`category` then holds the custom category's parent).
    public var customKey: String?
    public var customName: String?
    /// Account display name, e.g. "CIBC Dividend Visa", and its kind
    /// ("credit", "debit", ...).
    public var account: String?
    public var accountKind: String?

    public init(id: UUID = UUID(), date: Date, merchant: String, amount: Double, isCredit: Bool,
                category: SpendCategory, countsAsSpending: Bool = true, items: [String] = [],
                customKey: String? = nil, customName: String? = nil,
                account: String? = nil, accountKind: String? = nil) {
        self.id = id
        self.date = date
        self.merchant = merchant
        self.amount = amount
        self.isCredit = isCredit
        self.category = category
        self.countsAsSpending = countsAsSpending
        self.items = items
        self.customKey = customKey
        self.customName = customName
        self.account = account
        self.accountKind = accountKind
    }

    /// Key used for grouping: the custom category if any, else the built-in one.
    public var categoryKey: String { customKey ?? category.rawValue }
    public var categoryName: String { customName ?? category.displayName }

    /// Contribution to spending: purchases are positive, refunds negative,
    /// payments/transfers/income are zero.
    public var spend: Double {
        guard countsAsSpending, category.isSpending else { return 0 }
        return isCredit ? -amount : amount
    }

    public var isIncome: Bool { isCredit && category == .income }
}

public struct CategoryTotal: Sendable, Hashable, Identifiable {
    public var category: SpendCategory
    public var total: Double
    public var count: Int
    public var id: SpendCategory { category }
}

/// Totals per category key, including the user's custom categories.
public struct CategoryKeyTotal: Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var base: SpendCategory
    public var total: Double
    public var count: Int
    public var id: String { key }
}

public struct AccountTotal: Sendable, Hashable, Identifiable {
    public var account: String
    public var kind: String?
    public var spend: Double
    public var credits: Double
    public var count: Int
    public var id: String { account }
}

public struct PriceChange: Sendable, Hashable, Identifiable {
    public var merchant: String
    public var oldAmount: Double
    public var newAmount: Double
    public var date: Date
    public var id: String { merchant }
}

public struct MonthTotal: Sendable, Hashable, Identifiable {
    public var month: Date
    public var spend: Double
    public var income: Double
    public var id: Date { month }
}

public struct MerchantTotal: Sendable, Hashable, Identifiable {
    public var merchant: String
    public var total: Double
    public var count: Int
    public var id: String { merchant }
}

public struct RecurringCharge: Sendable, Hashable, Identifiable {
    public enum Cadence: String, Sendable { case weekly, monthly, yearly
        public var perYear: Double { self == .weekly ? 52 : self == .monthly ? 12 : 1 }
    }
    public var merchant: String
    public var typicalAmount: Double
    public var cadence: Cadence
    public var lastDate: Date
    public var nextExpected: Date
    public var occurrences: Int
    public var category: SpendCategory
    public var annualCost: Double { typicalAmount * cadence.perYear }
    public var id: String { merchant }
}

public struct Anomaly: Sendable, Hashable, Identifiable {
    public var fact: TxnFact
    public var reason: String
    public var id: UUID { fact.id }
}

public struct CategoryChange: Sendable, Hashable, Identifiable {
    public var category: SpendCategory
    public var thisMonth: Double
    public var baseline: Double
    public var change: Double { thisMonth - baseline }
    public var percent: Double { baseline > 0 ? change / baseline : 0 }
    public var id: SpendCategory { category }
}

public enum SpendingAnalytics {
    public static func inMonth(_ facts: [TxnFact], _ month: Date) -> [TxnFact] {
        let start = DateParsing.startOfMonth(month)
        let end = DateParsing.addMonths(1, to: start)
        return facts.filter { $0.date >= start && $0.date < end }
    }

    public static func totalSpend(_ facts: [TxnFact]) -> Double {
        facts.reduce(0) { $0 + $1.spend }
    }

    public static func totalIncome(_ facts: [TxnFact]) -> Double {
        facts.filter(\.isIncome).reduce(0) { $0 + $1.amount }
    }

    public static func byCategory(_ facts: [TxnFact]) -> [CategoryTotal] {
        var totals: [SpendCategory: (Double, Int)] = [:]
        for f in facts where f.spend != 0 {
            let cur = totals[f.category] ?? (0, 0)
            totals[f.category] = (cur.0 + f.spend, cur.1 + 1)
        }
        return totals.map { CategoryTotal(category: $0.key, total: $0.value.0, count: $0.value.1) }
            .filter { $0.total > 0.005 }
            .sorted { $0.total > $1.total }
    }

    public static func byCategoryKey(_ facts: [TxnFact]) -> [CategoryKeyTotal] {
        var totals: [String: CategoryKeyTotal] = [:]
        for f in facts where f.spend != 0 {
            var t = totals[f.categoryKey] ?? CategoryKeyTotal(key: f.categoryKey, name: f.categoryName,
                                                               base: f.category, total: 0, count: 0)
            t.total += f.spend
            t.count += 1
            totals[f.categoryKey] = t
        }
        return totals.values.filter { $0.total > 0.005 }.sorted { $0.total > $1.total }
    }

    public static func spend(forKey key: String, _ facts: [TxnFact], month: Date) -> Double {
        totalSpend(inMonth(facts, month).filter { $0.categoryKey == key })
    }

    /// Spending per account. Unassigned transactions are grouped as "Other".
    public static func byAccount(_ facts: [TxnFact]) -> [AccountTotal] {
        var totals: [String: AccountTotal] = [:]
        for f in facts where f.countsAsSpending {
            let name = f.account ?? "Unassigned"
            var t = totals[name] ?? AccountTotal(account: name, kind: f.accountKind, spend: 0, credits: 0, count: 0)
            t.spend += f.spend
            if f.isCredit && !f.category.isSpending { t.credits += f.amount }
            t.count += 1
            totals[name] = t
        }
        return totals.values.filter { $0.spend > 0.005 || $0.credits > 0.005 }.sorted { $0.spend > $1.spend }
    }

    /// Recurring charges whose latest amount went up versus the previous one.
    public static func priceChanges(_ facts: [TxnFact], now: Date = Date()) -> [PriceChange] {
        recurring(facts, now: now).compactMap { r in
            let charges = facts.filter { $0.merchant == r.merchant && !$0.isCredit }
                .sorted { $0.date < $1.date }
            guard charges.count >= 2 else { return nil }
            let last = charges[charges.count - 1], prev = charges[charges.count - 2]
            let diff = last.amount - prev.amount
            guard diff >= 0.5, last.amount <= prev.amount * 1.6 else { return nil }
            return PriceChange(merchant: r.merchant, oldAmount: prev.amount, newAmount: last.amount, date: last.date)
        }
    }

    public static let streamingMerchants: Set<String> = [
        "Netflix", "Disney+", "Crave", "Spotify", "YouTube Premium", "Apple Services", "Amazon Prime",
        "Audible", "Paramount+", "Prime Video"
    ]

    public static func monthly(_ facts: [TxnFact], months: Int, endingAt end: Date = Date()) -> [MonthTotal] {
        let last = DateParsing.startOfMonth(end)
        return (0..<months).reversed().map { back in
            let m = DateParsing.addMonths(-back, to: last)
            let f = inMonth(facts, m)
            return MonthTotal(month: m, spend: totalSpend(f), income: totalIncome(f))
        }
    }

    public static func topMerchants(_ facts: [TxnFact], limit: Int = 8) -> [MerchantTotal] {
        var totals: [String: (Double, Int)] = [:]
        for f in facts where f.spend != 0 {
            let cur = totals[f.merchant] ?? (0, 0)
            totals[f.merchant] = (cur.0 + f.spend, cur.1 + 1)
        }
        return totals.map { MerchantTotal(merchant: $0.key, total: $0.value.0, count: $0.value.1) }
            .filter { $0.total > 0.005 }
            .sorted { $0.total > $1.total }
            .prefix(limit).map { $0 }
    }

    /// Detects subscriptions and other repeating charges.
    public static func recurring(_ facts: [TxnFact], now: Date = Date()) -> [RecurringCharge] {
        let debits = facts.filter { !$0.isCredit && $0.countsAsSpending && $0.category.isSpending }
        let grouped = Dictionary(grouping: debits, by: \.merchant)
        var out: [RecurringCharge] = []
        for (merchant, list) in grouped where list.count >= 2 {
            let sorted = list.sorted { $0.date < $1.date }
            let amounts = sorted.map(\.amount).sorted()
            let median = amounts[amounts.count / 2]
            guard median > 0 else { continue }
            // Keep charges close to the typical amount (subscriptions rarely vary much).
            let similar = sorted.filter { abs($0.amount - median) / median <= 0.15 }
            guard similar.count >= 2 else { continue }
            let gaps = zip(similar, similar.dropFirst()).map { DateParsing.days(from: $0.date, to: $1.date) }
            let sortedGaps = gaps.sorted()
            let medianGap = sortedGaps[sortedGaps.count / 2]
            let cadence: RecurringCharge.Cadence
            switch medianGap {
            case 6...8: cadence = .weekly
            case 26...35: cadence = .monthly
            case 350...380: cadence = .yearly
            default: continue
            }
            // Require regularity: most gaps near the median.
            let regular = gaps.filter { abs($0 - medianGap) <= max(4, medianGap * 0.2) }.count
            guard Double(regular) >= Double(gaps.count) * 0.6 else { continue }
            if cadence == .weekly && similar.count < 4 { continue }
            if cadence == .monthly && similar.count < 2 { continue }
            let last = similar.last!.date
            // Drop subscriptions that seem to have stopped.
            let staleAfter = medianGap * 2.2
            if DateParsing.days(from: last, to: now) > staleAfter { continue }
            out.append(RecurringCharge(merchant: merchant, typicalAmount: median, cadence: cadence,
                                       lastDate: last, nextExpected: last.addingTimeInterval(medianGap * 86_400),
                                       occurrences: similar.count, category: similar.last!.category))
        }
        return out.sorted { $0.annualCost > $1.annualCost }
    }

    /// Flags charges far above what is normal for their category or merchant.
    public static func anomalies(_ facts: [TxnFact], in recent: [TxnFact]) -> [Anomaly] {
        let debits = facts.filter { !$0.isCredit && $0.spend > 0 }
        let byCat = Dictionary(grouping: debits, by: \.category)
        let byMerchant = Dictionary(grouping: debits, by: \.merchant)
        var out: [Anomaly] = []
        for f in recent where !f.isCredit && f.spend > 25 {
            if let history = byMerchant[f.merchant], history.count >= 4 {
                let others = history.filter { $0.id != f.id }.map(\.amount).sorted()
                let median = others[others.count / 2]
                if median > 0, f.amount > median * 2.5 {
                    out.append(Anomaly(fact: f, reason: String(format: "%.1f× your usual %@ charge", f.amount / median, f.merchant)))
                    continue
                }
            }
            if let history = byCat[f.category], history.count >= 6 {
                let values = history.filter { $0.id != f.id }.map(\.amount)
                let mean = values.reduce(0, +) / Double(values.count)
                let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
                let sd = variance.squareRoot()
                if sd > 0, f.amount > mean + 3 * sd, f.amount > mean * 2 {
                    out.append(Anomaly(fact: f, reason: "Much larger than your typical \(f.category.displayName.lowercased()) purchase"))
                }
            }
        }
        return out.sorted { $0.fact.amount > $1.fact.amount }
    }

    /// Category spend in `month` vs. the average of the previous 3 months.
    public static func categoryChanges(_ facts: [TxnFact], month: Date) -> [CategoryChange] {
        let current = byCategory(inMonth(facts, month))
        var baseline: [SpendCategory: Double] = [:]
        var monthsWithData = 0
        for back in 1...3 {
            let m = inMonth(facts, DateParsing.addMonths(-back, to: month))
            if !m.isEmpty { monthsWithData += 1 }
            for c in byCategory(m) { baseline[c.category, default: 0] += c.total }
        }
        guard monthsWithData > 0 else { return [] }
        let cats = Set(current.map(\.category)).union(baseline.keys)
        return cats.map { cat in
            CategoryChange(category: cat,
                           thisMonth: current.first { $0.category == cat }?.total ?? 0,
                           baseline: (baseline[cat] ?? 0) / Double(monthsWithData))
        }
        .filter { abs($0.change) >= 40 && ($0.baseline == 0 || abs($0.percent) >= 0.25) }
        .sorted { abs($0.change) > abs($1.change) }
    }

    /// Rule-based insights shown when the on-device LLM is unavailable, and
    /// also fed to the LLM as grounded facts.
    public static func ruleInsights(_ facts: [TxnFact], month: Date, now: Date = Date()) -> [String] {
        var out: [String] = []
        let thisMonth = inMonth(facts, month)
        let lastMonth = inMonth(facts, DateParsing.addMonths(-1, to: month))
        let spend = totalSpend(thisMonth)
        let prev = totalSpend(lastMonth)
        let monthName = monthLabel(month)

        if spend > 0 {
            if prev > 0 {
                let pct = (spend - prev) / prev * 100
                out.append(String(format: "You spent %@ in %@, %@ %.0f%% vs. the month before (%@).",
                                  money(spend), monthName, pct >= 0 ? "up" : "down", abs(pct), money(prev)))
            } else {
                out.append("You spent \(money(spend)) in \(monthName).")
            }
        }
        let income = totalIncome(thisMonth)
        if income > 0 {
            let rate = (income - spend) / income * 100
            out.append(String(format: "Income was %@; you kept about %.0f%% of it.", money(income), rate))
        }
        if let top = byCategory(thisMonth).first, spend > 0 {
            out.append(String(format: "%@ was your biggest category at %@ (%.0f%% of spending).",
                              top.category.displayName, money(top.total), top.total / spend * 100))
        }
        for c in categoryChanges(facts, month: month).prefix(2) {
            out.append("\(c.category.displayName) is \(c.change > 0 ? "up" : "down") \(money(abs(c.change))) compared with your 3-month average.")
        }
        let subs = recurring(facts, now: now)
        if !subs.isEmpty {
            let annual = subs.reduce(0) { $0 + $1.annualCost }
            out.append("You have \(subs.count) recurring charge\(subs.count == 1 ? "" : "s") costing about \(money(annual)) a year.")
        }
        for p in priceChanges(facts, now: now).prefix(2) {
            out.append("\(p.merchant) went up from \(money(p.oldAmount)) to \(money(p.newAmount)).")
        }
        let streaming = subs.filter { streamingMerchants.contains($0.merchant) && $0.cadence == .monthly }
        if streaming.count >= 2 {
            let monthlyCost = streaming.reduce(0) { $0 + $1.typicalAmount }
            out.append("You pay for \(streaming.count) streaming services (\(money(monthlyCost))/month): \(streaming.map(\.merchant).joined(separator: ", ")).")
        }
        if let a = anomalies(facts, in: thisMonth).first {
            out.append("Unusual: \(a.fact.merchant) \(money(a.fact.amount)) — \(a.reason).")
        }
        let dining = thisMonth.filter { $0.category == .dining && $0.spend > 0 }
        if dining.count >= 8 {
            out.append("You bought food or coffee out \(dining.count) times this month (\(money(totalSpend(dining)))).")
        }
        return out
    }

    /// Compact plain-text summary handed to the LLM so it reasons over real
    /// numbers instead of inventing them.
    public static func llmBrief(_ facts: [TxnFact], month: Date, now: Date = Date()) -> String {
        let thisMonth = inMonth(facts, month)
        var lines: [String] = []
        lines.append("Month: \(monthLabel(month))")
        lines.append("Total spending: \(money(totalSpend(thisMonth)))")
        lines.append("Income: \(money(totalIncome(thisMonth)))")
        let history = monthly(facts, months: 6, endingAt: month)
        lines.append("Spending by month: " + history.map { "\(monthLabel($0.month)) \(money($0.spend))" }.joined(separator: "; "))
        lines.append("By category this month: " + byCategoryKey(thisMonth).prefix(8)
            .map { "\($0.name) \(money($0.total)) (\($0.count) txns)" }.joined(separator: "; "))
        let accounts = byAccount(thisMonth)
        if accounts.count > 1 {
            lines.append("By account this month: " + accounts.prefix(5)
                .map { a in "\(a.account)\(a.kind.map { k in " (\(k))" } ?? "") \(money(a.spend))" }.joined(separator: "; "))
        }
        lines.append("Top merchants this month: " + topMerchants(thisMonth, limit: 6)
            .map { "\($0.merchant) \(money($0.total)) x\($0.count)" }.joined(separator: "; "))
        let changes = categoryChanges(facts, month: month).prefix(4)
        if !changes.isEmpty {
            lines.append("Changes vs 3-month average: " + changes
                .map { "\($0.category.displayName) \($0.change >= 0 ? "+" : "-")\(money(abs($0.change)))" }.joined(separator: "; "))
        }
        let subs = recurring(facts, now: now).prefix(8)
        if !subs.isEmpty {
            lines.append("Recurring charges: " + subs
                .map { "\($0.merchant) \(money($0.typicalAmount))/\($0.cadence.rawValue)" }.joined(separator: "; "))
        }
        let unusual = anomalies(facts, in: thisMonth).prefix(3)
        if !unusual.isEmpty {
            lines.append("Unusual charges: " + unusual.map { "\($0.fact.merchant) \(money($0.fact.amount))" }.joined(separator: "; "))
        }
        let products = thisMonth.flatMap(\.items).prefix(12)
        if !products.isEmpty {
            lines.append("Products bought: " + products.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// Projects month-end spending from the pace so far. Only meaningful for
    /// the current month; returns nil for past months or too little data.
    public static func forecast(_ facts: [TxnFact], month: Date, now: Date = Date()) -> Double? {
        let start = DateParsing.startOfMonth(month)
        guard DateParsing.startOfMonth(now) == start else { return nil }
        let cal = DateParsing.calendar
        let day = cal.component(.day, from: now)
        guard day >= 5, let days = cal.range(of: .day, in: .month, for: start)?.count else { return nil }
        let soFar = totalSpend(inMonth(facts, month))
        guard soFar > 0 else { return nil }
        // Recurring charges still to come this month are added at full value
        // rather than extrapolated.
        let upcoming = recurring(facts, now: now)
            .filter { $0.cadence == .monthly && $0.nextExpected > now && DateParsing.startOfMonth($0.nextExpected) == start }
            .reduce(0) { $0 + $1.typicalAmount }
        return soFar / Double(day) * Double(days) * 0.85 + soFar * 0.15 + upcoming
    }

    /// Spend per category for a month (for budgets).
    public static func spend(in category: SpendCategory, _ facts: [TxnFact], month: Date) -> Double {
        totalSpend(inMonth(facts, month).filter { $0.category == category })
    }

    public static func monthLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }

    public static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_CA")
        let digits = v.magnitude >= 1000 ? 0 : 2
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }
}
