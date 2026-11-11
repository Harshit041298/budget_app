import SwiftUI
import SwiftData
import BillCore

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Query private var customs: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var search = ""
    @State private var categoryKey: String?
    @State private var accountKey: String?
    @State private var month: Date?
    @State private var showingAdd = false
    private let embedded: Bool

    init(initialCategoryKey: String? = nil, initialMonth: Date? = nil) {
        _categoryKey = State(initialValue: initialCategoryKey)
        _month = State(initialValue: initialMonth)
        embedded = initialCategoryKey != nil || initialMonth != nil
    }

    private func filtered(_ catalog: CategoryCatalog) -> [LedgerEntry] {
        let q = search.lowercased()
        return entries.filter { e in
            (categoryKey == nil || e.categoryKey == categoryKey)
                && (accountKey == nil || e.account == accountKey)
                && (month == nil || Calendar.current.isDate(e.date, equalTo: month!, toGranularity: .month))
                && (q.isEmpty || e.merchant.lowercased().contains(q) || e.rawDescription.lowercased().contains(q)
                    || e.itemsText.lowercased().contains(q) || catalog.info(for: e).name.lowercased().contains(q))
        }
    }

    var body: some View {
        if embedded {
            list
        } else {
            NavigationStack { list }
        }
    }

    private var list: some View {
        let catalog = CategoryCatalog(customs)
        let rows = filtered(catalog)
        let grouped = Dictionary(grouping: rows) { DateParsing.startOfMonth($0.date) }
            .map { (month: $0.key, entries: $0.value) }
            .sorted { $0.month > $1.month }
        return List {
            if rows.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "tray",
                                       description: Text(entries.isEmpty ? "Import a statement to get started." : "Nothing matches your filters."))
            }
            ForEach(grouped, id: \.month) { group in
                Section {
                    ForEach(group.entries) { e in
                        NavigationLink { EntryDetailView(entry: e) } label: {
                            EntryRow(entry: e, info: catalog.info(for: e),
                                     accountName: e.account.flatMap { k in accounts.first { $0.key == k }?.name })
                        }
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
        .searchable(text: $search, prompt: "Merchant, product, category")
        .navigationTitle(categoryKey.map { catalog.info(key: $0).name } ?? "Transactions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Category", selection: $categoryKey) {
                        Text("All categories").tag(String?.none)
                        ForEach(catalog.all) { c in
                            Label(c.name, systemImage: c.symbol).tag(String?.some(c.key))
                        }
                    }
                    if !accounts.isEmpty {
                        Picker("Account", selection: $accountKey) {
                            Text("All accounts").tag(String?.none)
                            ForEach(accounts) { a in
                                Label(a.name, systemImage: a.kind.symbol).tag(String?.some(a.key))
                            }
                        }
                    }
                    if month != nil {
                        Button("Show all months") { month = nil }
                    }
                } label: {
                    Image(systemName: categoryKey == nil && accountKey == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
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
    let info: CategoryInfo
    var accountName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(info: info)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.merchant).lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.date.shortDay)
                    if !entry.items.isEmpty {
                        Text("· \(entry.items.first!)").lineLimit(1)
                    } else {
                        Text("· \(info.name)").lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let accountName {
                    Text(accountName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text((entry.isCredit ? "+" : "") + money(entry.amount))
                    .foregroundStyle(entry.isCredit ? Color.green : Color.primary)
                    .bold()
                if entry.source == .amazonOrderHistory {
                    Text(entry.linkedEntryID == nil ? "order" : "matched").font(.caption2).foregroundStyle(.secondary)
                } else if entry.source == .applePay {
                    Image(systemName: "wave.3.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct EntryDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var entry: LedgerEntry
    @Query private var customs: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var applyToAll = true

    var body: some View {
        let catalog = CategoryCatalog(customs)
        let info = catalog.info(for: entry)
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
                Picker("Account", selection: Binding(get: { entry.account ?? "" },
                                                     set: { entry.account = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(accounts) { a in Text(a.name).tag(a.key) }
                    if let key = entry.account, !accounts.contains(where: { $0.key == key }) {
                        Text(key).tag(key)
                    }
                }
            }

            Section {
                NavigationLink {
                    CategoryPickerList(selectedKey: info.key) { picked in
                        CategoryLearning.assign(picked, toMerchant: entry.merchant, context: context,
                                                applyToAll: applyToAll, entry: entry)
                    }
                } label: {
                    HStack {
                        Text("Category")
                        Spacer()
                        CategoryIcon(info: info, size: 24)
                        Text(info.name).foregroundStyle(.secondary)
                    }
                }
                Toggle("Apply to all \(entry.merchant) transactions", isOn: $applyToAll)
                Toggle("Exclude from spending", isOn: $entry.excludedFromSpending)
            } footer: {
                Text("Your choice is remembered and used to train the on-device categoriser for future imports. For finer control (e.g. by amount), use Settings → Rules.")
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
                if let doc = entry.document { LabeledContent("File", value: doc.filename) }
            }
        }
        .navigationTitle(entry.merchant)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
    }
}

struct AddEntryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var customs: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var merchant = ""
    @State private var amount: Double?
    @State private var date = Date()
    @State private var categoryKey = SpendCategory.other.rawValue
    @State private var accountKey = ""
    @State private var isCredit = false

    var body: some View {
        let catalog = CategoryCatalog(customs)
        NavigationStack {
            Form {
                TextField("Merchant", text: $merchant)
                TextField("Amount", value: $amount, format: .number.precision(.fractionLength(2)))
                    .keyboardType(.decimalPad)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Category", selection: $categoryKey) {
                    ForEach(catalog.all) { c in Text(c.name).tag(c.key) }
                }
                Picker("Account", selection: $accountKey) {
                    Text("None").tag("")
                    ForEach(accounts) { a in Text(a.name).tag(a.key) }
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
                        let info = catalog.info(key: categoryKey)
                        let e = LedgerEntry(parsed: parsed, merchant: merchant, category: info.base, source: .manual)
                        e.setCategory(info)
                        e.account = accountKey.isEmpty ? nil : accountKey
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
