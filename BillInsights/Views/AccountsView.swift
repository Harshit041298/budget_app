import SwiftUI
import SwiftData
import BillCore

/// Rename accounts and mark them as credit card / debit etc.
struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var entries: [LedgerEntry]
    @State private var adding = false
    @State private var newName = ""
    @State private var newKind: AccountKind = .credit

    var body: some View {
        List {
            Section {
                ForEach(accounts) { a in
                    AccountRow(account: a, count: entries.filter { $0.account == a.key }.count)
                }
                .onDelete { offsets in
                    for i in offsets {
                        let key = accounts[i].key
                        for e in entries where e.account == key { e.account = nil }
                        context.delete(accounts[i])
                    }
                    try? context.save()
                }
                Button { adding = true } label: { Label("Add account", systemImage: "plus.circle.fill") }
            } footer: {
                Text("Accounts are detected when you import (credit card exports include the card number). Rename them and set the type so Insights can split credit card vs debit spending. Move a transaction to another account from its detail screen.")
            }
        }
        .navigationTitle("Accounts")
        .alert("Add account", isPresented: $adding) {
            TextField("Name (e.g. CIBC Aventura Visa)", text: $newName)
            Button("Add credit card") { add(.credit) }
            Button("Add debit / chequing") { add(.debit) }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    private func add(_ kind: AccountKind) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !accounts.contains(where: { $0.key == name }) else { return }
        context.insert(Account(key: name, name: name, kind: kind))
        try? context.save()
        newName = ""
    }
}

private struct AccountRow: View {
    @Bindable var account: Account
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: account.kind.symbol).foregroundStyle(.tint).frame(width: 28)
                TextField("Name", text: $account.name).font(.headline)
            }
            Picker("Type", selection: Binding(get: { account.kind }, set: { account.kind = $0 })) {
                ForEach(AccountKind.allCases) { k in Text(k.displayName).tag(k) }
            }
            .font(.subheadline)
            Text("\(count) transactions\(account.key != account.name ? " · imported as \(account.key)" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
