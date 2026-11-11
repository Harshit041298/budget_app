import Foundation
import SwiftData
import BillCore

/// Category changes Claude proposes. Nothing is applied until the user taps
/// Apply in the chat; every applied proposal can be undone.
struct ChangeProposal: Identifiable, Codable {
    var id = UUID()
    var summary: String
    var items: [Item]
    var warnings: [String]

    struct Item: Identifiable, Codable {
        var id = UUID()
        var title: String
        var detail: String
        var payload: Payload
    }

    enum Payload: Codable {
        /// Move transactions to a category (existing key, or a category created in this proposal by name).
        case recategorize(ids: [UUID], toKey: String?, toNewName: String?, rememberMerchants: [String])
        case rule(text: String, min: Double?, max: Double?, direction: String, toKey: String?, toNewName: String?)
        case newCategory(name: String, parent: SpendCategory)
    }

    static let maxChanges = 20
    static let maxTransactionsPerChange = 50
}

/// What's needed to undo an applied proposal.
struct UndoRecord: Codable {
    struct EntryState: Codable { var id: UUID; var categoryRaw: String; var customKey: String?; var userSet: Bool }
    struct MerchantRuleState: Codable { var key: String; var previousRaw: String? }
    var entries: [EntryState] = []
    var createdRuleIDs: [UUID] = []
    var createdCategoryKeys: [String] = []
    var merchantRules: [MerchantRuleState] = []
}

/// Validates Claude's raw proposal against the real data (on device).
struct ProposalBuilder {
    let facts: [TxnFact]
    let catalog: CategoryCatalog
    let shortIDs: [String: UUID]

    func build(_ input: [String: Any]) -> (ChangeProposal?, String) {
        let summary = (input["summary"] as? String) ?? "Suggested changes"
        let raw = (input["changes"] as? [[String: Any]]) ?? []
        guard !raw.isEmpty else { return (nil, "No changes were given.") }
        var items: [ChangeProposal.Item] = []
        var warnings: [String] = []
        var newNames: [String: SpendCategory] = [:]
        let money = SpendingAnalytics.money

        // New categories first, so later changes can refer to them by name.
        for c in raw where (c["kind"] as? String) == "new_category" {
            let name = str(c["name"])
            guard !name.isEmpty else { continue }
            if catalog.all.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                warnings.append("Category \"\(name)\" already exists — reused it.")
                continue
            }
            let parent = resolveBuiltin(str(c["parent"])) ?? .other
            newNames[name.lowercased()] = parent
            items.append(.init(title: "New category: \(name)", detail: "Counts as \(parent.displayName)",
                               payload: .newCategory(name: name, parent: parent)))
        }

        func target(_ s: String) -> (key: String?, newName: String?, label: String)? {
            if let info = resolve(s) { return (info.key, nil, info.name) }
            if newNames[s.lowercased()] != nil { return (nil, s, s) }
            return nil
        }

