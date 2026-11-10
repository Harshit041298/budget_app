import SwiftUI
import BillCore

/// Cards the Insights tab can show. Users choose which ones and in what order.
enum InsightCard: String, CaseIterable, Identifiable {
    case review, accounts, budgets, calendar, categories, pace, history, categoryTrend, incomeVsSpend,
         weekday, topMerchantsChart, ai, recurring, unusual, merchants, products

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review: return "Uncategorised reminder"
        case .accounts: return "Credit vs debit"
        case .budgets: return "Budgets"
        case .calendar: return "Spending calendar"
        case .categories: return "Where it went"
        case .pace: return "Spending pace"
        case .history: return "Last 6 months"
        case .categoryTrend: return "Category trends"
        case .incomeVsSpend: return "Income vs spending"
        case .weekday: return "Spending by weekday"
        case .topMerchantsChart: return "Top merchants chart"
        case .ai: return "AI insights"
        case .recurring: return "Subscriptions & recurring"
        case .unusual: return "Unusual charges"
        case .merchants: return "Top merchants list"
        case .products: return "What you bought"
        }
    }

    var symbol: String {
        switch self {
        case .review: return "tag"
        case .accounts: return "creditcard.and.123"
        case .budgets: return "gauge.with.dots.needle.50percent"
        case .calendar: return "calendar.day.timeline.left"
        case .categories: return "chart.pie"
        case .pace: return "chart.line.uptrend.xyaxis"
        case .history: return "chart.bar"
        case .categoryTrend: return "chart.bar.xaxis"
        case .incomeVsSpend: return "arrow.left.arrow.right.circle"
        case .weekday: return "calendar"
        case .topMerchantsChart: return "chart.bar.doc.horizontal"
        case .ai: return "sparkles"
        case .recurring: return "repeat"
        case .unusual: return "exclamationmark.triangle"
        case .merchants: return "storefront"
        case .products: return "shippingbox"
        }
    }

    var blurb: String {
        switch self {
        case .review: return "Reminds you to file uncategorised merchants."
        case .accounts: return "Credit cards vs debit, and spend per card."
        case .budgets: return "Progress bars for your monthly limits."
        case .calendar: return "Month grid shaded by daily spending; tap a day for details."
        case .categories: return "Donut chart of this month's categories."
        case .pace: return "This month's running total vs last month, day by day."
        case .history: return "Monthly totals for the last 6 months."
        case .categoryTrend: return "How your top categories change month to month."
        case .incomeVsSpend: return "Money in vs money out and your savings rate."
        case .weekday: return "Which days of the week you spend the most."
        case .topMerchantsChart: return "Bar chart of where your money goes."
        case .ai: return "On-device AI summary and a saving tip."
        case .recurring: return "Subscriptions, price increases, yearly cost."
        case .unusual: return "Charges far above your normal."
        case .merchants: return "Top merchants with visit counts."
        case .products: return "Items from Amazon orders and receipts."
        }
    }

    static let defaultLayout: [InsightCard] = [
        .review, .calendar, .accounts, .budgets, .categories, .pace, .weekday, .history, .ai, .recurring, .unusual, .merchants, .products
    ]

    // MARK: Persistence (comma-separated raw values in AppStorage)

    static func decode(_ raw: String) -> [InsightCard] {
        guard !raw.isEmpty else { return defaultLayout }
        var seen = Set<InsightCard>()
        return raw.split(separator: ",").compactMap { InsightCard(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }

    static func encode(_ cards: [InsightCard]) -> String {
        cards.map(\.rawValue).joined(separator: ",")
    }
}

/// A personalised suggestion to add a card, with the reason from the user's data.
struct CardSuggestion: Identifiable {
    let card: InsightCard
    let reason: String
    var id: InsightCard { card }

    /// Looks at the data and proposes cards that would be useful but aren't shown.
    @MainActor
    static func make(facts: [TxnFact], visible: [InsightCard], dismissed: Set<InsightCard>,
                     hasBudgets: Bool, accountCount: Int, now: Date = Date()) -> [CardSuggestion] {
        var out: [CardSuggestion] = []
        func add(_ c: InsightCard, _ reason: String) {
            if !visible.contains(c) && !dismissed.contains(c) { out.append(CardSuggestion(card: c, reason: reason)) }
        }
        let months = SpendingAnalytics.monthsWithData(facts)
        let thisMonth = SpendingAnalytics.inMonth(facts, now)
        let monthlyAvg = months > 0 ? SpendingAnalytics.totalSpend(facts) / Double(months) : 0

        if !thisMonth.isEmpty {
            let days = SpendingAnalytics.dailyTotals(facts, month: now)
            if let big = days.max(by: { $0.value < $1.value }) {
                add(.calendar, "See every day at a glance — your biggest day this month was the \(big.key)\(ordinal(big.key)) (\(money(big.value))).")
            }
            add(.pace, "You have spending this month — see if you're ahead of or behind last month's pace.")
        }
        if months >= 3 {
            let top = SpendingAnalytics.byCategoryKey(facts).first
            add(.categoryTrend, "You have \(months) months of data\(top.map { " — watch whether \($0.name) is growing" } ?? "").")
        }
        let income = SpendingAnalytics.totalIncome(facts)
        if income > 0 {
            let rate = (income - SpendingAnalytics.totalSpend(facts)) / income * 100
            add(.incomeVsSpend, String(format: "You've kept about %.0f%% of your income overall — track it monthly.", rate))
        }
        if facts.filter({ $0.spend > 0 }).count >= 40 {
            add(.weekday, "With \(facts.count) transactions, there's enough to see which days you overspend.")
        }
        if !hasBudgets && monthlyAvg > 0 {
            if let dining = SpendingAnalytics.byCategoryKey(facts).first(where: { $0.base == .dining }), months > 0 {
                add(.budgets, "You average \(money(dining.total / Double(months)))/month on dining — a budget could help.")
            } else {
                add(.budgets, "You average \(money(monthlyAvg)) a month — set limits for your biggest categories.")
            }
        }
        if accountCount >= 2 { add(.accounts, "You have \(accountCount) accounts — compare credit cards and debit side by side.") }
        let subs = SpendingAnalytics.recurring(facts, now: now)
        if subs.count >= 2 {
            add(.recurring, "\(subs.count) recurring charges found, about \(money(subs.reduce(0) { $0 + $1.annualCost })) a year.")
        }
        if facts.contains(where: { !$0.items.isEmpty }) {
            add(.products, "Your Amazon orders and receipts list what you bought — see it at a glance.")
        }
        if !SpendingAnalytics.topMerchants(thisMonth, limit: 5).isEmpty {
            add(.topMerchantsChart, "A quick chart of the places that get most of your money.")
        }
        if LocalLLM.isAvailable { add(.ai, "Let the on-device AI write a monthly summary with a saving tip.") }
        return out
    }
}

private func ordinal(_ n: Int) -> String {
    if (11...13).contains(n % 100) { return "th" }
    switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
}

/// Choose, reorder and get suggestions for Insights cards.
struct CustomizeInsightsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("insightCards") private var layoutRaw = ""
    @AppStorage("dismissedCardSuggestions") private var dismissedRaw = ""
    let suggestions: [CardSuggestion]

    var body: some View {
        let layout = InsightCard.decode(layoutRaw)
        let hidden = InsightCard.allCases.filter { !layout.contains($0) }
        let pending = suggestions.filter { !layout.contains($0.card) }
        NavigationStack {
            List {
                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { s in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: s.card.symbol).foregroundStyle(.purple).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(s.card.title).bold()
                                    Text(s.reason).font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Button("Add") { add(s.card, to: layout) }.buttonStyle(.borderedProminent)
                                        Button("Not now") { dismissSuggestion(s.card) }.buttonStyle(.bordered)
                                    }
                                    .font(.caption)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Label("Suggested for you", systemImage: "sparkles")
                    }
                }
                Section {
                    ForEach(layout) { c in
                        Label(c.title, systemImage: c.symbol)
                    }
                    .onMove { from, to in
                        var l = layout
                        l.move(fromOffsets: from, toOffset: to)
                        layoutRaw = InsightCard.encode(l)
                    }
                    .onDelete { offsets in
                        var l = layout
                        l.remove(atOffsets: offsets)
                        layoutRaw = InsightCard.encode(l)
                    }
                } header: {
                    Text("Showing")
                } footer: {
                    Text("Drag to reorder, swipe to remove.")
                }
                if !hidden.isEmpty {
                    Section("More cards") {
                        ForEach(hidden) { c in
                            Button { add(c, to: layout) } label: {
                                HStack {
                                    Image(systemName: c.symbol).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.title).foregroundStyle(.primary)
                                        Text(c.blurb).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Reset to default layout") { layoutRaw = ""; dismissedRaw = "" }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customise Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func add(_ c: InsightCard, to layout: [InsightCard]) {
        layoutRaw = InsightCard.encode(layout + [c])
    }

    private func dismissSuggestion(_ c: InsightCard) {
        var set = Set(dismissedRaw.split(separator: ",").map(String.init))
        set.insert(c.rawValue)
        dismissedRaw = set.sorted().joined(separator: ",")
    }
}
