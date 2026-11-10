import SwiftUI

/// Settings → Cloud AI: opt-in Claude for advice, API key in the Keychain.
struct CloudAISettingsView: View {
    @AppStorage(CloudAI.enabledKey) private var enabled = false
    @AppStorage(CloudAI.modelKey) private var modelRaw = CloudAI.Model.sonnet.rawValue
    @State private var keyInput = ""
    @State private var hasKey = CloudAI.hasKey
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("Use Claude for advice", isOn: $enabled)
            } footer: {
                Text("When on, open-ended questions (\"how can I save more?\", AI insights, savings tips) are answered by Claude. Number questions are still calculated on your iPhone and never sent.")
            }

            Section("Model") {
                Picker("Model", selection: $modelRaw) {
                    ForEach(CloudAI.Model.allCases) { m in
                        VStack(alignment: .leading) {
                            Text(m.displayName)
                            Text(m.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(m.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                if hasKey {
                    Label("API key saved in Keychain", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Button("Remove key", role: .destructive) {
                        Keychain.delete()
                        hasKey = false
                        testResult = nil
                    }
                } else {
                    SecureField("sk-ant-…", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        let k = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        hasKey = Keychain.save(k)
                        keyInput = ""
                        if hasKey && !enabled { enabled = true }
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if hasKey {
                    Button {
                        Task { await test() }
                    } label: {
                        if testing { HStack { ProgressView(); Text("Testing…") } } else { Text("Test connection") }
                    }
                    .disabled(testing)
                }
                if let testResult { Text(testResult).font(.caption) }
            } header: {
                Text("Anthropic API key")
            } footer: {
                Text("Create a key at console.anthropic.com → API Keys. It's stored only in this iPhone's Keychain (not synced, not in backups).")
            }

            Section("Usage this month (estimate)") {
                LabeledContent("Requests", value: "\(CloudAI.requestsThisMonth)")
                LabeledContent("Cost", value: String(format: "US$%.3f", CloudAI.costThisMonth))
            }

            Section("What is sent") {
                Text("Only a short summary the app computes for your question — e.g. totals per category, top merchants and amounts for the period you asked about. Never your statements, account or card numbers, or full transaction history. Under Anthropic's commercial API terms your data isn't used to train models by default.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cloud AI")
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let reply = try await CloudAI.complete(system: "Reply with exactly: Connected.", prompt: "Test", maxTokens: 200)
            testResult = "✅ \(CloudAI.model.displayName): \(reply)"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
