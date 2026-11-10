import SwiftUI
import SwiftData
import BillCore

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @State private var search = ""
    @State private var category: SpendCategory?
    @State private var month: Date?
    @State private var showingAdd = false
    private let embedded: Bool

    init(initialCategory: SpendCategory? = nil, initialMonth: Date? = nil) {
        _category = State(initialValue: initialCategory)
        _month = State(initialValue: initialMonth)
        embedded = initialCategory != nil || initialMonth != nil
    }

    private var filtered: [LedgerEntry] {
        let q = search.lowercased()
        return entries.filter { e in
            (category == nil || e.category == category)
                && (month == nil || Calendar.current.isDate(e.date, equalTo: month!, toGranularity: .month))
                && (q.isEmpty || e.merchant.lowercased().contains(q) || e.rawDescription.lowercased().contains(q)
                    || e.itemsText.lowercased().contains(q))
        }
    }

    private var grouped: [(month: Date, entries: [LedgerEntry])] {
        Dictionary(grouping: filtered) { DateParsing.startOfMonth($0.date) }
            .map { ($0.key, $0.value) }
            .sorted { $0.month > $1.month }
    }

    var body: some View {
        if embedded {
            list
        } else {
            NavigationStack { list }
        }
    }

    private var list: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "tray",
                                       description: Text(entries.isEmpty ? "Import a statement to get started." : "Nothing matches your filters."))
            }
            ForEach(grouped, id: \.month) { group in
                Section {
                    ForEach(group.entries) { e in
                        NavigationLink { EntryDetailView(entry: e) } label: { EntryRow(entry: e) }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(group.entries[i]) }
                        try? context.save()
                    }
                } header: {
                    HStack {
                        Text(group.month.monthYear)
                        Spacer()
                        Text(money(group.entries.reduce(0) { $0 + $1.fact(countAmazonOrders: false).spend }))
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Merchant, product or description")
        .navigationTitle(category?.displayName ?? "Transactions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Category", selection: $category) {
                        Text("All categories").tag(SpendCategory?.none)
                        ForEach(SpendCategory.allCases) { c in
                            Label(c.displayName, systemImage: c.symbol).tag(SpendCategory?.some(c))
                        }
                    }
                    if month != nil {
                        Button("Show all months") { month = nil }
                    }
                } label: {
                    Image(systemName: category == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) { AddEntryView() }
    }
}

struct EntryRow: View {
    let entry: LedgerEntry

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: entry.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.merchant).lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.date.shortDay)
                    if !entry.items.isEmpty {
                        Text("· \(entry.items.first!)").lineLimit(1)
                    } else {
                        Text("· \(entry.category.displayName)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((entry.isCredit ? "+" : "") + money(entry.amount))
                    .foregroundStyle(entry.isCredit ? Color.green : Color.primary)
                    .bold()
                if entry.source == .amazonOrderHistory {
                    Text(entry.linkedEntryID == nil ? "order" : "matched").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct EntryDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var entry: LedgerEntry
    @State private var applyToAll = true

    var body: some View {
        Form {
            Section {
                TextField("Merchant", text: $entry.merchant)
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("Amount", value: $entry.amount, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Money in (refund / deposit)", isOn: $entry.isCredit)
                DatePicker("Date", selection: $entry.date, displayedComponents: .date)
            }

            Section {
                Picker("Category", selection: Binding(
                    get: { entry.category },
                    set: { setCategory($0) })) {
                    ForEach(SpendCategory.allCases) { c in
                        Label(c.displayName, systemImage: c.symbol).tag(c)
                    }
                }
                Toggle("Apply to all \(entry.merchant) transactions", isOn: $applyToAll)
                Toggle("Exclude from spending", isOn: $entry.excludedFromSpending)
            } footer: {
                Text("Your choice is remembered and used to train the on-device categoriser for future imports.")
            }

            if !entry.items.isEmpty {
                Section("Items") {
                    ForEach(entry.items, id: \.self) { Text($0).font(.subheadline) }
                }
            }

            Section("Notes") {
                TextField("Add a note", text: $entry.notes, axis: .vertical)
            }

            Section("Source") {
                LabeledContent("Original text", value: entry.rawDescription)
                LabeledContent("From", value: entry.source.displayName)
                if let account = entry.account { LabeledContent("Account", value: account) }
                if let doc = entry.document { LabeledContent("File", value: doc.filename) }
            }
        }
        .navigationTitle(entry.merchant)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
    }

    private func setCategory(_ c: SpendCategory) {
        CategoryLearning.assign(c, toMerchant: entry.merchant, context: context, applyToAll: applyToAll, entry: entry)
    }
}

struct AddEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var merchant = ""
    @State private var amount: Double?
    @State private var date = Date()
    @State private var category: SpendCategory = .other
    @State private var isCredit = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Merchant", text: $merchant)
                TextField("Amount", value: $amount, format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Category", selection: $category) {
                    ForEach(SpendCategory.allCases) { c in Text(c.displayName).tag(c) }
                }
                Toggle("Money in", isOn: $isCredit)
            }
            .navigationTitle("Add transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let parsed = ParsedTransaction(date: date, rawDescription: merchant,
                                                       amount: Decimal(amount ?? 0), isCredit: isCredit)
                        let e = LedgerEntry(parsed: parsed, merchant: merchant, category: category, source: .manual)
                        e.userSetCategory = true
                        context.insert(e)
                        try? context.save()
                        dismiss()
                    }
                    .disabled(merchant.isEmpty || (amount ?? 0) <= 0)
                }
            }
        }
    }
}
