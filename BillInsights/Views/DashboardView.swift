import SwiftUI
import SwiftData
import Charts
import BillCore

/// Which slice of money the Insights tab is looking at.
enum SpendScope: Hashable {
    case all
    case kind(AccountKind)
    case account(String)   // account display name

    func includes(_ f: TxnFact) -> Bool {
        switch self {
        case .all: return true
        case .kind(let k): return f.accountKind == k.rawValue
        case .account(let name): return f.account == name
        }
    }

    var title: String {
        switch self {
        case .all: return "All accounts"
        case .kind(.credit): return "Credit cards"
        case .kind(.debit): return "Debit & chequing"
        case .kind(let k): return k.displayName
        case .account(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up.fill"
        case .kind(let k): return k.symbol
        case .account: return "creditcard"
        }
    }
}

struct DashboardView: View {
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Query private var budgets: [CategoryBudget]
    @Query private var customs: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @AppStorage("countAmazonOrders") private var countAmazon = false
    @State private var month: Date = DateParsing.startOfMonth(Date())
    @State private var scope: SpendScope = .all
    @State private var didPickInitialMonth = false
    @State private var report: GenInsightReport?
    @State private var reportMonth: Date?
    @State private var generating = false
    @State private var reportError: String?
    @State private var customizing = false
    @State private var calendarDay: Int?
    @AppStorage("insightCards") private var layoutRaw = ""
    @AppStorage("dismissedCardSuggestions") private var dismissedRaw = ""

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
                    let catalog = CategoryCatalog(customs)
                    let accountMap = AppData.accountMap(accounts)
                    let allFacts = entries.map { $0.fact(countAmazonOrders: countAmazon, catalog: catalog, accounts: accountMap) }
                    content(allFacts: allFacts, catalog: catalog)
                }
            }
            .navigationTitle("Insights")
            .toolbar {
                if !accounts.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { scopeMenu }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { customizing = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Customise cards")
                }
            }
            .sheet(isPresented: $customizing) {
                CustomizeInsightsView(suggestions: suggestions(currentFacts()))
            }
            .onAppear(perform: pickInitialMonth)
            .onChange(of: entries.count) { _, _ in pickInitialMonth() }
        }
    }

    private func currentFacts() -> [TxnFact] {
        let catalog = CategoryCatalog(customs)
        let map = AppData.accountMap(accounts)
        return entries.map { $0.fact(countAmazonOrders: countAmazon, catalog: catalog, accounts: map) }
    }

    private func suggestions(_ facts: [TxnFact]) -> [CardSuggestion] {
        let dismissed = Set(dismissedRaw.split(separator: ",").compactMap { InsightCard(rawValue: String($0)) })
        return CardSuggestion.make(facts: facts, visible: InsightCard.decode(layoutRaw), dismissed: dismissed,
                                   hasBudgets: !budgets.isEmpty, accountCount: accounts.count)
    }

    private func pickInitialMonth() {
        guard !didPickInitialMonth, let latest = entries.first?.date else { return }
        month = DateParsing.startOfMonth(latest)
        didPickInitialMonth = true
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Show", selection: $scope) {
                Label("All accounts", systemImage: SpendScope.all.symbol).tag(SpendScope.all)
                Label("Credit cards", systemImage: AccountKind.credit.symbol).tag(SpendScope.kind(.credit))
                Label("Debit & chequing", systemImage: AccountKind.debit.symbol).tag(SpendScope.kind(.debit))
            }
            Section("Accounts") {
                Picker("Account", selection: $scope) {
                    ForEach(accounts) { a in
                        Label(a.name, systemImage: a.kind.symbol).tag(SpendScope.account(a.name))
                    }
                }
            }
        } label: {
            Label(scope.title, systemImage: scope.symbol)
        }
    }

    @ViewBuilder
    private func content(allFacts: [TxnFact], catalog: CategoryCatalog) -> some View {
        let facts = allFacts.filter { scope.includes($0) }
        let monthFacts = SpendingAnalytics.inMonth(facts, month)
        let spend = SpendingAnalytics.totalSpend(monthFacts)

        ScrollView {
            VStack(spacing: 16) {
                monthPicker
                if scope != .all {
                    HStack {
                        Label("Showing \(scope.title)", systemImage: scope.symbol).font(.subheadline.bold())
                        Spacer()
                        Button("Show all") { scope = .all }.font(.subheadline)
                    }
                    .padding(.horizontal)
                }
                summaryCard(facts: facts, monthFacts: monthFacts, spend: spend)
                suggestionBanner(allFacts: allFacts)
                ForEach(InsightCard.decode(layoutRaw)) { card in
                    switch card {
                    case .savings: if scope == .all { savingsCard(facts: allFacts) }
                    case .review: reviewBanner(facts: facts, monthFacts: monthFacts, spend: spend)
                    case .accounts:
                        if scope == .all { accountsCard(monthFacts: SpendingAnalytics.inMonth(allFacts, month)) }
                    case .budgets: budgetsCard(facts: allFacts, catalog: catalog)
                    case .calendar: calendarCard(facts: facts)
                    case .categories: categoriesCard(monthFacts: monthFacts, spend: spend, catalog: catalog)
                    case .pace: paceCard(facts: facts)
                    case .history: historyCard(facts: facts)
                    case .categoryTrend: categoryTrendCard(facts: facts, catalog: catalog)
                    case .incomeVsSpend: incomeCard(facts: facts)
                    case .weekday: weekdayCard(facts: facts)
                    case .topMerchantsChart: merchantsChartCard(monthFacts: monthFacts)
                    case .ai: aiCard(facts: facts)
                    case .recurring: recurringCard(facts: facts)
                    case .unusual: unusualCard(facts: facts, monthFacts: monthFacts)
                    case .merchants: merchantsCard(monthFacts: monthFacts)
                    case .products: productsCard(monthFacts: monthFacts)
                    }
                }
                Button { customizing = true } label: {
                    Label("Customise cards", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .padding(.bottom, 60)
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func suggestionBanner(allFacts: [TxnFact]) -> some View {
        let s = suggestions(allFacts)
        if let first = s.first {
            Button { customizing = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.count == 1 ? "Suggested card: \(first.card.title)" : "\(s.count) suggested cards for you").bold()
                        Text(first.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }

    private func savingsCard(facts: [TxnFact]) -> some View {
        let target = UserDefaults.standard.double(forKey: "savingsTarget")
        let incomeOverride = UserDefaults.standard.double(forKey: "incomeOverride")
        return Card(title: "Savings goal", systemImage: "banknote") {
            if target > 0 {
                let progress = SavingsProgress(facts: facts, target: target, incomeOverride: incomeOverride > 0 ? incomeOverride : nil)
                let plan = SavingsPlanner.plan(SavingsPlanner.baseline(facts, incomeOverride: incomeOverride > 0 ? incomeOverride : nil), target: target)
                ProgressView(value: min(max(progress.projected / target, 0), 1))
                    .tint(progress.projected >= target ? Color.green : Color.orange)
                Text(progress.summary).font(.subheadline)
                ForEach(plan.cuts.prefix(3)) { cut in
                    HStack {
                        Text(cut.name).font(.caption)
                        Spacer()
                        Text("\(money(cut.currentMonthly)) → \(money(cut.targetMonthly))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                NavigationLink("Open savings coach") { SavingsCoachView() }.font(.subheadline)
            } else {
                Text("Tell the app how much you want to save each month (e.g. $1,200–$1,500) and it will show where to cut, from your real spending.")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink {
                    SavingsCoachView()
                } label: {
                    Label("Set a savings goal", systemImage: "target").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func calendarCard(facts: [TxnFact]) -> some View {
        Card(title: "Spending calendar", systemImage: "calendar.day.timeline.left") {
            SpendingCalendar(facts: facts, month: month, compact: false, selectedDay: $calendarDay)
            if let day = calendarDay {
                let cal = Calendar.current
                let dayFacts = SpendingAnalytics.inMonth(facts, month)
                    .filter { cal.component(.day, from: $0.date) == day && $0.spend != 0 }
                    .sorted { $0.amount > $1.amount }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(month.formatted(.dateTime.month(.abbreviated))) \(day): \(money(SpendingAnalytics.totalSpend(dayFacts)))")
                        .font(.subheadline.bold())
                    if dayFacts.isEmpty {
                        Text("No spending 🎉").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(dayFacts.prefix(5)) { f in
                        HStack {
                            Text(f.merchant).font(.caption)
                            Spacer()
                            Text(money(f.amount)).font(.caption)
                        }
                    }
                }
            }
            NavigationLink {
                SpendingCalendarScreen(facts: facts, month: month)
            } label: {
                Label("Open full calendar", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .font(.subheadline)
        }
    }

    private func paceCard(facts: [TxnFact]) -> some View {
        let thisMonth = SpendingAnalytics.cumulativeDaily(facts, month: month, upTo: Date())
        let lastMonth = SpendingAnalytics.cumulativeDaily(facts, month: DateParsing.addMonths(-1, to: month))
        let today = thisMonth.last
        let sameDayLast = today.flatMap { t in lastMonth.first { $0.day == min(t.day, lastMonth.count) } }
        return Card(title: "Spending pace", systemImage: "chart.line.uptrend.xyaxis") {
            if let today, let sameDayLast, sameDayLast.total > 0 {
                let diff = today.total - sameDayLast.total
                Text("\(money(abs(diff))) \(diff >= 0 ? "more" : "less") than at this point last month")
                    .font(.subheadline).foregroundStyle(diff >= 0 ? Color.red : Color.green)
            }
            Chart {
                ForEach(lastMonth) { p in
                    LineMark(x: .value("Day", p.day), y: .value("Spent", p.total), series: .value("Month", "Last month"))
                        .foregroundStyle(Color.gray.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
                ForEach(thisMonth) { p in
                    AreaMark(x: .value("Day", p.day), y: .value("Spent", p.total))
                        .foregroundStyle(Color.accentColor.opacity(0.15))
                    LineMark(x: .value("Day", p.day), y: .value("Spent", p.total), series: .value("Month", "This month"))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 3))
                }
            }
            .chartXScale(domain: 1...31)
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(compactMoney(d)) } } } }
            .frame(height: 180)
            HStack(spacing: 16) {
                Label("This month", systemImage: "line.diagonal").foregroundStyle(Color.accentColor)
                Label("Last month", systemImage: "line.diagonal").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func categoryTrendCard(facts: [TxnFact], catalog: CategoryCatalog) -> some View {
        let points = SpendingAnalytics.categoryTrend(facts, months: 6, endingAt: month, top: 5)
        if !points.isEmpty {
            let names = Array(NSOrderedSet(array: points.map(\.name))) as? [String] ?? []
            let colors: [Color] = names.map { name in
                if let p = points.first(where: { $0.name == name }), p.key != "_rest" { return catalog.info(key: p.key).color }
                return .gray
            }
            Card(title: "Category trends", systemImage: "chart.bar.xaxis") {
                Chart(points) { p in
                    BarMark(x: .value("Month", p.month, unit: .month), y: .value("Spent", p.total))
                        .foregroundStyle(by: .value("Category", p.name))
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(compactMoney(d)) } } } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 220)
            }
        }
    }

    @ViewBuilder
    private func incomeCard(facts: [TxnFact]) -> some View {
        let history = SpendingAnalytics.monthly(facts, months: 6, endingAt: month)
        if history.contains(where: { $0.income > 0 }) {
            let thisMonth = history.last
            Card(title: "Income vs spending", systemImage: "arrow.left.arrow.right.circle") {
                if let m = thisMonth, m.income > 0 {
                    let rate = (m.income - m.spend) / m.income * 100
                    Text(String(format: "Savings rate this month: %.0f%%", rate))
                        .font(.subheadline.bold())
                        .foregroundStyle(rate >= 0 ? Color.green : Color.red)
                }
                Chart {
                    ForEach(history) { m in
                        BarMark(x: .value("Month", m.month, unit: .month), y: .value("Amount", m.income))
                            .foregroundStyle(by: .value("Type", "Income"))
                            .position(by: .value("Type", "Income"))
                        BarMark(x: .value("Month", m.month, unit: .month), y: .value("Amount", m.spend))
                            .foregroundStyle(by: .value("Type", "Spending"))
                            .position(by: .value("Type", "Spending"))
                    }
                }
                .chartForegroundStyleScale(["Income": Color.green, "Spending": Color.pink])
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) }
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(compactMoney(d)) } } } }
                .frame(height: 180)
            }
        }
    }

    @ViewBuilder
    private func weekdayCard(facts: [TxnFact]) -> some View {
        let window = facts.filter { $0.date >= DateParsing.addMonths(-2, to: month) && $0.date < DateParsing.addMonths(1, to: month) }
        let days = SpendingAnalytics.byWeekday(window)
        if let top = days.max(by: { $0.average < $1.average }), top.average > 0 {
            let symbols = Calendar.current.shortWeekdaySymbols
            Card(title: "Spending by weekday", systemImage: "calendar") {
                Text("\(Calendar.current.weekdaySymbols[top.weekday - 1])s are your biggest day, about \(money(top.average)) on average.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Chart(days) { d in
                    BarMark(x: .value("Day", symbols[d.weekday - 1]), y: .value("Average", d.average))
                        .foregroundStyle(d.weekday == top.weekday ? Color.orange : Color.orange.opacity(0.4))
                        .cornerRadius(4)
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(compactMoney(d)) } } } }
                .frame(height: 160)
                Text("Average per day over the last 3 months").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func merchantsChartCard(monthFacts: [TxnFact]) -> some View {
        let merchants = SpendingAnalytics.topMerchants(monthFacts, limit: 8)
        if !merchants.isEmpty {
            Card(title: "Top merchants", systemImage: "chart.bar.doc.horizontal") {
                Chart(merchants) { m in
                    BarMark(x: .value("Spent", m.total), y: .value("Merchant", m.merchant))
                        .foregroundStyle(Color.indigo.gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing) {
                            Text(compactMoney(m.total)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(merchants.count) * 32 + 10)
            }
        }
    }

    private func summaryCard(facts: [TxnFact], monthFacts: [TxnFact], spend: Double) -> some View {
        let prevSpend = SpendingAnalytics.totalSpend(SpendingAnalytics.inMonth(facts, DateParsing.addMonths(-1, to: month)))
        let income = SpendingAnalytics.totalIncome(monthFacts)
        let forecast = SpendingAnalytics.forecast(facts, month: month)
        return Card {
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
    }

    @ViewBuilder
    private func reviewBanner(facts: [TxnFact], monthFacts: [TxnFact], spend: Double) -> some View {
        let otherTotal = SpendingAnalytics.totalSpend(monthFacts.filter { $0.categoryKey == SpendCategory.other.rawValue })
        let otherMerchants = Set(facts.filter { $0.categoryKey == SpendCategory.other.rawValue && !$0.isCredit }.map(\.merchant)).count
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
    }

    @ViewBuilder
    private func accountsCard(monthFacts: [TxnFact]) -> some View {
        let byAccount = SpendingAnalytics.byAccount(monthFacts)
        let credit = SpendingAnalytics.totalSpend(monthFacts.filter { $0.accountKind == AccountKind.credit.rawValue })
        let debit = SpendingAnalytics.totalSpend(monthFacts.filter { $0.accountKind == AccountKind.debit.rawValue })
        let total = SpendingAnalytics.totalSpend(monthFacts)
        let other = max(0, total - credit - debit)
        if byAccount.count > 0 && (credit > 0 || debit > 0) {
            Card(title: "Credit vs debit", systemImage: "creditcard.and.123") {
                Chart {
                    BarMark(x: .value("Spent", credit)).foregroundStyle(by: .value("Type", "Credit cards"))
                    BarMark(x: .value("Spent", debit)).foregroundStyle(by: .value("Type", "Debit & chequing"))
                    if other > 0.005 {
                        BarMark(x: .value("Spent", other)).foregroundStyle(by: .value("Type", "Other / unassigned"))
                    }
                }
                .chartXAxis(.hidden)
                .chartForegroundStyleScale(["Credit cards": Color.purple, "Debit & chequing": Color.teal, "Other / unassigned": Color.gray])
                .frame(height: 56)

                HStack {
                    scopeButton(.kind(.credit), amount: credit)
                    scopeButton(.kind(.debit), amount: debit)
                }

                Divider()
                ForEach(byAccount) { a in
                    Button {
                        scope = a.account == "Unassigned" ? .all : .account(a.account)
                    } label: {
                        HStack {
                            Image(systemName: (AccountKind(rawValue: a.kind ?? "") ?? .other).symbol)
                                .foregroundStyle(.tint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.account).foregroundStyle(.primary)
                                if a.kind == AccountKind.credit.rawValue && a.credits > 0 {
                                    Text("Payments made \(money(a.credits))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(money(a.spend)).bold().foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink("Manage accounts") { AccountsView() }.font(.subheadline)
            }
        }
    }

    private func scopeButton(_ s: SpendScope, amount: Double) -> some View {
        Button { scope = s } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(s.title, systemImage: s.symbol).font(.caption).foregroundStyle(.secondary)
                Text(money(amount)).font(.title3.bold()).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func budgetsCard(facts: [TxnFact], catalog: CategoryCatalog) -> some View {
        if !budgets.isEmpty {
            Card(title: "Budgets", systemImage: "gauge.with.dots.needle.50percent") {
                ForEach(budgets.sorted { catalog.info(key: $0.categoryRaw).name < catalog.info(key: $1.categoryRaw).name }) { b in
                    let info = catalog.info(key: b.categoryRaw)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            CategoryIcon(info: info, size: 24)
                            Text(info.name).font(.subheadline)
                        }
                        BudgetBar(spent: SpendingAnalytics.spend(forKey: b.categoryRaw, facts, month: month), limit: b.monthlyLimit)
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
    }

    @ViewBuilder
    private func categoriesCard(monthFacts: [TxnFact], spend: Double, catalog: CategoryCatalog) -> some View {
        let categories = SpendingAnalytics.byCategoryKey(monthFacts)
        if !categories.isEmpty {
            Card(title: "Where it went", systemImage: "chart.pie") {
                Chart(categories) { c in
                    SectorMark(angle: .value("Spent", c.total), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(catalog.info(key: c.key).color)
                }
                .frame(height: 200)
                ForEach(categories.prefix(10)) { c in
                    let info = catalog.info(key: c.key)
                    NavigationLink {
                        TransactionsView(initialCategoryKey: c.key, initialMonth: month)
                    } label: {
                        HStack {
                            CategoryIcon(info: info, size: 28)
                            Text(info.name)
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
    }

    private func historyCard(facts: [TxnFact]) -> some View {
        let history = SpendingAnalytics.monthly(facts, months: 6, endingAt: month)
        return Card(title: "Last 6 months", systemImage: "chart.bar") {
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
    }

    @ViewBuilder
    private func recurringCard(facts: [TxnFact]) -> some View {
        let now = DateParsing.addMonths(1, to: month)
        let recurring = SpendingAnalytics.recurring(facts, now: now)
        let changes = SpendingAnalytics.priceChanges(facts, now: now)
        let streaming = recurring.filter { SpendingAnalytics.streamingMerchants.contains($0.merchant) && $0.cadence == .monthly }
        if !recurring.isEmpty {
            Card(title: "Subscriptions & recurring", systemImage: "repeat") {
                let annual = recurring.reduce(0) { $0 + $1.annualCost }
                Text("About \(money(annual)) per year").font(.subheadline).foregroundStyle(.secondary)
                if streaming.count >= 2 {
                    Label("\(streaming.count) streaming services · \(money(streaming.reduce(0) { $0 + $1.typicalAmount }))/month. Do you use them all?",
                          systemImage: "play.tv.fill")
                        .font(.subheadline)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(changes) { c in
                    Label("\(c.merchant) went up \(money(c.oldAmount)) → \(money(c.newAmount))", systemImage: "arrow.up.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                ForEach(recurring.prefix(10)) { r in
                    HStack {
                        CategoryIcon(category: r.category, size: 28)
                        VStack(alignment: .leading) {
                            Text(r.merchant)
                            Text("\(r.cadence.rawValue.capitalized) · next ~\(r.nextExpected.shortDay) · \(money(r.annualCost))/yr")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(r.typicalAmount)).bold()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func unusualCard(facts: [TxnFact], monthFacts: [TxnFact]) -> some View {
        let unusual = SpendingAnalytics.anomalies(facts, in: monthFacts)
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
    }

    @ViewBuilder
    private func merchantsCard(monthFacts: [TxnFact]) -> some View {
        let merchants = SpendingAnalytics.topMerchants(monthFacts, limit: 6)
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
    }

    @ViewBuilder
    private func productsCard(monthFacts: [TxnFact]) -> some View {
        let products = monthFacts.filter { !$0.items.isEmpty && !$0.isCredit }
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
