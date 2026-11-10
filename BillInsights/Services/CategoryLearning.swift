import Foundation
import SwiftData
import BillCore

/// Remembers a category choice for a merchant (used by the categoriser on
/// future imports) and applies it to existing transactions.
@MainActor
enum CategoryLearning {
    static func assign(_ category: SpendCategory, toMerchant merchant: String, context: ModelContext,
                       applyToAll: Bool = true, entry: LedgerEntry? = nil) {
        if let entry {
            entry.category = category
            entry.userSetCategory = true
        }
        let key = MerchantNormalizer.key(for: merchant)
        let existing = try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate<MerchantRule> { $0.merchantKey == key }))
        if let rule = existing?.first {
            rule.categoryRaw = category.rawValue
            rule.updatedAt = Date()
        } else {
            context.insert(MerchantRule(merchant: merchant, category: category))
        }
        if applyToAll {
            let same = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.merchant == merchant }))) ?? []
            for e in same where !e.userSetCategory || e.id == entry?.id {
                e.category = category
                e.userSetCategory = true
            }
        }
        try? context.save()
    }
}
