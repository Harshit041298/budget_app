import Foundation
import NaturalLanguage
import SwiftData
import BillCore

/// Multi-stage, fully on-device categoriser:
/// 1. Your own corrections (exact merchant)            — always wins
/// 2. Source hints (e.g. CIBC's own spend category)
/// 3. Known-merchant + keyword rules (BillCore)
/// 4. Nearest neighbour over merchants you've labelled, using Apple's
///    NaturalLanguage sentence embeddings (learns from your edits)
/// 5. Semantic similarity to category descriptions (low confidence → the
///    on-device LLM gets a chance to improve it during import)
final class Categorizer {
    enum Source: String { case user, hint, rule, learned, semantic, fallback, ai }

    struct Result {
        var category: SpendCategory
        var source: Source
        var customKey: String? = nil
        var isConfident: Bool { source != .semantic && source != .fallback }
    }

    private let userRules: [String: (base: SpendCategory, custom: String?)]
    private var examples: [(vector: [Double], category: SpendCategory, custom: String?)] = []
    private static let embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    private static let prototypes: [(vector: [Double], category: SpendCategory)] = {
        guard let e = embedding else { return [] }
        return SpendCategory.allCases.filter { $0 != .other }.compactMap { cat in
            e.vector(for: cat.prototype).map { (vector: $0, category: cat) }
        }
    }()

    /// - Parameters:
    ///   - rules: merchant rules the user created by editing categories.
    ///   - labeled: (merchant, category) examples from user-categorised entries.
    /// - Parameters:
    ///   - catalog: resolves custom category keys used in rules / examples.
    init(rules: [MerchantRule], labeled: [(String, String)], catalog: CategoryCatalog) {
        func resolve(_ key: String) -> (base: SpendCategory, custom: String?)? {
            if let c = catalog.custom(key: key) { return (c.base, c.key) }
            if let b = SpendCategory(rawValue: key) { return (b, nil) }
            return nil   // a deleted custom category
        }
        var map: [String: (base: SpendCategory, custom: String?)] = [:]
        for r in rules { if let v = resolve(r.categoryRaw) { map[r.merchantKey] = v } }
        userRules = map
        if let e = Self.embedding {
            var seen = Set<String>()
            for (merchant, key) in labeled where seen.insert(merchant).inserted {
                if let v = e.vector(for: merchant), let cat = resolve(key) {
                    examples.append((vector: v, category: cat.base, custom: cat.custom))
                }
                if examples.count > 400 { break }
            }
        }
    }

    @MainActor
    static func load(_ context: ModelContext) -> Categorizer {
        let rules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []
        let labeled = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.userSetCategory == true }))) ?? []
        return Categorizer(rules: rules, labeled: labeled.map { ($0.merchant, $0.categoryKey) },
                           catalog: CategoryCatalog.load(context))
    }

    func categorize(merchant: String, rawDescription: String, hint: SpendCategory?) -> Result {
        if let c = userRules[MerchantNormalizer.key(for: merchant)] {
            return Result(category: c.base, source: .user, customKey: c.custom)
        }
        if let c = RuleCategorizer.categorize(rawDescription: rawDescription), c == .transfer || c == .income || c == .fees {
            return Result(category: c, source: .rule)
        }
        if let hint { return Result(category: hint, source: .hint) }
        if let c = RuleCategorizer.categorize(rawDescription: rawDescription) { return Result(category: c, source: .rule) }

        guard let e = Self.embedding, let v = e.vector(for: merchant + " " + rawDescription.lowercased()) else {
            return Result(category: .other, source: .fallback)
        }
        if let best = examples.map({ ($0, cosine(v, $0.vector)) }).max(by: { $0.1 < $1.1 }), best.1 > 0.9 {
            return Result(category: best.0.category, source: .learned, customKey: best.0.custom)
        }
        if let best = Self.prototypes.map({ ($0.category, cosine(v, $0.vector)) }).max(by: { $0.1 < $1.1 }), best.1 > 0.3 {
            return Result(category: best.0, source: .semantic)
        }
        return Result(category: .other, source: .fallback)
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
