import Foundation
import FoundationModels
import BillCore

/// Where an answer came from — shown under each reply.
enum AnswerSource: Equatable {
    case calculated          // exact, computed on device by AskEngine
    case cloud(String)       // Claude model name; only a summary was sent
    case onDevice            // Apple's on-device model
    case facts               // model failed; raw computed facts shown

    var label: String {
        switch self {
        case .calculated: return "Calculated from your data on this iPhone"
        case .cloud(let detail): return detail
        case .onDevice: return "On-device AI"
        case .facts: return "Computed facts"
        }
    }
}

struct AskReply {
    let text: String
    let source: AnswerSource
    var proposal: ChangeProposal? = nil
    var steps: [String] = []
}

/// "Ask about my money" chat.
///
/// 1. AskEngine answers number questions exactly, with no model at all.
/// 2. Open-ended / advice questions go to Claude if the user enabled it,
///    otherwise to Apple's on-device model — either way with an exact fact
///    sheet computed by the app (AskContextBuilder), so the model never does maths.
@MainActor
final class FinanceAssistant {
    private let facts: [TxnFact]
    private var lastExchange: (question: String, answer: String)?
    private var lastQuery: AskEngine.Query?
    private let agent: ClaudeAgent

    private var pendingNote: String?

    init(facts: [TxnFact], budgets: [(name: String, key: String, limit: Double)] = [],
         catalog: CategoryCatalog = CategoryCatalog([]), now: Date = Date()) {
        self.facts = facts
        agent = ClaudeAgent(facts: facts, budgets: budgets, catalog: catalog)
    }

    /// Called after the user applied or undid a proposal: refresh Claude's data
    /// and tell it on the next message.
    func dataChanged(facts: [TxnFact], budgets: [(name: String, key: String, limit: Double)],
                     catalog: CategoryCatalog, note: String?) {
        agent.update(facts: facts, budgets: budgets, catalog: catalog)
        if let note { pendingNote = note }
    }

    var agentHistory: [[String: Any]] { agent.history }

    func restore(agentHistory: [[String: Any]], lastQuestion: String?, lastAnswer: String?) {
        agent.restore(history: agentHistory)
        if let q = lastQuestion, let a = lastAnswer { lastExchange = (q, a) }
    }

    private static let instructions = """
    You are a friendly, practical personal-finance assistant for a user in Canada. Amounts are Canadian dollars. \
    Answer ONLY from the data given; never invent numbers, merchants or dates. Be specific: name merchants and amounts. \
    Never suggest cutting rent/housing, insurance, utilities or health costs. Keep replies short: 2-6 sentences or a few bullets.
    """

    func ask(_ question: String, onStep: ((String) -> Void)? = nil) async -> AskReply {
        agent.onStep = onStep
        // Claude (when enabled) handles every question as an agent with read-only lookups.
        if CloudAI.isReady {
            do {
                let message = pendingNote.map { "(\($0))\n\(question)" } ?? question
                pendingNote = nil
                let text = try await agent.send(message)
                let n = agent.lookupsLastAnswer
                let detail = "\(CloudAI.model.displayName)" + (n > 0 ? " · checked your data \(n)×" : "")
                lastExchange = (question, text)
                return AskReply(text: text, source: .cloud(detail), proposal: agent.pendingProposal,
                                steps: agent.stepsLastAnswer)
            } catch {
                let local = await localAnswer(question, allowCloud: false)
                return AskReply(text: local.text + "\n\n_(Claude unavailable: \(error.localizedDescription))_", source: local.source)
            }
        }
        return await localAnswer(question, allowCloud: false)
    }

    private func localAnswer(_ question: String, allowCloud: Bool) async -> AskReply {
        let now = Date()
        let query = AskEngine.parse(question, facts: facts, previous: lastQuery, now: now)
        lastQuery = query
        if let exact = AskEngine.answer(query, facts: facts, now: now) {
            lastExchange = (question, exact)
            return AskReply(text: exact, source: .calculated)
        }

        let target = UserDefaults.standard.double(forKey: "savingsTarget")
        let income = UserDefaults.standard.double(forKey: "incomeOverride")
        let allFacts = self.facts
        let enriched = question + (query.hasSubject ? " (about: \(query.subjectText))" : "")
        func factSheet(_ max: Int) -> String {
            AskContextBuilder.build(question: enriched, facts: allFacts, now: now,
                                    savingsTarget: target > 0 ? target : nil,
                                    incomeOverride: income > 0 ? income : nil, maxCharacters: max)
        }
        var prompt = "Today is \(DateParsing.isoDay.string(from: now)).\nData (exact, computed by the app):\n"
        if let last = lastExchange {
            prompt += ""
            prompt = "Previous question: \(last.question.prefix(200))\nPrevious answer: \(last.answer.prefix(400))\n\n" + prompt
        }

        if allowCloud && CloudAI.isReady {
            do {
                let text = try await CloudAI.complete(system: Self.instructions,
                                                      prompt: prompt + factSheet(4000) + "\n\nQuestion: \(question)")
                lastExchange = (question, text)
                return AskReply(text: text, source: .cloud(CloudAI.model.displayName))
            } catch {
                // Fall through to the on-device model, but tell the user why.
                let local = await onDevice(prompt: prompt, sheet: factSheet, question: question)
                return AskReply(text: local.text + "\n\n_(Claude unavailable: \(error.localizedDescription))_", source: local.source)
            }
        }
        return await onDevice(prompt: prompt, sheet: factSheet, question: question)
    }

    private func onDevice(prompt: String, sheet: (Int) -> String, question: String) async -> AskReply {
        guard LocalLLM.isAvailable else {
            return AskReply(text: "Here's what I found:\n" + sheet(1200), source: .facts)
        }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let text = try await session.respond(to: prompt + sheet(1800) + "\n\nQuestion: \(question)").content
            lastExchange = (question, text)
            return AskReply(text: text, source: .onDevice)
        } catch {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let text = try await session.respond(to: "Data:\n\(sheet(900))\n\nQuestion: \(question)").content
                lastExchange = (question, text)
                return AskReply(text: text, source: .onDevice)
            } catch {
                return AskReply(text: "Here's what I found:\n" + sheet(1200), source: .facts)
            }
        }
    }

    func reset() {
        lastExchange = nil
        lastQuery = nil
        agent.reset()
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
