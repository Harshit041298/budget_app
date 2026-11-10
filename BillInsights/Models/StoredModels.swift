import Foundation
import SwiftData
import BillCore

/// A single money movement stored on-device.
@Model
final class LedgerEntry {
    var id: UUID
    var date: Date
    var merchant: String
    var rawDescription: String
    var amount: Double
    var isCredit: Bool
    var categoryRaw: String
    var userSetCategory: Bool
    var sourceRaw: String
    var account: String?
    var itemsText: String
    var externalID: String?
    var fingerprint: String
    /// Amazon order-history rows are excluded by default because the same
    /// purchase also appears as a card charge.
    var excludedFromSpending: Bool
    var linkedEntryID: UUID?
    var notes: String
    var document: ImportedDocument?
    /// "custom:<uuid>" when filed under a user-created category.
    var customCategoryKey: String? = nil

    init(parsed: ParsedTransaction, merchant: String, category: SpendCategory, source: DocumentKind,
         excluded: Bool = false) {
        id = UUID()
        date = parsed.date
        self.merchant = merchant
        rawDescription = parsed.rawDescription
        amount = parsed.amountDouble
        isCredit = parsed.isCredit
        categoryRaw = category.rawValue
        userSetCategory = false
        sourceRaw = source.rawValue
        account = parsed.account
        itemsText = parsed.items.joined(separator: "\n")
        externalID = parsed.externalID
        fingerprint = parsed.fingerprint
        excludedFromSpending = excluded
        linkedEntryID = nil
        notes = ""
    }

    var category: SpendCategory {
        get { SpendCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var source: DocumentKind { DocumentKind(rawValue: sourceRaw) ?? .manual }

    var items: [String] {
        get { itemsText.isEmpty ? [] : itemsText.components(separatedBy: "\n") }
        set { itemsText = newValue.joined(separator: "\n") }
    }

    var signedAmount: Double { isCredit ? amount : -amount }

    /// Key of the category shown to the user (custom or built-in).
    var categoryKey: String { customCategoryKey ?? categoryRaw }

    func setCategory(_ info: CategoryInfo) {
        category = info.base
        customCategoryKey = info.isCustom ? info.key : nil
    }

    func fact(countAmazonOrders: Bool, catalog: CategoryCatalog? = nil, accounts: [String: Account] = [:]) -> TxnFact {
        let excluded = source == .amazonOrderHistory ? !countAmazonOrders : excludedFromSpending
        let custom = customCategoryKey.flatMap { catalog?.custom(key: $0) }
        let acct = account.flatMap { accounts[$0] }
        return TxnFact(id: id, date: date, merchant: merchant, amount: amount, isCredit: isCredit,
                       category: category, countsAsSpending: !excluded, items: items,
                       customKey: custom?.key, customName: custom?.name,
                       account: acct?.name ?? account, accountKind: acct?.kindRaw)
    }
}

/// A statement, receipt or export the user imported.
@Model
final class ImportedDocument {
    var id: UUID
    var filename: String
    var importedAt: Date
    var kindRaw: String
    var extractedText: String
    var notes: String
    @Relationship(deleteRule: .cascade, inverse: \LedgerEntry.document)
    var entries: [LedgerEntry] = []

    init(filename: String, kind: DocumentKind, extractedText: String, notes: String = "") {
        id = UUID()
        self.filename = filename
        importedAt = Date()
        kindRaw = kind.rawValue
        self.extractedText = extractedText
        self.notes = notes
    }

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .manual }
}

/// A category the user chose for a merchant; the categoriser learns from it.
@Model
final class MerchantRule {
    @Attribute(.unique) var merchantKey: String
    var merchant: String
    var categoryRaw: String
    var updatedAt: Date

    init(merchant: String, category: SpendCategory) {
        merchantKey = MerchantNormalizer.key(for: merchant)
        self.merchant = merchant
        categoryRaw = category.rawValue
        updatedAt = Date()
    }

