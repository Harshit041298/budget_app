import Foundation
import FoundationModels
import BillCore

/// "Ask about my money" chat. The on-device LLM answers by calling tools that
/// run real queries over your transactions, so numbers come from your data,
/// not from the model's imagination.
@MainActor
final class FinanceAssistant {
    private var session: LanguageModelSession
    private let facts: [TxnFact]

    init(facts: [TxnFact], now: Date = Date()) {
        self.facts = facts
        session = Self.makeSession(facts: facts, now: now)
    }

    private static func makeSession(facts: [TxnFact], now: Date) -> LanguageModelSession {
        let range: String
        if let first = facts.map(\.date).min(), let last = facts.map(\.date).max() {
            range = "\(DateParsing.isoDay.string(from: first)) to \(DateParsing.isoDay.string(from: last))"
        } else {
            range = "no data yet"
        }
        let tools: [any Tool] = [
            SpendingTotalsTool(facts: facts),
            FindTransactionsTool(facts: facts),
            RecurringChargesTool(facts: facts, now: now),
            SavingsPlanTool(facts: facts, now: now)
        ]
        return LanguageModelSession(tools: tools, instructions: """
        You are a helpful personal-finance assistant running privately on the user's iPhone. \
        Today is \(DateParsing.isoDay.string(from: now)). The user's transactions cover \(range). \
        Always call a tool to get numbers; never guess amounts. Amounts are Canadian dollars. \
        Months are written yyyy-MM. Spending categories: \(categoryList(facts)). \
        Accounts: \(accountList(facts)). Use the account argument "credit" or "debit" to compare card types. \
        Answer in 1-4 short sentences.
        """)
    }

    private static func categoryList(_ facts: [TxnFact]) -> String {
        let custom = Set(facts.compactMap(\.customName))
        return (SpendCategory.allCases.map(\.rawValue) + custom.sorted()).joined(separator: ", ")
    }

    private static func accountList(_ facts: [TxnFact]) -> String {
        let names = Set(facts.compactMap { f in f.account.map { name in "\(name) (\(f.accountKind ?? "other"))" } })
        return names.isEmpty ? "unknown" : names.sorted().joined(separator: ", ")
    }

    func ask(_ question: String) async throws -> String {
        do {
            return try await session.respond(to: question).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize(_) {
            // Start a fresh conversation when the transcript gets too long.
            session = Self.makeSession(facts: facts, now: Date())
            return try await session.respond(to: question).content
        }
    }
}

// MARK: - Tools

private func monthRange(_ from: String, _ to: String) -> (Date?, Date?) {
    let start = from.isEmpty ? nil : DateParsing.isoMonth.date(from: from)
    let endMonth = to.isEmpty ? nil : DateParsing.isoMonth.date(from: to)
    return (start, endMonth.map { DateParsing.addMonths(1, to: $0) })
}

private func filterFacts(_ facts: [TxnFact], category: String, merchant: String, from: String, to: String,
                         account: String = "") -> [TxnFact] {
    let (start, end) = monthRange(from, to)
    let cat = SpendCategory(rawValue: category)
    let customName = category.trimmingCharacters(in: .whitespaces).lowercased()
    let m = merchant.lowercased()
    let acct = account.trimmingCharacters(in: .whitespaces).lowercased()
    return facts.filter { f in
        (start == nil || f.date >= start!) && (end == nil || f.date < end!)
            && (category.isEmpty || (cat != nil ? f.category == cat && f.customKey == nil : f.customName?.lowercased() == customName))
            && (acct.isEmpty || f.accountKind?.lowercased() == acct || (f.account?.lowercased().contains(acct) ?? false))
            && (m.isEmpty || f.merchant.lowercased().contains(m) || f.items.contains { $0.lowercased().contains(m) })
    }
}

struct SpendingTotalsTool: Tool {
    let name = "getSpendingTotals"
    let description = "Total spending, with a per-category and per-month breakdown, optionally filtered by category, merchant/product and month range."
    let facts: [TxnFact]

    @Generable
    struct Arguments {
        @Guide(description: "A spending category name, or empty string for all categories")
        var category: String
        @Guide(description: "Merchant or product name to filter by (e.g. 'Amazon', 'Tim Hortons'), or empty string")
        var merchant: String
        @Guide(description: "First month to include, yyyy-MM, or empty string for no limit")
        var fromMonth: String
        @Guide(description: "Last month to include, yyyy-MM, or empty string for no limit")
        var toMonth: String
        @Guide(description: "'credit' for credit cards, 'debit' for debit/chequing, an account name, or empty string for all accounts")
        var account: String
    }