        for c in raw {
            guard items.count < ChangeProposal.maxChanges else {
                warnings.append("Only the first \(ChangeProposal.maxChanges) changes are shown.")
                break
            }
            switch str(c["kind"]) {
            case "recategorize":
                guard let t = target(str(c["to_category"])) else {
                    warnings.append("Skipped: unknown category \"\(str(c["to_category"]))\".")
                    continue
                }
                var matched: [TxnFact] = []
                let ids = (c["transaction_ids"] as? [String] ?? []).compactMap { shortIDs[$0.lowercased()] }
                let merchant = str(c["merchant"]).lowercased()
                if !ids.isEmpty {
                    let set = Set(ids)
                    matched = facts.filter { set.contains($0.id) }
                } else if !merchant.isEmpty {
                    let from = str(c["from_category"])
                    let start = DateParsing.parseFullDate(str(c["start_date"]))
                    let end = DateParsing.parseFullDate(str(c["end_date"])).map { $0.addingTimeInterval(86_400) }
                    matched = facts.filter { f in
                        f.merchant.lowercased() == merchant
                            && (from.isEmpty || f.categoryName.lowercased() == from.lowercased() || f.categoryKey == from)
                            && (start == nil || f.date >= start!) && (end == nil || f.date < end!)
                    }
                }
                matched = matched.filter { $0.categoryKey != t.key || t.key == nil }
                guard !matched.isEmpty else {
                    warnings.append("Skipped: no transactions matched for \(merchant.isEmpty ? "the given ids" : merchant).")
                    continue
                }
                if matched.count > ChangeProposal.maxTransactionsPerChange {
                    warnings.append("Limited to \(ChangeProposal.maxTransactionsPerChange) of \(matched.count) transactions.")
                    matched = Array(matched.sorted { $0.date > $1.date }.prefix(ChangeProposal.maxTransactionsPerChange))
                }
                let merchants = Set(matched.map(\.merchant))
                let remember = (c["remember_merchant"] as? Bool) ?? !merchant.isEmpty
                let from = Set(matched.map(\.categoryName)).sorted().joined(separator: "/")
                let label = merchants.count == 1 ? merchants.first! : "\(merchants.count) merchants"
                let total = matched.reduce(0) { $0 + $1.amount }
                var detail = "\(matched.count) transaction\(matched.count == 1 ? "" : "s"), \(money(total)) · \(from) → \(t.label)"
                if let reason = c["reason"] as? String, !reason.isEmpty { detail += "\n" + reason }
                if remember { detail += "\nFuture \(label) imports will use \(t.label)." }
                items.append(.init(title: "\(label) → \(t.label)", detail: detail,
                                   payload: .recategorize(ids: matched.map(\.id), toKey: t.key, toNewName: t.newName,
                                                          rememberMerchants: remember ? Array(merchants) : [])))

            case "rule":
                let text = str(c["match_text"])
                let minA = num(c["min_amount"]), maxA = num(c["max_amount"])
                guard !text.isEmpty || minA != nil || maxA != nil else { continue }
                guard let t = target(str(c["to_category"])) else {
                    warnings.append("Skipped rule: unknown category \"\(str(c["to_category"]))\".")
                    continue
                }
                let dir = ["in", "out"].contains(str(c["direction"])) ? str(c["direction"]) : "any"
                var parts: [String] = []
                if !text.isEmpty { parts.append("contains “\(text)”") }
                if let minA { parts.append("over \(money(minA))") }
                if let maxA { parts.append("under \(money(maxA))") }
                items.append(.init(title: "Rule: \(parts.joined(separator: ", ")) → \(t.label)",
                                   detail: "Applies to future imports and matching existing transactions.",
                                   payload: .rule(text: text, min: minA, max: maxA, direction: dir, toKey: t.key, toNewName: t.newName)))
            case "new_category":
                continue
            default:
                warnings.append("Skipped an unsupported change type.")
            }
        }
        guard !items.isEmpty else {
            return (nil, "Nothing could be proposed: " + warnings.joined(separator: " "))
        }
        let proposal = ChangeProposal(summary: summary, items: items, warnings: warnings)
        let result = "Shown to the user for confirmation: " + items.map(\.title).joined(separator: "; ")
            + (warnings.isEmpty ? "" : ". Notes: " + warnings.joined(separator: " "))
            + ". Nothing is applied until the user taps Apply. Briefly tell them to review the card."
        return (proposal, result)
    }

    private func str(_ v: Any?) -> String { ((v as? String) ?? "").trimmingCharacters(in: .whitespaces) }
    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private func resolveBuiltin(_ s: String) -> SpendCategory? {
        let l = s.lowercased()
        return SpendCategory.allCases.first { $0.rawValue.lowercased() == l || $0.displayName.lowercased() == l }
            ?? SpendCategory.allCases.first { $0.displayName.lowercased().contains(l) && !l.isEmpty }
    }

    private func resolve(_ s: String) -> CategoryInfo? {
        let l = s.lowercased()
        guard !l.isEmpty else { return nil }
        if let exact = catalog.all.first(where: { $0.key.lowercased() == l || $0.name.lowercased() == l }) { return exact }
        return resolveBuiltin(s).map(CategoryInfo.builtin)
    }
}