    var category: SpendCategory { SpendCategory(rawValue: categoryRaw) ?? .other }
}

/// A monthly spending limit for one category.
@Model
final class CategoryBudget {
    @Attribute(.unique) var categoryRaw: String
    var monthlyLimit: Double

    init(category: SpendCategory, monthlyLimit: Double) {
        categoryRaw = category.rawValue
        self.monthlyLimit = monthlyLimit
    }

    var category: SpendCategory { SpendCategory(rawValue: categoryRaw) ?? .other }
}

/// A category the user created, e.g. "Pets" or "Car loan". It behaves like
/// its parent built-in category for analytics (spending vs. transfer etc.).
@Model
final class CustomCategory {
    @Attribute(.unique) var key: String
    var name: String
    var symbol: String
    var colorIndex: Int
    var baseRaw: String
    var createdAt: Date

    init(name: String, symbol: String, colorIndex: Int, base: SpendCategory) {
        key = "custom:\(UUID().uuidString)"
        self.name = name
        self.symbol = symbol
        self.colorIndex = colorIndex
        baseRaw = base.rawValue
        createdAt = Date()
    }

    var base: SpendCategory { SpendCategory(rawValue: baseRaw) ?? .other }
}

enum AccountKind: String, CaseIterable, Identifiable {
    case credit, debit, savings, cash, other
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .credit: return "Credit card"
        case .debit: return "Debit / Chequing"
        case .savings: return "Savings"
        case .cash: return "Cash"
        case .other: return "Other"
        }
    }
    var symbol: String {
        switch self {
        case .credit: return "creditcard.fill"
        case .debit: return "banknote.fill"
        case .savings: return "building.columns.fill"
        case .cash: return "dollarsign.circle.fill"
        case .other: return "wallet.pass.fill"
        }
    }
}

/// A bank account or card. `key` is the identifier stored on transactions
/// (e.g. "Card ••1234"); `name` is what the user sees and can rename.
@Model
final class Account {
    @Attribute(.unique) var key: String
    var name: String
    var kindRaw: String
    var createdAt: Date

    init(key: String, name: String? = nil, kind: AccountKind) {
        self.key = key
        self.name = name ?? key
        kindRaw = kind.rawValue
        createdAt = Date()
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}

/// A user rule such as "description contains UBER and amount > 40 → Travel".
/// Rules run on every import and win over automatic categorisation.
@Model
final class TransactionRule {
    var id: UUID
    var matchText: String
    var minAmount: Double?
    var maxAmount: Double?
    /// "any", "out" (purchases) or "in" (money received)
    var direction: String
    var categoryKey: String
    var accountKey: String?
    var createdAt: Date

    init(matchText: String, minAmount: Double? = nil, maxAmount: Double? = nil, direction: String = "any",
         categoryKey: String, accountKey: String? = nil) {
        id = UUID()
        self.matchText = matchText
        self.minAmount = minAmount
        self.maxAmount = maxAmount
        self.direction = direction
        self.categoryKey = categoryKey
        self.accountKey = accountKey
        createdAt = Date()
    }

    func matches(_ e: LedgerEntry) -> Bool {
        Self.matches(e, text: matchText, minAmount: minAmount, maxAmount: maxAmount,
                     direction: direction, accountKey: accountKey)
    }

    static func matches(_ e: LedgerEntry, text matchText: String, minAmount: Double?, maxAmount: Double?,
                        direction: String, accountKey: String?) -> Bool {
        let text = matchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !text.isEmpty {
            let hay = (e.rawDescription + " " + e.merchant).lowercased()
            guard hay.contains(text) else { return false }
        }
        if let minAmount, e.amount < minAmount { return false }
        if let maxAmount, e.amount > maxAmount { return false }
        if direction == "out" && e.isCredit { return false }
        if direction == "in" && !e.isCredit { return false }
        if let accountKey, !accountKey.isEmpty, e.account != accountKey { return false }
        return !text.isEmpty || minAmount != nil || maxAmount != nil || accountKey != nil
    }
}
