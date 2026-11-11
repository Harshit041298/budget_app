import Foundation
import SwiftData
import BillCore

/// Remembers a category choice for a merchant (used by the categoriser on
/// future imports) and applies it to existing transactions.
@MainActor
enum CategoryLearning {
    static func assign(_ info: CategoryInfo, toMerchant merchant: String, context: ModelContext,
                       applyToAll: Bool = true, entry: LedgerEntry? = nil) {
        if let entry {
            entry.setCategory(info)
            entry.userSetCategory = true
        }
        let key = MerchantNormalizer.key(for: merchant)
        let existing = try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate<MerchantRule> { $0.merchantKey == key }))
        if let rule = existing?.first {
            rule.categoryRaw = info.key
            rule.updatedAt = Date()
        } else {
            let rule = MerchantRule(merchant: merchant, category: info.base)
            rule.categoryRaw = info.key
            context.insert(rule)
        }
        if applyToAll {
            let same = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.merchant == merchant }))) ?? []
            for e in same where !e.userSetCategory || e.id == entry?.id {
                e.setCategory(info)
                e.userSetCategory = true
            }
        }
        try? context.save()
    }

    static func assign(_ category: SpendCategory, toMerchant merchant: String, context: ModelContext,
                       applyToAll: Bool = true, entry: LedgerEntry? = nil) {
        assign(.builtin(category), toMerchant: merchant, context: context, applyToAll: applyToAll, entry: entry)
    }

    /// Applies the user's transaction rules to the given entries. Returns how many changed.
    @discardableResult
    static func applyRules(to entries: [LedgerEntry], context: ModelContext) -> Int {
        let rules = ((try? context.fetch(FetchDescriptor<TransactionRule>())) ?? []).sorted { $0.createdAt > $1.createdAt }
        guard !rules.isEmpty else { return 0 }
        let catalog = CategoryCatalog.load(context)
        var changed = 0
        for e in entries {
            guard let rule = rules.first(where: { $0.matches(e) }) else { continue }
            let info = catalog.info(key: rule.categoryKey)
            if e.categoryKey != info.key {
                e.setCategory(info)
                changed += 1
            }
        }
        return changed
    }

    /// Removes a custom category: its transactions fall back to the parent
    /// category, and rules/budgets that used it are deleted.
    static func delete(_ custom: CustomCategory, context: ModelContext) {
        let key = custom.key
        let optionalKey: String? = key
        let entries = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.customCategoryKey == optionalKey }))) ?? []
        for e in entries { e.customCategoryKey = nil }
        for r in (try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate<MerchantRule> { $0.categoryRaw == key }))) ?? [] {
            context.delete(r)
        }
        for r in (try? context.fetch(FetchDescriptor<TransactionRule>(predicate: #Predicate<TransactionRule> { $0.categoryKey == key }))) ?? [] {
            context.delete(r)
        }
        for b in (try? context.fetch(FetchDescriptor<CategoryBudget>(predicate: #Predicate<CategoryBudget> { $0.categoryRaw == key }))) ?? [] {
            context.delete(b)
        }
        context.delete(custom)
        try? context.save()
    }
}