/// Applies / undoes an accepted proposal in the local database.
@MainActor
enum ChangeApplier {
    static func apply(_ p: ChangeProposal, selected: Set<UUID>, context: ModelContext) -> UndoRecord {
        var undo = UndoRecord()
        let chosen = p.items.filter { selected.contains($0.id) }
        var created: [String: CategoryInfo] = [:]

        for item in chosen {
            if case .newCategory(let name, let parent) = item.payload {
                let c = CustomCategory(name: name, symbol: "tag.fill", colorIndex: name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % CategoryInfo.palette.count, base: parent)
                context.insert(c)
                undo.createdCategoryKeys.append(c.key)
                created[name.lowercased()] = CategoryInfo(key: c.key, name: name, symbol: c.symbol,
                                                          color: CategoryInfo.palette[c.colorIndex], base: parent)
            }
        }
        let catalog = CategoryCatalog.load(context)
        func info(_ key: String?, _ newName: String?) -> CategoryInfo? {
            if let key { return catalog.info(key: key) }
            if let newName { return created[newName.lowercased()] ?? catalog.all.first { $0.name.lowercased() == newName.lowercased() } }
            return nil
        }
        let all = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        func change(_ e: LedgerEntry, to target: CategoryInfo) {
            if !undo.entries.contains(where: { $0.id == e.id }) {
                undo.entries.append(.init(id: e.id, categoryRaw: e.categoryRaw, customKey: e.customCategoryKey, userSet: e.userSetCategory))
            }
            e.setCategory(target)
            e.userSetCategory = true
        }

        for item in chosen {
            switch item.payload {
            case .recategorize(let ids, let key, let newName, let merchants):
                guard let target = info(key, newName) else { continue }
                for id in ids { if let e = byID[id] { change(e, to: target) } }
                for m in merchants {
                    let mk = MerchantNormalizer.key(for: m)
                    let existing = try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate<MerchantRule> { $0.merchantKey == mk }))
                    if let rule = existing?.first {
                        undo.merchantRules.append(.init(key: mk, previousRaw: rule.categoryRaw))
                        rule.categoryRaw = target.key
                        rule.updatedAt = Date()
                    } else {
                        let rule = MerchantRule(merchant: m, category: target.base)
                        rule.categoryRaw = target.key
                        context.insert(rule)
                        undo.merchantRules.append(.init(key: mk, previousRaw: nil))
                    }
                }
            case .rule(let text, let minA, let maxA, let dir, let key, let newName):
                guard let target = info(key, newName) else { continue }
                let rule = TransactionRule(matchText: text, minAmount: minA, maxAmount: maxA, direction: dir, categoryKey: target.key)
                context.insert(rule)
                undo.createdRuleIDs.append(rule.id)
                for e in all where rule.matches(e) && e.categoryKey != target.key { change(e, to: target) }
            case .newCategory:
                continue
            }
        }
        try? context.save()
        return undo
    }

    static func undo(_ r: UndoRecord, context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<LedgerEntry>())) ?? []
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for old in r.entries {
            guard let e = byID[old.id] else { continue }
            e.categoryRaw = old.categoryRaw
            e.customCategoryKey = old.customKey
            e.userSetCategory = old.userSet
        }
        let rules = (try? context.fetch(FetchDescriptor<TransactionRule>())) ?? []
        for rule in rules where r.createdRuleIDs.contains(rule.id) { context.delete(rule) }
        for saved in r.merchantRules.reversed() {
            let mk = saved.key
            let previous = saved.previousRaw
            let existing = try? context.fetch(FetchDescriptor<MerchantRule>(predicate: #Predicate<MerchantRule> { $0.merchantKey == mk }))
            guard let rule = existing?.first else { continue }
            if let previous { rule.categoryRaw = previous } else { context.delete(rule) }
        }
        for c in (try? context.fetch(FetchDescriptor<CustomCategory>())) ?? [] where r.createdCategoryKeys.contains(c.key) {
            context.delete(c)
        }
        try? context.save()
    }
}
