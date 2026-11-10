import SwiftUI
import SwiftData
import BillCore

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query private var budgets: [CategoryBudget]
    @Query private var entries: [LedgerEntry]
    @AppStorage("countAmazonOrders") private var countAmazon = false
    @AppStorage("budgetAlertsEnabled") private var alertsEnabled = true

    private var categories: [SpendCategory] {
        SpendCategory.allCases.filter { $0.isSpending }
    }

    var body: some View {
        let facts = entries.map { $0.fact(countAmazonOrders: countAmazon) }
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
                    BudgetRow(category: c,
                              budget: budgets.first { $0.category == c },
                              spent: SpendingAnalytics.spend(in: c, facts, month: now)) { newLimit in
                        setLimit(newLimit, for: c)
                    }
                }
            }
        }
        .navigationTitle("Budgets")
    }

    private func setLimit(_ limit: Double?, for category: SpendCategory) {
        let existing = budgets.first { $0.category == category }
        if let limit, limit > 0 {
            if let existing { existing.monthlyLimit = limit } else {
                context.insert(CategoryBudget(category: category, monthlyLimit: limit))
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
    let category: SpendCategory
    let budget: CategoryBudget?
    let spent: Double
    let onChange: (Double?) -> Void
    @State private var value: Double?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CategoryIcon(category: category, size: 28)
                Text(category.displayName)
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
