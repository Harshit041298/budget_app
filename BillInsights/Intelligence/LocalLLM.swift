import Foundation
import FoundationModels
import BillCore

/// Category identifiers the model may choose from (used by `@Guide(.anyOf:)`).
let spendCategoryNames: [String] = SpendCategory.allCases.map(\.rawValue)

// MARK: - Structured output types
//
// Apple's on-device Foundation Model (~3B parameters, runs fully offline on
// Apple Intelligence iPhones) fills these in via guided generation, so the
// output is always valid structured data rather than free text we must parse.

@Generable
struct GenReceipt {
    @Guide(description: "Name of the store, company or biller, e.g. 'Rogers' or 'Loblaws'")
    var merchant: String
    @Guide(description: "Purchase date or bill/statement date formatted as yyyy-MM-dd. Empty string if not shown.")
    var date: String
    @Guide(description: "The final total paid or amount due, including taxes. Not the subtotal.")
    var total: Double
    @Guide(description: "Spending category", .anyOf(spendCategoryNames))
    var category: String
    @Guide(description: "Purchased items or billed services", .maximumCount(20))
    var items: [GenItem]
}

@Generable
struct GenItem {
    @Guide(description: "Short item or service name")
    var name: String
    var price: Double
}

@Generable
struct GenStatementChunk {
    @Guide(description: "Every transaction line found in the text, in order", .maximumCount(40))
    var transactions: [GenTxn]
}

@Generable
struct GenTxn {
    @Guide(description: "Transaction date formatted as yyyy-MM-dd")
    var date: String
    @Guide(description: "Merchant or description exactly as written")
    var details: String
    @Guide(description: "Amount as a positive number")
    var amount: Double
    @Guide(description: "true only if money came INTO the account: deposits, refunds, payments received")
    var isCredit: Bool
}

@Generable
struct GenCategoryBatch {
    var assignments: [GenAssignment]
}

@Generable
struct GenAssignment {
    @Guide(description: "The merchant exactly as given")
    var merchant: String
    @Guide(description: "Best spending category", .anyOf(spendCategoryNames))
    var category: String
}

@Generable
struct GenInsightReport {
    @Guide(description: "One-sentence headline about this month's spending")
    var headline: String
    @Guide(description: "Specific, numeric insights grounded in the data", .count(4))
    var insights: [GenInsight]
    @Guide(description: "One concrete, practical way to save money next month, using the data")
    var savingTip: String
}

@Generable
struct GenInsight {
    @Guide(description: "Short title, 2-5 words")
    var title: String
    @Guide(description: "One or two sentences with the exact dollar figures from the data")
    var detail: String
}

// MARK: - Service

/// Wrapper around Apple's on-device LLM (Foundation Models framework).
@MainActor
enum LocalLLM {
    enum Status: Equatable {
        case ready
        case unavailable(String)
    }

