import SwiftUI

/// Settings → Cloud AI: opt-in Claude for advice, API key in the Keychain.
struct CloudAISettingsView: View {
    @AppStorage(CloudAI.enabledKey) private var enabled = false
    @AppStorage(CloudAI.modelKey) private var modelRaw = CloudAI.Model.sonnet.rawValue
    @AppStorage(CloudAI.capKey) private var cap: Double = 5
    @State private var keyInput = ""
    @State private var hasKey = CloudAI.hasKey
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("Use Claude for Ask, insights and tips", isOn: $enabled)
            } footer: {
                Text("When on, Claude answers every Ask question. It looks things up with read-only tools that run on this iPhone, and can ask you to clarify. When off, offline, or over your monthly limit, the on-device answers are used.")
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

            Section {
                LabeledContent("Requests", value: "\(CloudAI.requestsThisMonth)")
                LabeledContent("Cost", value: String(format: "US$%.3f", CloudAI.costThisMonth))
                Stepper(value: $cap, in: 1...100, step: 1) {
                    LabeledContent("Monthly limit", value: String(format: "US$%.0f", cap))
                }
            } header: {
                Text("Usage this month (estimate)")
            } footer: {
                Text("When the estimate reaches your limit, the app stops calling Claude until next month. Also set a spend limit in the Claude Console for a hard cap.")
            }

            Section("What is sent") {
                Text("Only what Claude looks up for your question: totals, and up to 30 matching transactions at a time (date, merchant, amount, category, account name, purchased items). Never your statement files, full card or account numbers, or your whole history at once. Under Anthropic's commercial API terms your data isn't used to train models by default.")
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
