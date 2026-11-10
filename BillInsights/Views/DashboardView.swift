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
            }
            .onAppear(perform: pickInitialMonth)
            .onChange(of: entries.count) { _, _ in pickInitialMonth() }
        }
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
                reviewBanner(facts: facts, monthFacts: monthFacts, spend: spend)
                if scope == .all {
                    accountsCard(monthFacts: SpendingAnalytics.inMonth(allFacts, month))
                }
                budgetsCard(facts: allFacts, catalog: catalog)
                categoriesCard(monthFacts: monthFacts, spend: spend, catalog: catalog)
                historyCard(facts: facts)
                aiCard(facts: facts)
                recurringCard(facts: facts)
                unusualCard(facts: facts, monthFacts: monthFacts)
                merchantsCard(monthFacts: monthFacts)
                productsCard(monthFacts: monthFacts)
            }
            .padding()
            .padding(.bottom, 60)
        }
    }

    // MARK: Cards

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
