import AppIntents
import SwiftData
import BillCore

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

/// Logs a Wallet card purchase. Designed for a Shortcuts "Transaction"
/// automation, which fires whenever you pay with a card in Wallet.
struct LogPurchaseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Purchase"
    static var description = IntentDescription(
        "Adds a purchase to Bill Insights. Use it in a Shortcuts “Transaction” automation to log every Wallet card payment automatically.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Amount")
    var amount: String

    @Parameter(title: "Card")
    var card: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IntentFailure(message: "No amount was received. If you pressed ▶ to test the automation, that's expected — Wallet only provides the amount on a real card tap.")
        }
        guard let value = LiveMatcher.parseAmount(amount), value > 0 else {
            throw IntentFailure(message: "Couldn't read the amount “\(amount)”.")
        }
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw IntentFailure(message: "The merchant name is missing.") }

        let context = AppData.container.mainContext
        let categorizer = Categorizer.load(context)
        let clean = MerchantNormalizer.normalize(name)
        let result = categorizer.categorize(merchant: clean, rawDescription: name, hint: nil)
        let catalog = CategoryCatalog.load(context)

        let parsed = ParsedTransaction(date: Date(), rawDescription: name, amount: Decimal(value).rounded2,
                                       isCredit: false, account: card?.isEmpty == false ? card : nil,
                                       externalID: "applepay:\(UUID().uuidString)")
        let entry = LedgerEntry(parsed: parsed, merchant: clean, category: result.category, source: .applePay)
        entry.customCategoryKey = result.customKey
        entry.fingerprint = Privacy.hash(entry.fingerprint)
        entry.rawDescription = Redactor.redact(entry.rawDescription)
        context.insert(entry)
        CategoryLearning.applyRules(to: [entry], context: context)
        ImportService.ensureAccounts(for: [entry], context: context)
        try context.save()
        let categoryName = catalog.info(for: entry).name
        await Alerts.checkBudgets(context: context)

        let facts = AppData.facts(context: context)
        let monthTotal = SpendingAnalytics.totalSpend(SpendingAnalytics.inMonth(facts, Date()))
        return .result(dialog: "Logged \(SpendingAnalytics.money(value)) at \(clean) (\(categoryName)). \(SpendingAnalytics.money(monthTotal)) spent this month.")
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
        if let top = SpendingAnalytics.byCategoryKey(month).first {
            text += " Most of it on \(top.name.lowercased()), \(SpendingAnalytics.money(top.total))."
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