    func call(arguments: Arguments) async throws -> String {
        let matched = filterFacts(facts, category: arguments.category, merchant: arguments.merchant,
                             from: arguments.fromMonth, to: arguments.toMonth, account: arguments.account)
        guard !matched.isEmpty else { return "No matching transactions." }
        let total = SpendingAnalytics.totalSpend(matched)
        let cats = SpendingAnalytics.byCategoryKey(matched).prefix(6)
            .map { "\($0.name): \(SpendingAnalytics.money($0.total))" }.joined(separator: ", ")
        let accts = SpendingAnalytics.byAccount(matched).prefix(5)
            .map { "\($0.account): \(SpendingAnalytics.money($0.spend))" }.joined(separator: ", ")
        let byMonth = Dictionary(grouping: matched) { DateParsing.isoMonth.string(from: $0.date) }
            .map { ($0.key, SpendingAnalytics.totalSpend($0.value)) }
            .sorted { $0.0 < $1.0 }.suffix(12)
            .map { "\($0.0): \(SpendingAnalytics.money($0.1))" }.joined(separator: ", ")
        return "Total spent: \(SpendingAnalytics.money(total)) across \(matched.count) transactions. By category: \(cats). By account: \(accts). By month: \(byMonth)."
    }
}

struct FindTransactionsTool: Tool {
    let name = "findTransactions"
    let description = "Lists individual transactions (largest first) matching a merchant/product, category and month range."
    let facts: [TxnFact]

    @Generable
    struct Arguments {
        @Guide(description: "Merchant or product name to search for, or empty string")
        var merchant: String
        @Guide(description: "A spending category name, or empty string")
        var category: String
        @Guide(description: "First month to include, yyyy-MM, or empty string")
        var fromMonth: String
        @Guide(description: "Last month to include, yyyy-MM, or empty string")
        var toMonth: String
    }

    func call(arguments: Arguments) async throws -> String {
        let matched = filterFacts(facts, category: arguments.category, merchant: arguments.merchant,
                             from: arguments.fromMonth, to: arguments.toMonth)
            .sorted { $0.amount > $1.amount }
        guard !matched.isEmpty else { return "No matching transactions." }
        return matched.prefix(12).map { f in
            var s = "\(DateParsing.isoDay.string(from: f.date)) \(f.merchant) \(f.isCredit ? "+" : "-")\(SpendingAnalytics.money(f.amount)) [\(f.categoryName)]\(f.account.map { acct in " on \(acct)" } ?? "")"
            if !f.items.isEmpty { s += " items: " + f.items.prefix(4).joined(separator: "; ") }
            return s
        }.joined(separator: "\n") + (matched.count > 12 ? "\n(\(matched.count - 12) more not shown)" : "")
    }
}

struct RecurringChargesTool: Tool {
    let name = "getRecurringCharges"
    let description = "Lists detected subscriptions and other recurring bills with their typical amount and yearly cost."
    let facts: [TxnFact]
    let now: Date

    @Generable
    struct Arguments {
        @Guide(description: "Maximum number of results, 1-20")
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let subs = SpendingAnalytics.recurring(facts, now: now).prefix(max(1, min(arguments.limit, 20)))
        guard !subs.isEmpty else { return "No recurring charges detected." }
        return subs.map {
            "\($0.merchant): \(SpendingAnalytics.money($0.typicalAmount)) \($0.cadence.rawValue), about \(SpendingAnalytics.money($0.annualCost))/year, next around \(DateParsing.isoDay.string(from: $0.nextExpected))"
        }.joined(separator: "\n")
    }
}

struct SavingsPlanTool: Tool {
    let name = "getSavingsPlan"
    let description = "Given a monthly savings target, returns the user's average income, spending, current saving, the gap, and how much to cut in each flexible category to close it."
    let facts: [TxnFact]
    let now: Date

    @Generable
    struct Arguments {
        @Guide(description: "Monthly savings target in dollars, e.g. 1500")
        var monthlyTarget: Double
    }

    func call(arguments: Arguments) async throws -> String {
        let override = UserDefaults.standard.double(forKey: "incomeOverride")
        let baseline = SavingsPlanner.baseline(facts, now: now, incomeOverride: override > 0 ? override : nil)
        let plan = SavingsPlanner.plan(baseline, target: max(0, arguments.monthlyTarget))
        return SavingsPlanner.brief(plan, facts: facts, now: now)
            + (plan.achievable ? "" : "\nThe flexible categories alone can't close the whole gap.")
    }
}
