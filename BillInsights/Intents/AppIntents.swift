import AppIntents
import SwiftData
import BillCore

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

/// Logs an Apple Pay purchase. Designed for a Shortcuts "Transaction"
/// automation, which fires whenever you pay with a card in Wallet.
struct LogPurchaseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Purchase"
    static var description = IntentDescription(
        "Adds a purchase to Bill Insights. Use it in a Shortcuts “Transaction” automation to log every Apple Pay tap automatically.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: String

    @Parameter(title: "Card")
    var card: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let value = LiveMatcher.parseAmount(amount), value > 0 else {
            throw IntentFailure(message: "Couldn't read the amount “\(amount)”.")
        }
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw IntentFailure(message: "The merchant name is missing.") }

        let context = AppData.container.mainContext
        let rules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []
        let labeled = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.userSetCategory == true }))) ?? []
        let categorizer = Categorizer(rules: rules, labeled: labeled.map { ($0.merchant, $0.category) })
        let clean = MerchantNormalizer.normalize(name)
        let category = categorizer.categorize(merchant: clean, rawDescription: name, hint: nil).category

        let parsed = ParsedTransaction(date: Date(), rawDescription: name, amount: Decimal(value).rounded2,
                                       isCredit: false, account: card?.isEmpty == false ? card : nil,
                                       externalID: "applepay:\(UUID().uuidString)")
        let entry = LedgerEntry(parsed: parsed, merchant: clean, category: category, source: .applePay)
        context.insert(entry)
        try context.save()
        await Alerts.checkBudgets(context: context)

        let facts = AppData.facts(context: context)
        let monthTotal = SpendingAnalytics.totalSpend(SpendingAnalytics.inMonth(facts, Date()))
        return .result(dialog: "Logged \(SpendingAnalytics.money(value)) at \(clean) (\(category.displayName)). \(SpendingAnalytics.money(monthTotal)) spent this month.")
    }
}

/// "Hey Siri, how much did I spend in Bill Insights?"
struct MonthSpendingIntent: AppIntent {
    static var title: LocalizedStringResource = "Spending This Month"
    static var description = IntentDescription("Tells you how much you've spent this month and where.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = AppData.container.mainContext
        let facts = AppData.facts(context: context)
        let now = Date()
        let month = SpendingAnalytics.inMonth(facts, now)
        let spent = SpendingAnalytics.totalSpend(month)
        guard spent > 0 else { return .result(dialog: "No spending recorded yet this month.") }
        var text = "You've spent \(SpendingAnalytics.money(spent)) this month."
        if let top = SpendingAnalytics.byCategory(month).first {
            text += " Most of it on \(top.category.displayName.lowercased()), \(SpendingAnalytics.money(top.total))."
        }
        if let f = SpendingAnalytics.forecast(facts, month: now, now: now) {
            text += " You're on pace for about \(SpendingAnalytics.money(f))."
        }
        return .result(dialog: "\(text)")
    }
}

struct BillInsightsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MonthSpendingIntent(),
                    phrases: ["How much did I spend in \(.applicationName)",
                              "My spending in \(.applicationName)"],
                    shortTitle: "Spending This Month",
                    systemImageName: "chart.pie")
        AppShortcut(intent: LogPurchaseIntent(),
                    phrases: ["Log a purchase in \(.applicationName)"],
                    shortTitle: "Log Purchase",
                    systemImageName: "creditcard")
    }
}
