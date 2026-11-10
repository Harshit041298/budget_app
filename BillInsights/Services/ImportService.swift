import Foundation
import SwiftData
import UIKit
import BillCore

struct ImportSummary: Identifiable {
    let id = UUID()
    var filename: String
    var kind: DocumentKind
    var added: Int
    var duplicates: Int
    var linkedOrders: Int
    var mergedApplePay: Int = 0
    var usedAI: Bool
    var warnings: [String]
}

/// Orchestrates: file → text (PDFKit / Vision OCR) → parser (BillCore) or
/// on-device LLM → categoriser → dedupe → SwiftData.
@MainActor
@Observable
final class ImportService {
    var isImporting = false
    var status = ""
    var summaries: [ImportSummary] = []
    var errorMessage: String?

    // MARK: Entry points

    func importFiles(_ urls: [URL], context: ModelContext) async {
        isImporting = true
        defer { isImporting = false; status = "" }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                Privacy.deleteInboxCopy(url)
            }
            let name = url.lastPathComponent
            do {
                status = "Reading \(name)…"
                let ext = url.pathExtension.lowercased()
                let summary: ImportSummary
                switch ext {
                case "pdf":
                    let text = try await TextExtraction.text(fromPDF: url)
                    summary = try await process(text: text, isCSV: false, filename: name, context: context)
                case "csv", "tsv":
                    let text = try readText(url)
                    summary = try await process(text: text, isCSV: true, filename: name, context: context)
                case "txt":
                    let text = try readText(url)
                    summary = try await process(text: text, isCSV: false, filename: name, context: context)
                default:
                    let data = try Data(contentsOf: url)
                    guard let image = UIImage(data: data) else {
                        throw TextExtraction.Failure.noText
                    }
                    status = "Scanning \(name) with on-device OCR…"
                    let text = try await TextExtraction.ocr(image)
                    summary = try await process(text: text, isCSV: false, filename: name, context: context)
                }
                summaries.insert(summary, at: 0)
            } catch {
                errorMessage = "\(name): \(error.localizedDescription)"
            }
        }
    }

    func importImages(_ images: [UIImage], name: String, context: ModelContext) async {
        guard !images.isEmpty else { return }
        isImporting = true
        defer { isImporting = false; status = "" }
        do {
            status = "Scanning \(images.count) page\(images.count == 1 ? "" : "s") with on-device OCR…"
            let text = try await TextExtraction.ocr(images: images)
            let summary = try await process(text: text, isCSV: false, filename: name, context: context)
            summaries.insert(summary, at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Pipeline

    private func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw TextExtraction.Failure.noText
    }

    func process(text: String, isCSV: Bool, filename: String, context: ModelContext) async throws -> ImportSummary {
        status = "Finding transactions…"
        var result = DocumentRouter.parse(isCSV ? .csv(text) : .text(text))
        var usedAI = false

        if !isCSV && LocalLLM.isAvailable {
            if result.isEmpty && looksMultiLine(text) {
                status = "Reading statement with on-device AI…"
                let txns = try await LocalLLM.extractStatement(from: text) { p in
                    self.status = "Reading statement with on-device AI… \(Int(p * 100))%"
                }
                if !txns.isEmpty {
                    result = ParseResult(kind: .aiExtracted, transactions: txns,
                                         warnings: ["Extracted by the on-device AI — please double-check amounts."])
                    usedAI = true
                }
            } else if result.kind == .receipt {
                status = "Reading receipt with on-device AI…"
                if let t = try? await LocalLLM.extractReceipt(from: text) {
                    result = ParseResult(kind: .receipt, transactions: [t])
                    usedAI = true
                }
            }
        }

        guard !result.isEmpty else {
            throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No transactions found. Try the CSV download from CIBC online banking, or a clearer photo."])
        }

        status = "Categorising…"
        let categorizer = Categorizer.load(context)

        let existing = Set(((try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []).map(\.fingerprint))
        // The original statement text is only used in memory for parsing; what
        // is stored is redacted (or nothing, by default).
        let doc = ImportedDocument(filename: Redactor.redact(filename), kind: result.kind,
                                   extractedText: Privacy.storedText(text),
                                   notes: result.warnings.joined(separator: "\n"))
        context.insert(doc)

        var added: [LedgerEntry] = []
        var unsure: [String: [LedgerEntry]] = [:]
        var duplicates = 0
        var seenThisFile = Set<String>()
        for parsed in result.transactions {
            let fp = Privacy.hash(parsed.fingerprint)
            if existing.contains(fp) || !seenThisFile.insert(fp).inserted {
                duplicates += 1
                continue
            }
            let merchant = result.kind == .amazonOrderHistory ? "Amazon" : MerchantNormalizer.normalize(parsed.rawDescription)
            let cat = categorizer.categorize(merchant: merchant, rawDescription: parsed.rawDescription, hint: parsed.categoryHint)
            let entry = LedgerEntry(parsed: parsed, merchant: merchant, category: cat.category, source: result.kind,
                                    excluded: result.kind == .amazonOrderHistory)
            // Credits in a spending category are refunds; other credits are usually payments or deposits.
            if parsed.isCredit && cat.source == .fallback { entry.category = .transfer }
            entry.customCategoryKey = cat.customKey
            entry.fingerprint = fp
            entry.rawDescription = Redactor.redact(parsed.rawDescription)
            entry.account = Self.accountKey(for: parsed, kind: result.kind)
            entry.document = doc
            context.insert(entry)
            added.append(entry)
            if !cat.isConfident && !parsed.isCredit { unsure[merchant, default: []].append(entry) }
        }

        if !unsure.isEmpty && LocalLLM.isAvailable {
            status = "Asking on-device AI about \(unsure.count) merchant\(unsure.count == 1 ? "" : "s")…"
            let request = unsure.prefix(36).map { (merchant: $0.key, description: $0.value.first?.rawDescription ?? "") }
            let answers = await LocalLLM.categorize(request)
            for (merchant, cat) in answers {
                unsure[merchant]?.forEach { $0.category = cat }
            }
            if !answers.isEmpty { usedAI = true }
        }

        CategoryLearning.applyRules(to: added, context: context)
        Self.ensureAccounts(for: added, context: context)
        let linked = linkAmazonOrders(context: context)
        let merged = mergeApplePay(into: added, kind: result.kind, context: context)
        try context.save()
        await Alerts.checkBudgets(context: context)
        await Alerts.rescheduleBillReminders(context: context)

        return ImportSummary(filename: filename, kind: result.kind, added: added.count, duplicates: duplicates,
                             linkedOrders: linked, mergedApplePay: merged, usedAI: usedAI, warnings: result.warnings)
    }

    /// Which account a transaction belongs to. Credit-card exports carry the
    /// card number; chequing exports and bank statements don't.
    static func accountKey(for parsed: ParsedTransaction, kind: DocumentKind) -> String? {
        if let a = parsed.account, !a.isEmpty { return a }
        switch kind {
        case .cibcCSV, .cibcBankStatement: return "CIBC Chequing"
        case .cibcCreditCardStatement: return "CIBC Credit Card"
        case .genericCSV, .aiExtracted: return "Bank account"
        default: return nil
        }
    }

    /// One-time upgrade for data imported before accounts existed.
    static func backfillAccountsIfNeeded(context: ModelContext) {
        let flag = "accountsBackfilled-v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let all = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        for e in all where e.account == nil {
            switch e.source {
            case .cibcCSV, .cibcBankStatement: e.account = "CIBC Chequing"
            case .cibcCreditCardStatement: e.account = "CIBC Credit Card"
            case .genericCSV, .aiExtracted: e.account = "Bank account"
            default: break
            }
        }
        ensureAccounts(for: all, context: context)
        try? context.save()
        UserDefaults.standard.set(true, forKey: flag)
    }

    /// Creates Account records for new account keys, guessing credit vs debit.
    static func ensureAccounts(for entries: [LedgerEntry], context: ModelContext) {
        let known = Set(((try? context.fetch(FetchDescriptor<Account>())) ?? []).map(\.key))
        var created = Set<String>()
        for e in entries {
            guard let key = e.account, !known.contains(key), created.insert(key).inserted else { continue }
            let lower = key.lowercased()
            let kind: AccountKind
            if lower.contains("debit") || lower.contains("chequing") || lower.contains("checking") {
                kind = .debit
            } else if lower.contains("saving") {
                kind = .savings
            } else if e.source == .cibcCreditCardStatement || lower.contains("card ••") || lower.contains("visa")
                        || lower.contains("mastercard") || lower.contains("amex") || lower.contains("credit") {
                kind = .credit
            } else if e.source == .cibcBankStatement {
                kind = .debit
            } else {
                kind = .other
            }
            let name = key.hasPrefix("Card ••") ? "CIBC Credit Card \(key.dropFirst(5))" : key
            context.insert(Account(key: key, name: name, kind: kind))
        }
    }

    private func looksMultiLine(_ text: String) -> Bool {
        let amountLines = text.components(separatedBy: .newlines).filter {
            $0.range(of: AmountParsing.pattern, options: .regularExpression) != nil
        }
        return (amountLines.count >= 6 && DocumentRouter.looksLikeStatement(text)) || amountLines.count >= 15
    }

    /// Purchases logged live from Apple Pay reappear on the statement. Keep
    /// the statement version (exact final amount, incl. tips) and carry over
    /// anything the user set on the live entry.
    private func mergeApplePay(into added: [LedgerEntry], kind: DocumentKind, context: ModelContext) -> Int {
        guard [.cibcCSV, .genericCSV, .cibcCreditCardStatement, .cibcBankStatement, .aiExtracted].contains(kind) else { return 0 }
        let live = ((try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []).filter { $0.source == .applePay }
        guard !live.isEmpty else { return 0 }
        let statement = added.filter { !$0.isCredit }
        let matches = LiveMatcher.match(
            live: live.map { .init(id: $0.id, date: $0.date, amount: $0.amount, merchant: $0.rawDescription) },
            statement: statement.map { .init(id: $0.id, date: $0.date, amount: $0.amount, merchant: $0.rawDescription) })
        let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        let stmtByID = Dictionary(uniqueKeysWithValues: statement.map { ($0.id, $0) })
        for (liveID, stmtID) in matches {
            guard let l = liveByID[liveID], let s = stmtByID[stmtID] else { continue }
            if l.userSetCategory {
                s.category = l.category
                s.userSetCategory = true
            }
            if !l.notes.isEmpty { s.notes = l.notes }
            if s.items.isEmpty && !l.items.isEmpty { s.items = l.items }
            context.delete(l)
        }
        return matches.count
    }

    /// Attaches Amazon order items to the matching card charges.
    @discardableResult
    func linkAmazonOrders(context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<LedgerEntry>()) else { return 0 }
        let orders = all.filter { $0.source == .amazonOrderHistory && $0.linkedEntryID == nil }
        guard !orders.isEmpty else { return 0 }
        let alreadyLinked = Set(all.compactMap(\.linkedEntryID))
        let charges = all.filter {
            $0.merchant == "Amazon" && $0.source != .amazonOrderHistory && !$0.isCredit && !alreadyLinked.contains($0.id)
        }
        let matches = OrderMatcher.match(
            orders: orders.map { .init(id: $0.id, date: $0.date, amount: $0.amount) },
            charges: charges.map { .init(id: $0.id, date: $0.date, amount: $0.amount) })
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for (orderID, chargeID) in matches {
            guard let order = byID[orderID], let charge = byID[chargeID] else { continue }
            order.linkedEntryID = chargeID
            if charge.items.isEmpty { charge.items = order.items }
            if !charge.userSetCategory, order.category != .shopping { charge.category = order.category }
        }
        return matches.count
    }
}
