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
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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
        let rules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []
        let labeledEntries = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.userSetCategory == true }))) ?? []
        let categorizer = Categorizer(rules: rules, labeled: labeledEntries.map { ($0.merchant, $0.category) })

        let existing = Set(((try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []).map(\.fingerprint))
        let doc = ImportedDocument(filename: filename, kind: result.kind, extractedText: String(text.prefix(200_000)),
                                   notes: result.warnings.joined(separator: "\n"))
        context.insert(doc)

        var added: [LedgerEntry] = []
        var unsure: [String: [LedgerEntry]] = [:]
        var duplicates = 0
        var seenThisFile = Set<String>()
        for parsed in result.transactions {
            let fp = parsed.fingerprint
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

        let linked = linkAmazonOrders(context: context)
        try context.save()

        return ImportSummary(filename: filename, kind: result.kind, added: added.count, duplicates: duplicates,
                             linkedOrders: linked, usedAI: usedAI, warnings: result.warnings)
    }

    private func looksMultiLine(_ text: String) -> Bool {
        let amountLines = text.components(separatedBy: .newlines).filter {
            $0.range(of: AmountParsing.pattern, options: .regularExpression) != nil
        }
        return (amountLines.count >= 6 && DocumentRouter.looksLikeStatement(text)) || amountLines.count >= 15
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
