import SwiftUI
import SwiftData
import BillCore

/// Clears out the "Other" bucket: one row per merchant, one tap to file it.
/// Every choice becomes a learned rule for future imports.
struct CategoryReviewView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Query private var customs: [CustomCategory]
    @State private var creatingFor: String?
    @State private var suggestions: [String: SpendCategory] = [:]
    @State private var suggesting = false

    struct MerchantGroup: Identifiable {
        var merchant: String
        var total: Double
        var count: Int
        var sample: String
        var id: String { merchant }
    }

    private var groups: [MerchantGroup] {
        let other = entries.filter { $0.categoryKey == SpendCategory.other.rawValue && !$0.isCredit }
        return Dictionary(grouping: other, by: \.merchant).map { merchant, list in
            MerchantGroup(merchant: merchant, total: list.reduce(0) { $0 + $1.amount }, count: list.count,
                  sample: list.first?.rawDescription ?? "")
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        let groups = groups
        List {
            if groups.isEmpty {
                ContentUnavailableView("Everything is categorised", systemImage: "checkmark.seal.fill",
                                       description: Text("New merchants you haven't seen before will show up here."))
            } else {
                Section {
                    if LocalLLM.isAvailable {
                        Button {
                            Task { await suggest(groups) }
                        } label: {
                            if suggesting {
                                HStack { ProgressView(); Text("Thinking on-device…") }
                            } else {
                                Label("Suggest categories with on-device AI", systemImage: "sparkles")
                            }
                        }
                        .disabled(suggesting)
                    }
                    if !suggestions.isEmpty {
                        Button {
                            for g in groups { if let c = suggestions[g.merchant] { assign(c, g.merchant) } }
                        } label: {
                            Label("Accept all \(suggestions.count) suggestions", systemImage: "checkmark.circle.fill")
                        }
                    }
                } footer: {
                    Text("\(groups.count) merchants · \(money(groups.reduce(0) { $0 + $1.total })) uncategorised. Your choices are remembered for future imports.")
                }

                Section {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.merchant).bold()
                                    Text("\(g.count)× · \(g.sample)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(money(g.total)).bold()
                            }
                            HStack {
                                if let s = suggestions[g.merchant] {
                                    Button {
                                        assign(s, g.merchant)
                                    } label: {
                                        Label(s.displayName, systemImage: s.symbol)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(s.color)
                                }
                                Menu {
                                    Button { creatingFor = g.merchant } label: { Label("New category…", systemImage: "plus") }
                                    ForEach(CategoryCatalog(customs).all.filter { $0.key != SpendCategory.other.rawValue }) { c in
                                        Button { assign(c, g.merchant) } label: { Label(c.name, systemImage: c.symbol) }
                                    }
                                } label: {
                                    Label(suggestions[g.merchant] == nil ? "Choose category" : "Other…", systemImage: "tag")
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Review categories")
        .sheet(item: Binding(get: { creatingFor.map { MerchantRef(name: $0) } },
                             set: { creatingFor = $0?.name })) { ref in
            CategoryEditor(existing: nil) { info in assign(info, ref.name) }
        }
    }

    struct MerchantRef: Identifiable { let name: String; var id: String { name } }

    private func assign(_ category: SpendCategory, _ merchant: String) {
        assign(.builtin(category), merchant)
    }

    private func assign(_ info: CategoryInfo, _ merchant: String) {
        withAnimation {
            CategoryLearning.assign(info, toMerchant: merchant, context: context)
            suggestions[merchant] = nil
        }
    }

    private func suggest(_ groups: [MerchantGroup]) async {
        suggesting = true
        defer { suggesting = false }
        let answers = await LocalLLM.categorize(groups.prefix(48).map { (merchant: $0.merchant, description: $0.sample) })
        var mapped: [String: SpendCategory] = [:]
        for g in groups {
            if let c = answers[g.merchant] ?? answers.first(where: { $0.key.lowercased() == g.merchant.lowercased() })?.value,
               c != .other {
                mapped[g.merchant] = c
            }
        }
        suggestions = mapped
    }
}