    static var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This iPhone doesn't support Apple Intelligence. Rule-based parsing and on-device ML still work.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Turn on Apple Intelligence in Settings to enable the on-device AI.")
            case .modelNotReady:
                return .unavailable("The on-device model is still downloading. Try again shortly.")
            @unknown default:
                return .unavailable("The on-device model is unavailable.")
            }
        }
    }

    static var isAvailable: Bool { status == .ready }

    /// The model's context window is small (~4k tokens), so inputs are capped.
    static let maxChunkCharacters = 2_800

    private static let extractionInstructions = """
    You extract financial data from Canadian bank statements, bills and receipts. \
    Amounts are in Canadian dollars. Only use information present in the text; never invent values.
    """

    static func extractReceipt(from text: String, now: Date = Date()) async throws -> ParsedTransaction? {
        let session = LanguageModelSession(instructions: extractionInstructions)
        let prompt = """
        Today is \(DateParsing.isoDay.string(from: now)). Extract the merchant, date, total and items from this receipt or bill:

        \(String(text.prefix(maxChunkCharacters)))
        """
        let r = try await session.respond(to: prompt, generating: GenReceipt.self,
                                          options: GenerationOptions(temperature: 0))
        let g = r.content
        guard g.total > 0 else { return nil }
        let date = DateParsing.parseFullDate(g.date) ?? now
        return ParsedTransaction(date: date, rawDescription: g.merchant,
                                 amount: Decimal(g.total).rounded2, isCredit: false,
                                 categoryHint: SpendCategory(rawValue: g.category),
                                 items: g.items.map { item in
                                     item.price > 0 ? "\(item.name) — \(SpendingAnalytics.money(item.price))" : item.name
                                 })
    }

    /// Fallback for statement layouts the deterministic parsers don't know.
    static func extractStatement(from text: String, progress: (Double) -> Void = { _ in }) async throws -> [ParsedTransaction] {
        let resolverHint = DateParsing.allFullDates(in: text).max().map { DateParsing.isoDay.string(from: $0) } ?? ""
        let chunks = chunk(text)
        var out: [ParsedTransaction] = []
        for (i, c) in chunks.enumerated() {
            progress(Double(i) / Double(max(chunks.count, 1)))
            // Fresh session per chunk keeps us inside the context window.
            let session = LanguageModelSession(instructions: extractionInstructions)
            let prompt = """
            This is part \(i + 1) of \(chunks.count) of a bank or credit card statement\
            \(resolverHint.isEmpty ? "" : " that ends on \(resolverHint)"). \
            List every transaction. Skip balances, totals, headers and interest-rate tables.

            \(c)
            """
            do {
                let r = try await session.respond(to: prompt, generating: GenStatementChunk.self,
                                                  options: GenerationOptions(temperature: 0))
                for t in r.content.transactions where t.amount > 0 {
                    guard let date = DateParsing.parseFullDate(t.date) else { continue }
                    out.append(ParsedTransaction(date: date, rawDescription: t.details,
                                                 amount: Decimal(t.amount).rounded2, isCredit: t.isCredit))
                }
            } catch {
                // Skip a chunk the model can't handle rather than failing the import.
                continue
            }
        }
        progress(1)
        return out
    }

    /// Categorises merchants the rules and the embedding model weren't sure about.
    static func categorize(_ merchants: [(merchant: String, description: String)]) async -> [String: SpendCategory] {
        var result: [String: SpendCategory] = [:]
        let batches = stride(from: 0, to: merchants.count, by: 12).map {
            Array(merchants[$0..<min($0 + 12, merchants.count)])
        }
        for batch in batches {
            let session = LanguageModelSession(instructions: """
            You categorise Canadian card transactions. Categories: \
            \(SpendCategory.allCases.map { "\($0.rawValue) (\($0.displayName))" }.joined(separator: ", ")).
            """)
            let list = batch.map { "- \($0.merchant) [raw: \($0.description.prefix(60))]" }.joined(separator: "\n")
            do {
                let r = try await session.respond(to: "Assign a category to each merchant:\n\(list)",
                                                  generating: GenCategoryBatch.self,
                                                  options: GenerationOptions(temperature: 0))
                for a in r.content.assignments {
                    if let cat = SpendCategory(rawValue: a.category) { result[a.merchant] = cat }
                }
            } catch {
                continue
            }
        }
        return result
    }

    static func insightReport(brief: String) async throws -> GenInsightReport {
        let session = LanguageModelSession(instructions: """
        You are a friendly, concise personal-finance coach. Use ONLY the numbers in the data provided. \
        Never make up merchants or amounts. Amounts are in Canadian dollars.
        """)
        let r = try await session.respond(to: "Here is my spending data:\n\(brief)\n\nWrite my monthly insight report.",
                                          generating: GenInsightReport.self)
        return r.content
    }

    static func chunk(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if current.count + line.count + 1 > maxChunkCharacters {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

extension Decimal {
    var rounded2: Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 2, .plain)
        return result
    }
}
