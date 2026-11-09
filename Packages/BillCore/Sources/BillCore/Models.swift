import Foundation

/// Spending categories used throughout the app.
public enum SpendCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case groceries
    case dining
    case transportation
    case fuel
    case shopping
    case subscriptions
    case utilities
    case phoneInternet
    case housing
    case insurance
    case health
    case personalCare
    case entertainment
    case travel
    case education
    case giftsDonations
    case fees
    case income
    case transfer
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groceries: return "Groceries"
        case .dining: return "Dining & Coffee"
        case .transportation: return "Transportation"
        case .fuel: return "Gas & Fuel"
        case .shopping: return "Shopping"
        case .subscriptions: return "Subscriptions"
        case .utilities: return "Utilities"
        case .phoneInternet: return "Phone & Internet"
        case .housing: return "Rent & Housing"
        case .insurance: return "Insurance"
        case .health: return "Health & Pharmacy"
        case .personalCare: return "Personal Care"
        case .entertainment: return "Entertainment"
        case .travel: return "Travel"
        case .education: return "Education"
        case .giftsDonations: return "Gifts & Donations"
        case .fees: return "Bank Fees & Interest"
        case .income: return "Income"
        case .transfer: return "Transfers & Payments"
        case .other: return "Other"
        }
    }

    /// Whether this category counts as spending in totals.
    public var isSpending: Bool {
        self != .income && self != .transfer
    }

    /// Plain-language description, used as an embedding "prototype" for the
    /// on-device semantic categoriser and as a hint for the LLM.
    public var prototype: String {
        switch self {
        case .groceries: return "grocery store supermarket food market produce butcher bakery"
        case .dining: return "restaurant cafe coffee shop fast food pizza bar pub takeout food delivery"
        case .transportation: return "public transit bus subway train taxi rideshare parking toll car"
        case .fuel: return "gas station fuel petrol diesel ev charging"
        case .shopping: return "retail store clothing electronics online shopping department store home goods"
        case .subscriptions: return "monthly subscription streaming music video software membership"
        case .utilities: return "electricity hydro water natural gas heating utility bill"
        case .phoneInternet: return "mobile phone wireless carrier cell plan internet provider cable"
        case .housing: return "rent mortgage property management condo fees landlord"
        case .insurance: return "insurance premium auto home life tenant policy"
        case .health: return "pharmacy drug store doctor dentist clinic hospital medical prescription"
        case .personalCare: return "hair salon barber spa beauty cosmetics gym fitness"
        case .entertainment: return "movies cinema concert tickets games bowling sports event"
        case .travel: return "airline flight hotel airbnb travel booking vacation"
        case .education: return "tuition school university college course books"
        case .giftsDonations: return "charity donation gift florist"
        case .fees: return "bank service fee interest charge overdraft annual fee"
        case .income: return "payroll salary deposit direct deposit income"
        case .transfer: return "payment thank you transfer e-transfer credit card payment"
        case .other: return "miscellaneous"
        }
    }
}

/// Where a document / transaction came from.
public enum DocumentKind: String, Codable, Sendable, CaseIterable {
    case cibcCSV
    case genericCSV
    case cibcCreditCardStatement
    case cibcBankStatement
    case amazonOrderHistory
    case receipt
    case aiExtracted
    case manual

    public var displayName: String {
        switch self {
        case .cibcCSV: return "CIBC CSV export"
        case .genericCSV: return "Bank CSV"
        case .cibcCreditCardStatement: return "CIBC credit card statement"
        case .cibcBankStatement: return "CIBC bank statement"
        case .amazonOrderHistory: return "Amazon order history"
        case .receipt: return "Receipt / bill"
        case .aiExtracted: return "Statement (read by on-device AI)"
        case .manual: return "Manual entry"
        }
    }
}

/// A transaction extracted from a document, before it is stored.
public struct ParsedTransaction: Hashable, Sendable, Codable {
    public var date: Date
    /// Raw description as it appeared on the statement.
    public var rawDescription: String
    /// Always a positive magnitude.
    public var amount: Decimal
    /// `true` when money came *in* (refund, payment received, deposit).
    public var isCredit: Bool
    /// Category hint supplied by the source (e.g. CIBC spend category).
    public var categoryHint: SpendCategory?
    public var account: String?
    /// Line items (e.g. Amazon products, receipt items).
    public var items: [String]
    /// Stable ID from the source (e.g. Amazon order ID).
    public var externalID: String?

    public init(date: Date,
                rawDescription: String,
                amount: Decimal,
                isCredit: Bool,
                categoryHint: SpendCategory? = nil,
                account: String? = nil,
                items: [String] = [],
                externalID: String? = nil) {
        self.date = date
        self.rawDescription = rawDescription
        self.amount = amount < 0 ? -amount : amount
        self.isCredit = isCredit
        self.categoryHint = categoryHint
        self.account = account
        self.items = items
        self.externalID = externalID
    }

    public var amountDouble: Double { NSDecimalNumber(decimal: amount).doubleValue }

    /// Fingerprint used to avoid importing the same transaction twice.
    public var fingerprint: String {
        if let externalID { return "ext:\(externalID)" }
        let day = DateParsing.isoDay.string(from: date)
        let desc = rawDescription.uppercased().filter { $0.isLetter || $0.isNumber }
        return "\(day)|\(amount)|\(isCredit ? "C" : "D")|\(desc.prefix(24))"
    }
}

public struct ParseResult: Sendable {
    public var kind: DocumentKind
    public var transactions: [ParsedTransaction]
    public var warnings: [String]

    public init(kind: DocumentKind, transactions: [ParsedTransaction], warnings: [String] = []) {
        self.kind = kind
        self.transactions = transactions
        self.warnings = warnings
    }

    public var isEmpty: Bool { transactions.isEmpty }
}
