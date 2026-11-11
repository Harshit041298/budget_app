import SwiftUI
import SwiftData
import BillCore

/// "Description contains … (and amount between …) → category" rules.
struct RulesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TransactionRule.createdAt, order: .reverse) private var rules: [TransactionRule]
    @Query private var customs: [CustomCategory]
    @Query private var entries: [LedgerEntry]
    @State private var editing: TransactionRule?
    @State private var creating = false
    @State private var lastApplied: Int?

    var body: some View {
        let catalog = CategoryCatalog(customs)
        List {
            Section {
                Button { creating = true } label: { Label("New rule", systemImage: "plus.circle.fill") }
                if !rules.isEmpty {
                    Button {
                        lastApplied = CategoryLearning.applyRules(to: entries, context: context)
                        try? context.save()
                    } label: { Label("Apply rules to all existing transactions", systemImage: "arrow.triangle.2.circlepath") }
                }
                if let lastApplied {
                    Text("\(lastApplied) transactions updated").font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Examples: “UBER” over $40 → Travel; “E-TRANSFER JOHN” → Rent & Housing. Rules run on every import and override automatic categories. Newest rule wins if several match.")
            }
            if !rules.isEmpty {
                Section("Rules") {
                    ForEach(rules) { r in
                        let info = catalog.info(key: r.categoryKey)
                        Button { editing = r } label: {
                            HStack {
                                CategoryIcon(info: info, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(describe(r)).foregroundStyle(.primary)
                                    Text("→ \(info.name) · matches \(entries.filter { r.matches($0) }.count)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(rules[i]) }
                        try? context.save()
                    }
                }
            }
        }
        .navigationTitle("Rules")
        .sheet(isPresented: $creating) { RuleEditor(existing: nil) }
        .sheet(item: $editing) { r in RuleEditor(existing: r) }
    }

    private func describe(_ r: TransactionRule) -> String {
        var parts: [String] = []
        if !r.matchText.isEmpty { parts.append("“\(r.matchText)”") }
        if let min = r.minAmount { parts.append("over \(money(min))") }
        if let max = r.maxAmount { parts.append("under \(money(max))") }
        if r.direction == "in" { parts.append("money in") }
        if r.direction == "out" { parts.append("purchases") }
        if let a = r.accountKey, !a.isEmpty { parts.append("on \(a)") }
        return parts.isEmpty ? "Any transaction" : parts.joined(separator: " · ")
    }
}

struct RuleEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CustomCategory.name) private var customs: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var entries: [LedgerEntry]
    let existing: TransactionRule?

    @State private var matchText = ""
    @State private var minAmount: Double?
    @State private var maxAmount: Double?
    @State private var direction = "out"
    @State private var categoryKey = SpendCategory.other.rawValue
    @State private var accountKey = ""

    var body: some View {
        let catalog = CategoryCatalog(customs)
        let matching = entries.filter {
            TransactionRule.matches($0, text: matchText, minAmount: minAmount, maxAmount: maxAmount,
                                    direction: direction, accountKey: accountKey.isEmpty ? nil : accountKey)
        }
        NavigationStack {
            Form {
                Section("When") {
                    TextField("Description contains (e.g. UBER)", text: $matchText)
                        .textInputAutocapitalization(.characters)
                    TextField("Amount at least (optional)", value: $minAmount, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Amount at most (optional)", value: $maxAmount, format: .number)
                        .keyboardType(.decimalPad)
                    Picker("Direction", selection: $direction) {
                        Text("Purchases").tag("out")
                        Text("Money in").tag("in")
                        Text("Either").tag("any")
                    }
                    Picker("Account", selection: $accountKey) {
                        Text("Any account").tag("")
                        ForEach(accounts) { a in Text(a.name).tag(a.key) }
                    }
                }
                Section("Then file under") {
                    NavigationLink {
                        CategoryPickerList(selectedKey: categoryKey) { categoryKey = $0.key }
                    } label: {
                        let info = catalog.info(key: categoryKey)
                        HStack { CategoryIcon(info: info, size: 28); Text(info.name) }
                    }
                }
                Section("Matches \(matching.count) existing transactions") {
                    ForEach(matching.prefix(5)) { e in
                        HStack {
                            Text(e.merchant).lineLimit(1)
                            Spacer()
                            Text(money(e.amount)).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New rule" : "Edit rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(applyTo: matching) }
                        .disabled(matchText.trimmingCharacters(in: .whitespaces).isEmpty && minAmount == nil
                                  && maxAmount == nil && accountKey.isEmpty)
                }
            }
            .onAppear {
                if let r = existing {
                    matchText = r.matchText
                    minAmount = r.minAmount
                    maxAmount = r.maxAmount
                    direction = r.direction
                    categoryKey = r.categoryKey
                    accountKey = r.accountKey ?? ""
                }
            }
        }
    }

    private func save(applyTo matching: [LedgerEntry]) {
        let rule = existing ?? TransactionRule(matchText: "", categoryKey: categoryKey)
        rule.matchText = matchText.trimmingCharacters(in: .whitespaces)
        rule.minAmount = minAmount
        rule.maxAmount = maxAmount
        rule.direction = direction
        rule.categoryKey = categoryKey
        rule.accountKey = accountKey.isEmpty ? nil : accountKey
        if existing == nil { context.insert(rule) }
        let info = CategoryCatalog(customs).info(key: categoryKey)
        for e in matching { e.setCategory(info) }
        try? context.save()
        dismiss()
    }
}
