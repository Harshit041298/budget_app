import SwiftUI
import SwiftData
import BillCore

/// Set a monthly savings goal; see the gap and a category-by-category cut plan
/// from real spending, apply it as budgets, and get on-device AI tips.
struct SavingsCoachView: View {
    @Environment(\.modelContext) private var context
    @Query private var entries: [LedgerEntry]
    @Query private var customs: [CustomCategory]
    @Query private var accounts: [Account]
    @Query private var budgets: [CategoryBudget]
    @AppStorage("countAmazonOrders") private var countAmazon = false
    @AppStorage("savingsTarget") private var target: Double = 0
    @AppStorage("incomeOverride") private var incomeOverride: Double = 0
    @State private var draftTarget: Double?
    @State private var draftIncome: Double?
    @State private var advice: GenSavingsAdvice?
    @State private var thinking = false
    @State private var adviceError: String?
    @State private var applied = false

    var body: some View {
        let catalog = CategoryCatalog(customs)
        let facts = entries.map { $0.fact(countAmazonOrders: countAmazon, catalog: catalog, accounts: AppData.accountMap(accounts)) }
        let goal = target > 0 ? target : 1200
        let baseline = SavingsPlanner.baseline(facts, incomeOverride: incomeOverride > 0 ? incomeOverride : nil)
        let plan = SavingsPlanner.plan(baseline, target: goal)
        let progress = SavingsProgress(facts: facts, target: goal, incomeOverride: incomeOverride > 0 ? incomeOverride : nil)

        List {
            Section {
                HStack {
                    Text("Save each month")
                    Spacer()
                    TextField("1200", value: $draftTarget, format: .currency(code: "CAD").precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .onSubmit { commit() }
                }
                HStack {
                    Text("Monthly take-home pay")
                    Spacer()
                    TextField(baseline.avgIncome > 0 && incomeOverride == 0 ? money(baseline.avgIncome) : "Auto",
                              value: $draftIncome, format: .currency(code: "CAD").precision(.fractionLength(0)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                        .onSubmit { commit() }
                }
                Button("Save goal") { commit() }
            } header: {
                Text("Your goal")
            } footer: {
                Text("Income is detected from deposits on imported chequing statements. If your pay goes to an account you haven't imported, enter it here.")
            }

            Section("Where you are (last \(max(baseline.months, 1)) month\(baseline.months == 1 ? "" : "s"))") {
                row("Average income", money(baseline.avgIncome))
                row("Average spending", money(baseline.avgSpend))
                row("Currently saving", money(baseline.avgSaved), color: baseline.avgSaved >= goal ? .green : (baseline.avgSaved >= 0 ? .orange : .red))
                if baseline.avgIncome == 0 {
                    Label("No income found. Import your chequing account or enter your pay above.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("This month") {
                ProgressView(value: min(max(progress.projected / goal, 0), 1))
                    .tint(progress.projected >= goal ? Color.green : Color.orange)
                Text(progress.summary).font(.subheadline)
            }

            Section {
                if plan.gap == 0 {
                    Label("You're already saving \(money(baseline.avgSaved)) a month — above your \(money(goal)) goal. Keep it up!",
                          systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Text("You need to free up about **\(money(plan.gap))** a month. Here's a plan using only flexible spending:")
                        .font(.subheadline)
                    ForEach(plan.cuts) { cut in
                        let info = catalog.info(key: cut.key)
                        HStack {
                            CategoryIcon(info: info, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.name)
                                Text("\(money(cut.currentMonthly)) → \(money(cut.targetMonthly)) a month")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("−\(money(cut.saving))").bold().foregroundStyle(.green)
                        }
                    }
                    if !plan.achievable {
                        Label("Even with these cuts you'd save about \(money(baseline.avgSaved + plan.plannedSaving)). Reaching \(money(goal)) would also need lower fixed costs (rent, phone plan, insurance) or more income.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        applyAsBudgets(plan)
                    } label: {
                        Label(applied ? "Budgets set ✓" : "Turn this plan into budgets", systemImage: "gauge.with.dots.needle.50percent")
                    }
                    .disabled(applied || plan.cuts.isEmpty)
                }
            } header: {
                Text("Plan")
            } footer: {
                Text("Rent, insurance, utilities and health costs are never cut. Budgets alert you at 80% and 100% each month.")
            }

            Section {
                if let advice {
                    Text(advice.summary).font(.subheadline.bold())
                    ForEach(Array(advice.tips.enumerated()), id: \.offset) { _, tip in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(tip.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                if tip.monthlySaving > 0 {
                                    Text("~\(money(tip.monthlySaving))/mo").font(.caption.bold()).foregroundStyle(.green)
                                }
                            }
                            Text(tip.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                switch LocalLLM.status {
                case .ready:
                    Button {
                        Task { await coach(plan: plan, facts: facts) }
                    } label: {
                        if thinking {
                            HStack { ProgressView(); Text("Thinking on-device…") }
                        } else {
                            Label(advice == nil ? "Get personal tips from on-device AI" : "Get new tips", systemImage: "sparkles")
                        }
                    }
                    .disabled(thinking || entries.isEmpty)
                case .unavailable(let why):
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
                if let adviceError { Text(adviceError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("AI coach")
            }
        }
        .navigationTitle("Savings coach")
        .onAppear {
            draftTarget = target > 0 ? target : 1200
            draftIncome = incomeOverride > 0 ? incomeOverride : nil
        }
    }

    private func row(_ title: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).bold().foregroundStyle(color)
        }
    }

    private func commit() {
        if let t = draftTarget, t > 0 { target = t }
        incomeOverride = max(0, draftIncome ?? 0)
        applied = false
        advice = nil
    }

    private func applyAsBudgets(_ plan: SavingsPlan) {
        for cut in plan.cuts {
            if let b = budgets.first(where: { $0.categoryRaw == cut.key }) {
                b.monthlyLimit = cut.targetMonthly
            } else {
                let b = CategoryBudget(category: cut.base, monthlyLimit: cut.targetMonthly)
                b.categoryRaw = cut.key
                context.insert(b)
            }
        }
        try? context.save()
        applied = true
        Task {
            await Alerts.requestPermission()
            await Alerts.checkBudgets(context: context)
        }
    }

    private func coach(plan: SavingsPlan, facts: [TxnFact]) async {
        thinking = true
        adviceError = nil
        defer { thinking = false }
        do {
            advice = try await LocalLLM.savingsAdvice(brief: SavingsPlanner.brief(plan, facts: facts))
        } catch {
            adviceError = "Couldn't get tips: \(error.localizedDescription)"
        }
    }
}

/// Saved-so-far and projected saving for the current month.
struct SavingsProgress {
    let projected: Double
    let summary: String

    init(facts: [TxnFact], target: Double, incomeOverride: Double?, now: Date = Date()) {
        let month = SpendingAnalytics.inMonth(facts, now)
        let incomeSoFar = SpendingAnalytics.totalIncome(month)
        let income = max(incomeOverride ?? 0, incomeSoFar)
        let projectedSpend = SpendingAnalytics.forecast(facts, month: now, now: now) ?? SpendingAnalytics.totalSpend(month)
        let p = income - projectedSpend
        projected = p
        if income == 0 {
            summary = "No income recorded this month yet. Projected spending: \(money(projectedSpend))."
        } else if p >= target {
            summary = "On track to save about \(money(p)) of your \(money(target)) goal. 🎉"
        } else {
            summary = "On pace to save about \(money(max(p, 0))) — \(money(target - max(p, 0))) short of \(money(target)). Spending \(money((target - p) / 30 * 7)) less per week would close it."
        }
    }
}
