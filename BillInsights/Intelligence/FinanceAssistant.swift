import Foundation
import FoundationModels
import BillCore

/// "Ask about my money" chat.
///
/// The on-device model has a small (~4k token) window and is weak at maths, so
/// for every question the app first computes an exact fact sheet in code
/// (AskContextBuilder) and the model only turns it into a friendly answer.
/// Each question gets a fresh session carrying just the previous exchange, so
/// long chats never overflow.
@MainActor
final class FinanceAssistant {
    private let facts: [TxnFact]
    private var lastExchange: (question: String, answer: String)?

    init(facts: [TxnFact], now: Date = Date()) {
        self.facts = facts
    }

    private static let instructions = """
    You are a friendly personal-finance assistant on the user's iPhone. Amounts are Canadian dollars. \
    Answer ONLY from the data given; never invent numbers. Be specific: name merchants and amounts. \
    Never suggest cutting rent/housing, insurance, utilities or health costs. Reply in 2-5 short sentences.
    """

    func ask(_ question: String) async throws -> String {
        let target = UserDefaults.standard.double(forKey: "savingsTarget")
        let income = UserDefaults.standard.double(forKey: "incomeOverride")
        let context = AskContextBuilder.build(question: question, facts: facts,
                                              savingsTarget: target > 0 ? target : nil,
                                              incomeOverride: income > 0 ? income : nil)
        var prompt = "Today is \(DateParsing.isoDay.string(from: Date())).\nData (exact, computed by the app):\n\(context)\n"
        if let last = lastExchange {
            prompt += "\nPrevious question: \(last.question.prefix(200))\nPrevious answer: \(last.answer.prefix(300))\n"
        }
        prompt += "\nQuestion: \(question)"

        let answer: String
        do {
            let session = LanguageModelSession(tools: [FindTransactionsTool(facts: facts)], instructions: Self.instructions)
            answer = try await session.respond(to: prompt).content
        } catch {
            // Retry lean: no tools, no history, shorter data.
            do {
                let short = AskContextBuilder.build(question: question, facts: facts,
                                                    savingsTarget: target > 0 ? target : nil,
                                                    incomeOverride: income > 0 ? income : nil, maxCharacters: 900)
                let session = LanguageModelSession(instructions: Self.instructions)
                answer = try await session.respond(to: "Data:\n\(short)\n\nQuestion: \(question)").content
            } catch {
                // Last resort: show the computed facts directly.
                answer = "Here's what I found:\n" + context.split(separator: "\n").prefix(4).joined(separator: "\n")
            }
        }
        lastExchange = (question, answer)
        return answer
    }

    func reset() { lastExchange = nil }
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
        return matched.prefix(8).map { f in
            var s = "\(DateParsing.isoDay.string(from: f.date)) \(f.merchant) \(f.isCredit ? "+" : "-")\(SpendingAnalytics.money(f.amount)) [\(f.categoryName)]\(f.account.map { acct in " on \(acct)" } ?? "")"
            if !f.items.isEmpty { s += " items: " + f.items.prefix(4).joined(separator: "; ") }
            return s
        }.joined(separator: "\n") + (matched.count > 8 ? "\n(\(matched.count - 8) more not shown)" : "")
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
