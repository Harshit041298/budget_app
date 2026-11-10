import SwiftUI
import SwiftData
import Charts
import BillCore

struct DashboardView: View {
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Query private var budgets: [CategoryBudget]
    @AppStorage("countAmazonOrders") private var countAmazon = false
    @State private var month: Date = DateParsing.startOfMonth(Date())
    @State private var didPickInitialMonth = false
    @State private var report: GenInsightReport?
    @State private var reportMonth: Date?
    @State private var generating = false
    @State private var reportError: String?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No data yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Import a CIBC statement, CSV export, Amazon order history or a photo of a bill to see insights.")
                    }
                } else {
                    content(facts: entries.map { $0.fact(countAmazonOrders: countAmazon) })
                }
            }
            .navigationTitle("Insights")
            .onAppear(perform: pickInitialMonth)
            .onChange(of: entries.count) { _, _ in pickInitialMonth() }
        }
    }

    private func pickInitialMonth() {
        guard !didPickInitialMonth, let latest = entries.first?.date else { return }
        month = DateParsing.startOfMonth(latest)
        didPickInitialMonth = true
    }

    @ViewBuilder
    private func content(facts: [TxnFact]) -> some View {
        let monthFacts = SpendingAnalytics.inMonth(facts, month)
        let spend = SpendingAnalytics.totalSpend(monthFacts)
        let prevSpend = SpendingAnalytics.totalSpend(SpendingAnalytics.inMonth(facts, DateParsing.addMonths(-1, to: month)))
        let income = SpendingAnalytics.totalIncome(monthFacts)
        let categories = SpendingAnalytics.byCategory(monthFacts)
        let history = SpendingAnalytics.monthly(facts, months: 6, endingAt: month)
        let recurring = SpendingAnalytics.recurring(facts, now: DateParsing.addMonths(1, to: month))
        let unusual = SpendingAnalytics.anomalies(facts, in: monthFacts)
        let merchants = SpendingAnalytics.topMerchants(monthFacts, limit: 6)
        let products = monthFacts.filter { !$0.items.isEmpty && !$0.isCredit }
        let forecast = SpendingAnalytics.forecast(facts, month: month)
        let otherTotal = categories.first { $0.category == .other }?.total ?? 0
        let otherMerchants = Set(facts.filter { $0.category == .other && !$0.isCredit }.map(\.merchant)).count

        ScrollView {
            VStack(spacing: 16) {
                monthPicker

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Spent in \(month.monthYear)").font(.subheadline).foregroundStyle(.secondary)
                        Text(money(spend)).font(.system(size: 40, weight: .bold, design: .rounded))
                        if prevSpend > 0 {
                            let delta = spend - prevSpend
                            Label("\(money(abs(delta))) \(delta >= 0 ? "more" : "less") than last month",
                                  systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.subheadline)
                                .foregroundStyle(delta >= 0 ? Color.red : Color.green)
                        }
                        if income > 0 {
                            Text("Income \(money(income)) · Net \(money(income - spend))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let forecast {
                            Label("On pace for about \(money(forecast)) by month-end", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }

                if otherMerchants > 0 && (spend == 0 || otherTotal / max(spend, 1) > 0.05 || otherMerchants >= 5) {
                    NavigationLink {
                        CategoryReviewView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tag.fill")
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Review \(otherMerchants) uncategorised merchant\(otherMerchants == 1 ? "" : "s")").bold()
                                Text("Sort them once and future imports are categorised automatically.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding()
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }

                if !budgets.isEmpty {
                    Card(title: "Budgets", systemImage: "gauge.with.dots.needle.50percent") {
                        ForEach(budgets.sorted { $0.category.displayName < $1.category.displayName }) { b in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    CategoryIcon(category: b.category, size: 24)
                                    Text(b.category.displayName).font(.subheadline)
                                }
                                BudgetBar(spent: SpendingAnalytics.spend(in: b.category, facts, month: month), limit: b.monthlyLimit)
                            }
                        }
                        NavigationLink("Edit budgets") { BudgetsView() }.font(.subheadline)
                    }
                } else {
                    NavigationLink {
                        BudgetsView()
                    } label: {
                        Label("Set monthly budgets", systemImage: "gauge.with.dots.needle.50percent")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if !categories.isEmpty {
                    Card(title: "Where it went", systemImage: "chart.pie") {
                        Chart(categories) { c in
                            SectorMark(angle: .value("Spent", c.total), innerRadius: .ratio(0.62), angularInset: 1.5)
                                .cornerRadius(4)
                                .foregroundStyle(c.category.color)
                        }
                        .frame(height: 200)
                        ForEach(categories.prefix(7)) { c in
                            NavigationLink {
                                TransactionsView(initialCategory: c.category, initialMonth: month)
                            } label: {
                                HStack {
                                    CategoryIcon(category: c.category, size: 28)
                                    Text(c.category.displayName)
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Text(money(c.total)).bold()
                                        Text(spend > 0 ? "\(Int((c.total / spend * 100).rounded()))%" : "")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Card(title: "Last 6 months", systemImage: "chart.bar") {
                    Chart(history) { m in
                        BarMark(x: .value("Month", m.month, unit: .month), y: .value("Spent", m.spend))
                            .foregroundStyle(Calendar.current.isDate(m.month, equalTo: month, toGranularity: .month)
                                             ? Color.accentColor : Color.accentColor.opacity(0.35))
                            .cornerRadius(4)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                        }
                    }
                    .frame(height: 160)
                }

                aiCard(facts: facts)

                if !recurring.isEmpty {
                    Card(title: "Subscriptions & recurring", systemImage: "repeat") {
                        let annual = recurring.reduce(0) { $0 + $1.annualCost }
                        Text("About \(money(annual)) per year").font(.subheadline).foregroundStyle(.secondary)
                        ForEach(recurring.prefix(8)) { r in
                            HStack {
                                CategoryIcon(category: r.category, size: 28)
                                VStack(alignment: .leading) {
                                    Text(r.merchant)
                                    Text("\(r.cadence.rawValue.capitalized) · next ~\(r.nextExpected.shortDay)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(money(r.typicalAmount)).bold()
                            }
                        }
                    }
                }

                if !unusual.isEmpty {
                    Card(title: "Unusual charges", systemImage: "exclamationmark.triangle") {
                        ForEach(unusual.prefix(4)) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(a.fact.merchant).bold()
                                    Spacer()
                                    Text(money(a.fact.amount))
                                }
                                Text("\(a.fact.date.shortDay) · \(a.reason)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !merchants.isEmpty {
                    Card(title: "Top merchants", systemImage: "storefront") {
                        ForEach(merchants) { m in
                            HStack {
                                Text(m.merchant)
                                Text("×\(m.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(money(m.total)).bold()
                            }
                        }
                    }
                }

                if !products.isEmpty {
                    Card(title: "What you bought", systemImage: "shippingbox") {
                        ForEach(products.prefix(8)) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(p.merchant).bold()
                                    Spacer()
                                    Text(money(p.amount))
                                }
                                ForEach(p.items.prefix(4), id: \.self) { item in
                                    Text("• \(item)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, 60)
        }
    }

    private var monthPicker: some View {
        HStack {
            Button { month = DateParsing.addMonths(-1, to: month) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.monthYear).font(.headline)
            Spacer()
            Button { month = DateParsing.addMonths(1, to: month) } label: { Image(systemName: "chevron.right") }
                .disabled(month >= DateParsing.startOfMonth(Date()))
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func aiCard(facts: [TxnFact]) -> some View {
        Card(title: "AI insights", systemImage: "sparkles") {
            if let report, reportMonth == month {
                Text(report.headline).font(.subheadline.bold())
                ForEach(Array(report.insights.enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.title).font(.subheadline.weight(.semibold))
                        Text(i.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Label(report.savingTip, systemImage: "lightbulb.fill")
                    .font(.subheadline)
                    .padding(10)
                    .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(SpendingAnalytics.ruleInsights(facts, month: month), id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle").font(.subheadline)
                }
            }
            switch LocalLLM.status {
            case .ready:
                Button {
                    Task { await generate(facts: facts) }
                } label: {
                    if generating {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label(reportMonth == month ? "Regenerate with on-device AI" : "Generate with on-device AI",
                              systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating)
            case .unavailable(let why):
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            if let reportError {
                Text(reportError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func generate(facts: [TxnFact]) async {
        generating = true
        reportError = nil
        defer { generating = false }
        do {
            report = try await LocalLLM.insightReport(brief: SpendingAnalytics.llmBrief(facts, month: month))
            reportMonth = month
        } catch {
            reportError = "Couldn't generate insights: \(error.localizedDescription)"
        }
    }
}
