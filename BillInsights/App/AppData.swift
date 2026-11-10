import Foundation
import SwiftData
import BillCore

/// One shared on-device database, used by the app UI and by Siri/Shortcuts
/// actions (which can run while the app is in the background).
enum AppData {
    @MainActor static let container: ModelContainer = {
        let schema = Schema([LedgerEntry.self, ImportedDocument.self, MerchantRule.self, CategoryBudget.self,
                             CustomCategory.self, Account.self, TransactionRule.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError("Could not open the on-device database: \(error)")
        }
    }()

    @MainActor
    static func facts(context: ModelContext) -> [TxnFact] {
        let countAmazon = UserDefaults.standard.bool(forKey: "countAmazonOrders")
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        let catalog = CategoryCatalog.load(context)
        let accounts = accountMap((try? context.fetch(FetchDescriptor<Account>())) ?? [])
        return entries.map { $0.fact(countAmazonOrders: countAmazon, catalog: catalog, accounts: accounts) }
    }

    static func accountMap(_ accounts: [Account]) -> [String: Account] {
        var map: [String: Account] = [:]
        for a in accounts { map[a.key] = a }
        return map
    }
}
