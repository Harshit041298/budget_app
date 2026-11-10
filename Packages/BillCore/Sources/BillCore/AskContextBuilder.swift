import Foundation

/// Turns a chat question into a small, exact fact sheet computed in code.
/// The on-device model has a ~4k-token window and is weak at arithmetic, so
/// the app does the maths and the model only phrases the answer.
public enum AskContextBuilder {
    static let synonyms: [(words: [String], category: SpendCategory)] = [
        (["shopping", "shop", "clothes", "clothing", "electronics", "retail"], .shopping),
        (["dining", "restaurant", "eating out", "eat out", "food", "coffee", "takeout", "take-out", "delivery", "uber eats", "doordash", "skip"], .dining),
        (["grocer", "grocery", "groceries", "supermarket"], .groceries),
        (["gas", "fuel", "petrol"], .fuel),
        (["transport", "transit", "uber", "taxi", "parking", "presto", "commute"], .transportation),
        (["subscription", "streaming", "netflix", "spotify"], .subscriptions),
        (["rent", "housing", "mortgage"], .housing),
        (["phone", "internet", "mobile", "wireless"], .phoneInternet),
        (["utilit", "hydro", "electric"], .utilities),
        (["insurance"], .insurance),
        (["health", "pharmacy", "medical", "dental"], .health),
        (["entertainment", "movies", "concert", "games"], .entertainment),
        (["travel", "flight", "hotel", "trip"], .travel),
        (["fee", "interest"], .fees),
        (["gym", "salon", "haircut", "personal care"], .personalCare)
    ]

    public struct Period: Sendable {
        public var start: Date
        public var end: Date
        public var label: String
        public var months: Double
    }

    public static func period(for question: String, now: Date = Date()) -> Period {
        let q = question.lowercased()
        let thisMonth = DateParsing.startOfMonth(now)
        let cal = DateParsing.calendar
        if q.contains("last month") || q.contains("previous month") {
            let s = DateParsing.addMonths(-1, to: thisMonth)
            return Period(start: s, end: thisMonth, label: SpendingAnalytics.monthLabel(s), months: 1)
        }
        if q.contains("this month") || q.contains("so far") {
            return Period(start: thisMonth, end: DateParsing.addMonths(1, to: thisMonth), label: SpendingAnalytics.monthLabel(thisMonth), months: 1)
        }
        if q.contains("week") {
            return Period(start: now.addingTimeInterval(-7 * 86_400), end: now.addingTimeInterval(86_400), label: "the last 7 days", months: 0.25)
        }
        if q.contains("this year") || q.contains("year") {
            let comps = cal.dateComponents([.year], from: now)
            let s = cal.date(from: comps) ?? thisMonth
            let m = Double(cal.component(.month, from: now))
            return Period(start: s, end: DateParsing.addMonths(1, to: thisMonth), label: "this year", months: m)
        }
        // A named month, e.g. "in October".
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        for (i, name) in names.enumerated() where q.contains(name) || q.contains(String(name.prefix(3)) + " ") {
            var s = thisMonth
            for _ in 0..<12 where cal.component(.month, from: s) != i + 1 { s = DateParsing.addMonths(-1, to: s) }
            return Period(start: s, end: DateParsing.addMonths(1, to: s), label: SpendingAnalytics.monthLabel(s), months: 1)
        }
        let s = DateParsing.addMonths(-3, to: thisMonth)
        let elapsed = Double(cal.component(.day, from: now)) / 30.0
        return Period(start: s, end: DateParsing.addMonths(1, to: thisMonth),
                      label: "the last 3 months plus this month so far", months: 3 + elapsed)
    }

    /// Category keys mentioned in the question (built-in synonyms and custom names).
    public static func categories(in question: String, facts: [TxnFact]) -> [(key: String, name: String)] {
        let q = " " + question.lowercased() + " "
        var out: [(key: String, name: String)] = []
        let customs = Dictionary(facts.compactMap { f in f.customKey.map { ($0, f.customName ?? $0) } }, uniquingKeysWith: { a, _ in a })
        for (key, name) in customs where q.contains(name.lowercased()) { out.append((key, name)) }
        for s in synonyms where s.words.contains(where: { q.containsKeyword($0) }) {
            if !out.contains(where: { $0.key == s.category.rawValue }) { out.append((s.category.rawValue, s.category.displayName)) }
        }
        return Array(out.prefix(2))
    }

    /// Merchants (from the user's data) mentioned in the question.
    public static func merchants(in question: String, facts: [TxnFact]) -> [String] {
        let q = question.lowercased()
        let names = Set(facts.map(\.merchant)).filter { $0.count >= 3 }
        return names.filter { q.contains($0.lowercased()) }.sorted { $0.count > $1.count }.prefix(2).map { $0 }
    }

    static let essentials: Set<SpendCategory> = [.housing, .insurance, .utilities, .health, .education]

