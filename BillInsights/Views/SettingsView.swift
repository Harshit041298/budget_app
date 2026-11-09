import SwiftUI
import SwiftData
import BillCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ImportedDocument.importedAt, order: .reverse) private var documents: [ImportedDocument]
    @Query private var entries: [LedgerEntry]
    @Query private var rules: [MerchantRule]
    @AppStorage("countAmazonOrders") private var countAmazon = false
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @State private var exportURL: URL?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("On-device intelligence") {
                    switch LocalLLM.status {
                    case .ready:
                        Label("Apple on-device LLM ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    case .unavailable(let why):
                        Label(why, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    LabeledContent("Text recognition", value: "Apple Vision (on-device)")
                    LabeledContent("Categoriser", value: "Rules + NL embeddings")
                    LabeledContent("Learned merchant rules", value: "\(rules.count)")
                }

                Section {
                    Toggle("Count Amazon orders as spending", isOn: $countAmazon)
                } footer: {
                    Text("Leave off if you also import the card you pay Amazon with. Otherwise each purchase would be counted twice. Orders are still matched to card charges to show what you bought.")
                }

                Section("Privacy") {
                    Toggle("Require Face ID", isOn: $lockEnabled)
                    Text("All data is stored only on this iPhone, in the app's sandbox. The app makes no network requests.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Imported documents (\(documents.count))") {
                    ForEach(documents) { doc in
                        NavigationLink {
                            DocumentDetailView(document: doc)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(doc.filename).lineLimit(1)
                                Text("\(doc.kind.displayName) · \(doc.entries.count) transactions · \(doc.importedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(documents[i]) }
                        try? context.save()
                    }
                }

                Section("Data") {
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share CSV export", systemImage: "square.and.arrow.up") }
                    } else {
                        Button("Export all transactions (CSV)") { exportURL = makeExport() }
                    }
                    Button("Delete all data", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all transactions, documents and learned rules?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    try? context.delete(model: LedgerEntry.self)
                    try? context.delete(model: ImportedDocument.self)
                    try? context.delete(model: MerchantRule.self)
                    try? context.save()
                }
            }
        }
    }

    private func makeExport() -> URL? {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "Date,Merchant,Category,Amount,Direction,Account,Source,Items,Original description\n"
        for e in entries.sorted(by: { $0.date < $1.date }) {
            csv += [DateParsing.isoDay.string(from: e.date), esc(e.merchant), e.category.displayName,
                    String(format: "%.2f", e.amount), e.isCredit ? "in" : "out", esc(e.account ?? ""),
                    e.source.displayName, esc(e.items.joined(separator: "; ")), esc(e.rawDescription)]
                .joined(separator: ",") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bill-insights-export.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

struct DocumentDetailView: View {
    let document: ImportedDocument

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: document.kind.displayName)
                LabeledContent("Imported", value: document.importedAt.formatted())
                LabeledContent("Transactions", value: "\(document.entries.count)")
                if !document.notes.isEmpty {
                    Text(document.notes).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Transactions") {
                ForEach(document.entries.sorted { $0.date < $1.date }) { e in
                    NavigationLink { EntryDetailView(entry: e) } label: { EntryRow(entry: e) }
                }
            }
            Section("Extracted text") {
                Text(document.extractedText.prefix(20_000))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(document.filename)
        .navigationBarTitleDisplayMode(.inline)
    }
}
