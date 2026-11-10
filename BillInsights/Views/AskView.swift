import SwiftUI
import SwiftData
import BillCore

struct AskView: View {
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @AppStorage("countAmazonOrders") private var countAmazon = false
    @Environment(\.modelContext) private var context
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var assistant: FinanceAssistant?
    @State private var assistantDataCount = -1

    private let suggestions = [
        "How much did I spend on food last month?",
        "What are my subscriptions costing me?",
        "What did I buy on Amazon recently?",
        "How can I save $1,500 a month?",
        "Where can I cut back?",
        "What was my biggest purchase this month?",
        "How much did I spend on my credit cards vs debit?"
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch LocalLLM.status {
                case .ready:
                    chat
                case .unavailable(let reason):
                    ContentUnavailableView {
                        Label("On-device AI unavailable", systemImage: "sparkles")
                    } description: {
                        Text(reason + "\n\nThe Insights tab still works without it.")
                    }
                }
            }
            .navigationTitle("Ask")
            .toolbar {
                if !messages.isEmpty {
                    Button("Clear") {
                        messages = []
                        assistant = nil
                    }
                }
            }
        }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ask anything about your spending. Answers are computed privately on this iPhone.")
                                    .foregroundStyle(.secondary)
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { send(s) }
                                        .buttonStyle(.bordered)
                                        .disabled(entries.isEmpty)
                                }
                            }
                            .padding(.top)
                        }
                        ForEach(messages) { m in
                            Bubble(message: m).id(m.id)
                        }
                        if thinking {
                            HStack { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }
                                .id("thinking")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            HStack {
                TextField("Ask about your money…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { send(input) }
                Button { send(input) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || thinking || entries.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        input = ""
        messages.append(ChatMessage(text: q, fromUser: true))
        if assistant == nil || assistantDataCount != entries.count {
            assistant = FinanceAssistant(facts: AppData.facts(context: context))
            assistantDataCount = entries.count
        }
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let answer = try await assistant!.ask(q)
                messages.append(ChatMessage(text: answer, fromUser: false))
            } catch {
                messages.append(ChatMessage(text: "Sorry, I couldn't answer that (\(error.localizedDescription)).", fromUser: false))
            }
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let fromUser: Bool
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.fromUser { Spacer(minLength: 40) }
            Text(LocalizedStringKey(message.text))
                .padding(12)
                .background(message.fromUser ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(message.fromUser ? Color.white : Color.primary)
                .textSelection(.enabled)
            if !message.fromUser { Spacer(minLength: 40) }
        }
    }
}
