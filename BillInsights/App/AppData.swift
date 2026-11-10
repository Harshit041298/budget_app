import Foundation
import SwiftData
import BillCore

/// One shared on-device database, used by the app UI and by Siri/Shortcuts
/// actions (which can run while the app is in the background).
enum AppData {
    @MainActor static let container: ModelContainer = {
        let schema = Schema([LedgerEntry.self, ImportedDocument.self, MerchantRule.self, CategoryBudget.self])
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
        return entries.map { $0.fact(countAmazonOrders: countAmazon) }
    }
}
