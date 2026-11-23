import Foundation

/// Understands common money questions and answers them exactly from the data,
/// without a language model. Handles follow-ups ("in sep?", "and Walmart?")
/// by inheriting the previous question's subject / period.
public enum AskEngine {
    public enum Intent: String, Sendable { case total, top, biggest, accounts, subscriptions, advice, other }

    public struct CategoryRef: Sendable, Hashable { public var key: String; public var name: String }

    public struct Query: Sendable {
        public var period: AskContextBuilder.Period
        public var periodExplicit: Bool
        public var merchants: [String]
        public var categories: [CategoryRef]
        public var intent: Intent
        public var hasSubject: Bool { !merchants.isEmpty || !categories.isEmpty }

        /// Words describing the subject, used to enrich the AI fact sheet for follow-ups.
        public var subjectText: String {
            (merchants + categories.map(\.name)).joined(separator: " ")
        }
    }

    // MARK: Parsing

    static let monthWords: [(pattern: String, month: Int)] = [
        ("jan(uary)?", 1), ("feb(ruary)?", 2), ("mar(ch)?", 3), ("apr(il)?", 4), ("may", 5), ("june?", 6),
        ("july?", 7), ("aug(ust)?", 8), ("sept?(ember)?", 9), ("oct(ober)?", 10), ("nov(ember)?", 11), ("dec(ember)?", 12)
    ]

    /// A period explicitly mentioned in the question, or nil.
    public static func explicitPeriod(_ question: String, now: Date = Date()) -> AskContextBuilder.Period? {
        let q = question.lowercased()
        let thisMonth = DateParsing.startOfMonth(now)
        let cal = DateParsing.calendar
        func month(_ s: Date) -> AskContextBuilder.Period {
            AskContextBuilder.Period(start: s, end: DateParsing.addMonths(1, to: s), label: SpendingAnalytics.monthLabel(s), months: 1)
        }
        if q.contains("last month") || q.contains("previous month") { return month(DateParsing.addMonths(-1, to: thisMonth)) }
        if q.contains("this month") || q.contains("so far") { return month(thisMonth) }
        if let m = firstMatch(#"(?:last|past)\s+(\d+|two|three|four|six|twelve)\s+months"#, in: q) {
            let words = ["two": 2, "three": 3, "four": 4, "six": 6, "twelve": 12]
            let n = Int(m[1]) ?? words[m[1]] ?? 3
            let s = DateParsing.addMonths(-n, to: thisMonth)
            return AskContextBuilder.Period(start: s, end: thisMonth, label: "the last \(n) months", months: Double(n))
        }
        if q.contains("this week") || q.contains("last 7 days") || q.contains("past week") {
            return AskContextBuilder.Period(start: now.addingTimeInterval(-7 * 86_400), end: now.addingTimeInterval(86_400),
                                            label: "the last 7 days", months: 0.25)
        }
        if q.contains("this year") {
            let s = cal.date(from: cal.dateComponents([.year], from: now)) ?? thisMonth
            return AskContextBuilder.Period(start: s, end: DateParsing.addMonths(1, to: thisMonth), label: "this year",
                                            months: Double(cal.component(.month, from: now)))
        }
        for (pattern, number) in monthWords {
            // "may" only counts with a hint, so "may I" isn't read as May.
            let p = number == 5 ? #"\b(in|of|for|during)\s+may\b"# : #"\b"# + pattern + #"\b"#
            if firstMatch(p, in: q) != nil {
                var s = thisMonth
                for _ in 0..<12 where cal.component(.month, from: s) != number { s = DateParsing.addMonths(-1, to: s) }
                return month(s)
            }
        }
        return nil
    }

