import SwiftUI
import SwiftData
import BillCore

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query private var budgets: [CategoryBudget]
    @Query private var entries: [LedgerEntry]
    @Query private var customs: [CustomCategory]
    @Query private var accounts: [Account]
    @AppStorage("countAmazonOrders") private var countAmazon = false
    @AppStorage("budgetAlertsEnabled") private var alertsEnabled = true

    var body: some View {
        let catalog = CategoryCatalog(customs)
        let categories = catalog.all.filter { $0.base.isSpending }
        let facts = entries.map { $0.fact(countAmazonOrders: countAmazon, catalog: catalog, accounts: AppData.accountMap(accounts)) }
        let now = Date()
        List {
            Section {
                Toggle("Alert me at 80% and 100%", isOn: $alertsEnabled)
                    .onChange(of: alertsEnabled) { _, on in
                        if on { Task { await Alerts.requestPermission() } }
                    }
            } footer: {
                Text("Set a monthly limit for any category. Leave blank for no budget. Alerts are local notifications on this iPhone.")
            }
            Section("Monthly limits · \(now.monthYear)") {
                ForEach(categories) { c in
                    BudgetRow(info: c,
                              budget: budgets.first { $0.categoryRaw == c.key },
                              spent: SpendingAnalytics.spend(forKey: c.key, facts, month: now)) { newLimit in
                        setLimit(newLimit, forKey: c.key)
                    }
                }
            }
        }
        .navigationTitle("Budgets")
    }

    private func setLimit(_ limit: Double?, forKey key: String) {
        let existing = budgets.first { $0.categoryRaw == key }
        if let limit, limit > 0 {
            if let existing { existing.monthlyLimit = limit } else {
                let b = CategoryBudget(category: .other, monthlyLimit: limit)
                b.categoryRaw = key
                context.insert(b)
            }
            if alertsEnabled { Task { await Alerts.requestPermission() } }
        } else if let existing {
            context.delete(existing)
        }
        try? context.save()
        Task { await Alerts.checkBudgets(context: context) }
    }
}

private struct BudgetRow: View {
    let info: CategoryInfo
    let budget: CategoryBudget?
    let spent: Double
    let onChange: (Double?) -> Void
    @State private var value: Double?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CategoryIcon(info: info, size: 28)
                Text(info.name)
                Spacer()
                TextField("No limit", value: $value, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($focused)
                    .onSubmit { onChange(value) }
                    .onChange(of: focused) { _, f in if !f { onChange(value) } }
            }
            if let limit = budget?.monthlyLimit, limit > 0 {
                BudgetBar(spent: spent, limit: limit)
            } else if spent > 0 {
                Text("\(money(spent)) spent this month").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { value = budget?.monthlyLimit }
    }
}

struct BudgetBar: View {
    let spent: Double
    let limit: Double

    var body: some View {
        let ratio = limit > 0 ? spent / limit : 0
        let color: Color = ratio >= 1 ? .red : (ratio >= 0.8 ? .orange : .green)
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: min(ratio, 1))
                .tint(color)
            Text(ratio >= 1
                 ? "\(money(spent - limit)) over · \(money(spent)) of \(money(limit))"
                 : "\(money(limit - spent)) left · \(money(spent)) of \(money(limit))")
                .font(.caption).foregroundStyle(ratio >= 1 ? Color.red : Color.secondary)
        }
    }
}
