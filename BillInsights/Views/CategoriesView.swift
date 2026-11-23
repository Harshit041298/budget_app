import SwiftUI
import SwiftData
import BillCore

/// Manage custom categories.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomCategory.name) private var customs: [CustomCategory]
    @Query private var entries: [LedgerEntry]
    @State private var editing: CustomCategory?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                Button { creating = true } label: { Label("New category", systemImage: "plus.circle.fill") }
            } footer: {
                Text("Create your own categories, like Pets, Car, Kids or Side business. Each one behaves like its parent category in totals and budgets.")
            }
            if !customs.isEmpty {
                Section("Your categories") {
                    ForEach(customs) { c in
                        let info = CategoryCatalog(customs).info(key: c.key)
                        Button { editing = c } label: {
                            HStack {
                                CategoryIcon(info: info, size: 30)
                                VStack(alignment: .leading) {
                                    Text(c.name).foregroundStyle(.primary)
                                    Text("Under \(c.base.displayName) · \(entries.filter { $0.customCategoryKey == c.key }.count) transactions")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { CategoryLearning.delete(customs[i], context: context) }
                    }
                }
            }
            Section("Built-in") {
                ForEach(SpendCategory.allCases) { c in
                    HStack {
                        CategoryIcon(category: c, size: 30)
                        Text(c.displayName)
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .sheet(isPresented: $creating) { CategoryEditor(existing: nil) }
        .sheet(item: $editing) { c in CategoryEditor(existing: c) }
    }
}

/// Create or edit a custom category. `onCreate` receives the new category.
struct CategoryEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let existing: CustomCategory?
    var onCreate: ((CategoryInfo) -> Void)? = nil

    @State private var name = ""
    @State private var symbol = "tag.fill"
    @State private var colorIndex = 7
    @State private var base: SpendCategory = .other

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        CategoryIcon(info: CategoryInfo(key: "preview", name: name, symbol: symbol,
                                                        color: CategoryInfo.palette[colorIndex], base: base), size: 64)
                        Spacer()
                    }
                    TextField("Name (e.g. Pets)", text: $name)
                }
                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(CategoryInfo.palette.indices, id: \.self) { i in
                            Circle().fill(CategoryInfo.palette[i]).frame(width: 32, height: 32)
                                .overlay { if i == colorIndex { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                .onTapGesture { colorIndex = i }
                        }
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(CategoryInfo.symbols, id: \.self) { s in
                            Image(systemName: s)
                                .frame(width: 36, height: 36)
                                .background(s == symbol ? CategoryInfo.palette[colorIndex].opacity(0.3) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .onTapGesture { symbol = s }
                        }
                    }
                }
                Section {
                    Picker("Counts as", selection: $base) {
                        ForEach(SpendCategory.allCases) { c in Text(c.displayName).tag(c) }
                    }
                } footer: {
                    Text("The parent decides how it's treated: spending categories count toward your totals; Income and Transfers don't.")
                }
            }
            .navigationTitle(existing == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    symbol = existing.symbol
                    colorIndex = existing.colorIndex % CategoryInfo.palette.count
                    base = existing.base
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing {
            existing.name = trimmed
            existing.symbol = symbol
            existing.colorIndex = colorIndex
            existing.baseRaw = base.rawValue
            // Keep the parent of already-filed transactions in sync.
            let key: String? = existing.key
            let filed = (try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate<LedgerEntry> { $0.customCategoryKey == key }))) ?? []
            for e in filed { e.category = base }
        } else {
            let c = CustomCategory(name: trimmed, symbol: symbol, colorIndex: colorIndex, base: base)
            context.insert(c)
            onCreate?(CategoryInfo(key: c.key, name: trimmed, symbol: symbol, color: CategoryInfo.palette[colorIndex], base: base))
        }
        try? context.save()
        dismiss()
    }
}

/// A category picker listing custom + built-in categories, with "New category…".
struct CategoryPickerList: View {
    @Query(sort: \CustomCategory.name) private var customs: [CustomCategory]
    @Environment(\.dismiss) private var dismiss
    let selectedKey: String?
    let onPick: (CategoryInfo) -> Void
    @State private var creating = false

    var body: some View {
        let catalog = CategoryCatalog(customs)
        List {
            Section {
                Button { creating = true } label: { Label("New category…", systemImage: "plus.circle.fill") }
            }
            if !catalog.customs.isEmpty {
                Section("Your categories") { rows(catalog.customs) }
            }
            Section("Built-in") { rows(SpendCategory.allCases.map(CategoryInfo.builtin)) }
        }
        .navigationTitle("Category")
        .sheet(isPresented: $creating) {
            CategoryEditor(existing: nil) { info in
                onPick(info)
                dismiss()
            }
        }
    }

    private func rows(_ infos: [CategoryInfo]) -> some View {
        ForEach(infos) { info in
            Button {
                onPick(info)
                dismiss()
            } label: {
                HStack {
                    CategoryIcon(info: info, size: 28)
                    Text(info.name).foregroundStyle(.primary)
                    Spacer()
                    if info.key == selectedKey { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
        }
    }
}
