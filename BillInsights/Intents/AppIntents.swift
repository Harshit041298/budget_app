import AppIntents
import SwiftData
import BillCore

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

/// Logs a Wallet card purchase. Designed for a Shortcuts "Transaction"
/// automation, which fires whenever you pay with a card in Wallet.
///
/// Some card issuers don't share the merchant or amount with Wallet, so both
/// are optional: the purchase is always saved, and if the amount is missing
/// the user gets a notification to add it. Every run is recorded in a small
/// on-device log (Import → Apple Pay live logging) to help diagnose setup.
struct LogPurchaseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Purchase"
    static var description = IntentDescription(
        "Adds a purchase to Bill Insights. Use it in a Shortcuts “Transaction” automation to log every Wallet card payment automatically.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Merchant")
    var merchant: String?

    @Parameter(title: "Amount")
    var amount: String?

    @Parameter(title: "Card")
    var card: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rawMerchant = (merchant ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAmount = (amount ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCard = (card ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = LiveMatcher.parseAmount(rawAmount).flatMap { $0 > 0 ? $0 : nil }
        let name = rawMerchant.isEmpty ? "Apple Pay purchase" : rawMerchant

        do {
            let context = AppData.container.mainContext
            let categorizer = Categorizer.load(context)
            let clean = MerchantNormalizer.normalize(name)
            let result = categorizer.categorize(merchant: clean, rawDescription: name, hint: nil)
            let catalog = CategoryCatalog.load(context)

            let parsed = ParsedTransaction(date: Date(), rawDescription: name, amount: Decimal(value ?? 0).rounded2,
                                           isCredit: false, account: rawCard.isEmpty ? nil : rawCard,
                                           externalID: "applepay:\(UUID().uuidString)")
            let entry = LedgerEntry(parsed: parsed, merchant: clean, category: result.category, source: .applePay)
            entry.customCategoryKey = result.customKey
            entry.fingerprint = Privacy.hash(entry.fingerprint)
            entry.rawDescription = Redactor.redact(entry.rawDescription)
            if value == nil { entry.notes = "Amount missing — your card didn't share it with Wallet. Tap Amount to add it." }
            context.insert(entry)
            CategoryLearning.applyRules(to: [entry], context: context)
            ImportService.ensureAccounts(for: [entry], context: context)
            try context.save()
            let categoryName = catalog.info(for: entry).name

            guard let value else {
                ApplePayLog.record(merchant: !rawMerchant.isEmpty, amount: false, card: !rawCard.isEmpty,
                                   rawAmount: rawAmount, outcome: "Saved \(clean) without an amount")
                await Alerts.notifyMissingAmount(merchant: clean)
                return .result(dialog: "Logged a purchase at \(clean), but Wallet didn't provide the amount. Open Bill Insights to add it.")
            }
            await Alerts.checkBudgets(context: context)
            ApplePayLog.record(merchant: !rawMerchant.isEmpty, amount: true, card: !rawCard.isEmpty,
                               rawAmount: rawAmount, outcome: "Logged \(SpendingAnalytics.money(value)) at \(clean)")
            let facts = AppData.facts(context: context)
            let monthTotal = SpendingAnalytics.totalSpend(SpendingAnalytics.inMonth(facts, Date()))
            return .result(dialog: "Logged \(SpendingAnalytics.money(value)) at \(clean) (\(categoryName)). \(SpendingAnalytics.money(monthTotal)) spent this month.")
        } catch {
            ApplePayLog.record(merchant: !rawMerchant.isEmpty, amount: value != nil, card: !rawCard.isEmpty,
                               rawAmount: rawAmount, outcome: "Error: \(error.localizedDescription)")
            throw error
        }
    }
}

/// Last few automation runs, stored on device only, for troubleshooting.
enum ApplePayLog {
    static let key = "applePayRunLog"

    static func record(merchant: Bool, amount: Bool, card: Bool, rawAmount: String, outcome: String) {
        let time = Date().formatted(date: .abbreviated, time: .shortened)
        let received = "merchant \(merchant ? "✓" : "✗") · amount \(amount ? "✓" : (rawAmount.isEmpty ? "✗" : "✗ (\"\(rawAmount.prefix(20))\")")) · card \(card ? "✓" : "✗")"
        var log = UserDefaults.standard.stringArray(forKey: key) ?? []
        log.insert("\(time) — \(outcome)\n\(received)", at: 0)
        UserDefaults.standard.set(Array(log.prefix(15)), forKey: key)
    }

    static var entries: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
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
