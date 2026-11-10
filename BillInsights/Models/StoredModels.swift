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

    func fact(countAmazonOrders: Bool) -> TxnFact {
        let excluded = source == .amazonOrderHistory ? !countAmazonOrders : excludedFromSpending
        return TxnFact(id: id, date: date, merchant: merchant, amount: amount, isCredit: isCredit,
                       category: category, countsAsSpending: !excluded, items: items)
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