    /// Merchants whose name shares a word (4+ letters) with the question.
    public static func matchMerchants(_ question: String, facts: [TxnFact]) -> [String] {
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "&" }
            .map(String.init).filter { $0.count >= 4 })
        let stop: Set<String> = ["spent", "spend", "much", "month", "months", "what", "where", "when", "much", "last",
                                 "this", "that", "have", "with", "from", "most", "money", "total", "card", "cards",
                                 "debit", "credit", "purchase", "purchases", "bought", "order", "orders", "payment",
                                 "transfer", "other", "bank", "store", "shop", "shopping", "food"]
        let keys = words.subtracting(stop)
        guard !keys.isEmpty else { return [] }
        let names = Set(facts.map(\.merchant))
        return names.filter { name in
            let nameWords = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return nameWords.contains { keys.contains($0) } || keys.contains(name.lowercased().filter { $0.isLetter })
        }.sorted()
    }

    public static func parse(_ question: String, facts: [TxnFact], previous: Query?, now: Date = Date()) -> Query {
        let q = question.lowercased()
        let explicit = explicitPeriod(question, now: now)
        var merchants = matchMerchants(question, facts: facts)
        var cats = AskContextBuilder.categories(in: question, facts: facts).map { CategoryRef(key: $0.key, name: $0.name) }
        // A category word that is also a merchant word (e.g. "amazon") — prefer the merchant.
        if !merchants.isEmpty { cats.removeAll { c in merchants.contains { $0.lowercased() == c.name.lowercased() } } }

        var intent: Intent = .other
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }
        if has(["save", "saving", "cut back", "cut down", "reduce", "advice", "tip", "should i", "how can i", "afford", "budget"]) {
            intent = .advice
        } else if has(["subscription", "recurring", "subscriptions"]) {
            intent = .subscriptions
        } else if has(["credit", "debit", "which card", "accounts", "per account"]) {
            intent = .accounts
        } else if has(["biggest", "largest", "most expensive", "big purchases", "expensive"]) {
            intent = .biggest
        } else if has(["where", "most", "top", "which store", "major", "mainly", "breakdown"]) {
            intent = .top
        } else if has(["how much", "spent", "spend", "total", "cost me", "paid", "pay "]) {
            intent = .total
        }

        // Follow-ups: "in sep?", "and last month?", "what about walmart?"
        let shortFollowUp = q.split(separator: " ").count <= 6
        if let previous, shortFollowUp {
            if merchants.isEmpty && cats.isEmpty && (explicit != nil || intent == .other) {
                merchants = previous.merchants
                cats = previous.categories
            }
            if intent == .other { intent = previous.intent }
        }
        let period = explicit ?? (shortFollowUp ? previous?.period : nil) ?? AskContextBuilder.period(for: "", now: now)
        return Query(period: period, periodExplicit: explicit != nil, merchants: merchants, categories: cats, intent: intent)
    }

    // MARK: Answers

    /// Exact answer, or nil when the question needs the AI (advice / open-ended).
    public static func answer(_ query: Query, facts: [TxnFact], now: Date = Date()) -> String? {
        let money = SpendingAnalytics.money
        let p = query.period
        let inPeriod = facts.filter { $0.date >= p.start && $0.date < p.end }

        func subjectFilter(_ f: TxnFact) -> Bool {
            (query.merchants.isEmpty || query.merchants.contains(f.merchant))
                && (query.categories.isEmpty || query.categories.contains { $0.key == f.categoryKey })
        }
        let subject = inPeriod.filter(subjectFilter)
        let subjectName: String = {
            if !query.merchants.isEmpty { return listJoin(query.merchants) }
            if !query.categories.isEmpty { return listJoin(query.categories.map(\.name)) }
            return "everything"
        }()

        switch query.intent {
        case .advice, .other:
            return nil

        case .total:
            guard query.hasSubject else {
                let total = SpendingAnalytics.totalSpend(inPeriod)
                let cats = SpendingAnalytics.byCategoryKey(inPeriod).prefix(3)
                return "You spent **\(money(total))** in \(p.label)." +
                    (cats.isEmpty ? "" : "\nBiggest categories: " + cats.map { "\($0.name) \(money($0.total))" }.joined(separator: ", ") + ".")
            }
            let spent = subject.filter { $0.spend != 0 }
            let total = SpendingAnalytics.totalSpend(spent)
            var text: String
            if spent.isEmpty {
                text = "No spending at \(subjectName) in \(p.label)."
                let all = facts.filter(subjectFilter).filter { $0.spend > 0 }.sorted { $0.date > $1.date }
                if let last = all.first {
                    text += "\nThe most recent was \(money(last.amount)) on \(dayLabel(last.date))."
                }
            } else {
                text = "You spent **\(money(total))** at \(subjectName) in \(p.label) — \(spent.count) purchase\(spent.count == 1 ? "" : "s")."
                if p.months > 1.2 {
                    let byMonth = Dictionary(grouping: spent) { DateParsing.startOfMonth($0.date) }
                        .map { ($0.key, SpendingAnalytics.totalSpend($0.value)) }.sorted { $0.0 < $1.0 }
                    text += "\n" + byMonth.map { "• \(SpendingAnalytics.monthLabel($0.0)): \(money($0.1))" }.joined(separator: "\n")
                }
                if query.merchants.count > 1 || (!query.categories.isEmpty && query.merchants.isEmpty) {
                    let top = SpendingAnalytics.topMerchants(spent, limit: 4)
                    text += "\nMostly: " + top.map { "\($0.merchant) \(money($0.total))" }.joined(separator: ", ") + "."
                }
            }
            let notCounted = subject.filter { !$0.countsAsSpending && !$0.isCredit }
            if !notCounted.isEmpty {
                text += "\n(\(notCounted.count) Amazon order\(notCounted.count == 1 ? "" : "s") from order history worth \(money(notCounted.reduce(0) { $0 + $1.amount })) aren't counted separately — they're matched to your card charges.)"
            }
            return text

        case .top:
            if !query.merchants.isEmpty && query.categories.isEmpty {
                let purchases = subject.filter { $0.spend > 0 }.sorted { $0.amount > $1.amount }
                guard !purchases.isEmpty else { return "No spending at \(subjectName) in \(p.label)." }
                var text = "At \(subjectName) in \(p.label): **\(money(SpendingAnalytics.totalSpend(purchases)))** over \(purchases.count) purchases. Largest:"
                text += "\n" + purchases.prefix(5).map { "• \(dayLabel($0.date)) — \(money($0.amount))\($0.items.first.map { " · \($0)" } ?? "")" }.joined(separator: "\n")
                return text
            }
            let pool = query.categories.isEmpty ? inPeriod : subject
            let top = SpendingAnalytics.topMerchants(pool, limit: 6)
            guard !top.isEmpty else { return "No spending on \(subjectName) in \(p.label)." }
            let total = SpendingAnalytics.totalSpend(pool)
            var text = query.categories.isEmpty
                ? "Where your money went in \(p.label) (**\(money(total))** total):"
                : "\(subjectName) in \(p.label): **\(money(total))**. Where it went:"
            text += "\n" + top.map { m in
                let share = total > 0 ? Int((m.total / total * 100).rounded()) : 0
                return "• \(m.merchant) — \(money(m.total)) (\(m.count)×, \(share)%)"
            }.joined(separator: "\n")
            if query.categories.isEmpty {
                let cats = SpendingAnalytics.byCategoryKey(pool).prefix(3)
                text += "\nTop categories: " + cats.map { "\($0.name) \(money($0.total))" }.joined(separator: ", ") + "."
            }
            return text

        case .biggest:
            let pool = (query.hasSubject ? subject : inPeriod).filter { $0.spend > 0 }.sorted { $0.amount > $1.amount }
            guard !pool.isEmpty else { return "No purchases found for \(subjectName) in \(p.label)." }
            return "Biggest purchases (\(subjectName), \(p.label)):\n" + pool.prefix(5).map {
                "• \($0.merchant) — \(money($0.amount)) on \(dayLabel($0.date))\($0.items.first.map { " · \($0)" } ?? "")"
            }.joined(separator: "\n")

        case .accounts:
            let pool = query.hasSubject ? subject : inPeriod
            let credit = SpendingAnalytics.totalSpend(pool.filter { $0.accountKind == "credit" })
            let debit = SpendingAnalytics.totalSpend(pool.filter { $0.accountKind == "debit" })
            let accounts = SpendingAnalytics.byAccount(pool).prefix(6)
            var text = "In \(p.label): credit cards **\(money(credit))**, debit/chequing **\(money(debit))**."
            if !accounts.isEmpty {
                text += "\n" + accounts.map { "• \($0.account): \(money($0.spend))" }.joined(separator: "\n")
            }
            return text

        case .subscriptions:
            let subs = SpendingAnalytics.recurring(facts, now: now)
            guard !subs.isEmpty else { return "I haven't detected any recurring charges yet. They appear after 2–3 months of statements." }
            let monthly = subs.reduce(0) { $0 + $1.annualCost } / 12
            var text = "\(subs.count) recurring charges, about **\(money(monthly))/month** (\(money(monthly * 12))/year):"
            text += "\n" + subs.prefix(10).map { "• \($0.merchant) — \(money($0.typicalAmount)) \($0.cadence.rawValue)" }.joined(separator: "\n")
            let changes = SpendingAnalytics.priceChanges(facts, now: now)
            if !changes.isEmpty {
                text += "\nPrice increases: " + changes.map { "\($0.merchant) \(money($0.oldAmount)) → \(money($0.newAmount))" }.joined(separator: ", ") + "."
            }
            return text
        }
    }

    static func listJoin(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_CA")
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}