    public static func build(question: String, facts: [TxnFact], now: Date = Date(),
                             savingsTarget: Double? = nil, incomeOverride: Double? = nil, maxCharacters: Int = 1800) -> String {
        let q = question.lowercased()
        let p = period(for: question, now: now)
        let inPeriod = facts.filter { $0.date >= p.start && $0.date < p.end }
        let money = SpendingAnalytics.money
        var lines: [String] = []

        let total = SpendingAnalytics.totalSpend(inPeriod)
        let purchases = inPeriod.filter { $0.spend > 0 }.count
        lines.append("Period: \(p.label). Total spending \(money(total)) over \(purchases) purchases"
                     + (p.months > 1 ? ", about \(money(total / p.months)) per month." : "."))

        let cats = categories(in: question, facts: facts)
        let merchantsAsked = merchants(in: question, facts: facts)

        for c in cats {
            let cf = inPeriod.filter { $0.categoryKey == c.key }
            let ct = SpendingAnalytics.totalSpend(cf)
            var s = "\(c.name): \(money(ct)) (\(cf.filter { $0.spend > 0 }.count) purchases"
            s += p.months > 1 ? ", about \(money(ct / p.months))/month)." : ")."
            let top = SpendingAnalytics.topMerchants(cf, limit: 5)
            if !top.isEmpty {
                s += " Where: " + top.map { "\($0.merchant) \(money($0.total)) (\($0.count)x)" }.joined(separator: ", ") + "."
            }
            let biggest = cf.filter { !$0.isCredit }.sorted { $0.amount > $1.amount }.prefix(3)
            if !biggest.isEmpty {
                s += " Biggest: " + biggest.map { "\($0.merchant) \(money($0.amount)) on \(DateParsing.isoDay.string(from: $0.date))" }.joined(separator: ", ") + "."
            }
            let items = cf.flatMap(\.items).prefix(5)
            if !items.isEmpty { s += " Items bought: " + items.joined(separator: "; ") + "." }
            lines.append(s)
        }

        for m in merchantsAsked {
            let mf = inPeriod.filter { $0.merchant == m }
            let mt = SpendingAnalytics.totalSpend(mf)
            var s = "\(m): \(money(mt)) over \(mf.count) transactions"
            let byMonth = Dictionary(grouping: mf) { DateParsing.isoMonth.string(from: $0.date) }
                .map { ($0.key, SpendingAnalytics.totalSpend($0.value)) }.sorted { $0.0 < $1.0 }
            if byMonth.count > 1 { s += " (by month: " + byMonth.map { "\($0.0) \(money($0.1))" }.joined(separator: ", ") + ")" }
            s += "."
            let items = mf.flatMap(\.items).prefix(6)
            if !items.isEmpty { s += " Items: " + items.joined(separator: "; ") + "." }
            lines.append(s)
        }

        if cats.isEmpty && merchantsAsked.isEmpty {
            let topCats = SpendingAnalytics.byCategoryKey(inPeriod).prefix(6)
            lines.append("By category: " + topCats.map { "\($0.name) \(money($0.total))" }.joined(separator: ", ") + ".")
            let topM = SpendingAnalytics.topMerchants(inPeriod, limit: 5)
            lines.append("Top merchants: " + topM.map { "\($0.merchant) \(money($0.total)) (\($0.count)x)" }.joined(separator: ", ") + ".")
        }

        if ["credit", "debit", "card", "account", "chequing"].contains(where: { q.contains($0) }) {
            let accts = SpendingAnalytics.byAccount(inPeriod).prefix(5)
            lines.append("By account: " + accts.map { "\($0.account)\($0.kind.map { k in " (\(k))" } ?? "") \(money($0.spend))" }.joined(separator: ", ") + ".")
        }

        if ["subscription", "recurring", "bill"].contains(where: { q.contains($0) }) {
            let subs = SpendingAnalytics.recurring(facts, now: now).prefix(8)
            lines.append("Recurring: " + (subs.isEmpty ? "none detected" :
                subs.map { "\($0.merchant) \(money($0.typicalAmount))/\($0.cadence.rawValue)" }.joined(separator: ", ")) + ".")
        }

        if ["save", "saving", "cut", "reduce", "budget", "afford", "spend less", "lower"].contains(where: { q.contains($0) }) {
            let asked = firstMatch(#"\$?\s?(\d[\d,]{2,})"#, in: question).flatMap { Double($0[1].replacingOccurrences(of: ",", with: "")) }
            let target = asked ?? savingsTarget ?? 1200
            let plan = SavingsPlanner.plan(SavingsPlanner.baseline(facts, now: now, incomeOverride: incomeOverride), target: target)
            let b = plan.baseline
            lines.append("Savings goal \(money(target))/month. Average income \(money(b.avgIncome)), spending \(money(b.avgSpend)), currently saving \(money(b.avgSaved))/month. Gap \(money(plan.gap)).")
            if !plan.cuts.isEmpty {
                lines.append("Recommended cuts: " + plan.cuts.map { "\($0.name) \(money($0.currentMonthly)) to \(money($0.targetMonthly)) (save \(money($0.saving)))" }.joined(separator: "; ") + ".")
            }
            if !plan.achievable { lines.append("Flexible spending alone cannot close the whole gap.") }
            let fixed = b.categories.filter { essentials.contains($0.base) }
            if !fixed.isEmpty {
                lines.append("Fixed essentials, do NOT suggest cutting: " + fixed.map { "\($0.name) \(money($0.total))/month" }.joined(separator: ", ") + ".")
            }
        }

        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) }
        return text
    }
}
