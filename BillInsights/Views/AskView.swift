import SwiftUI
import SwiftData
import BillCore

struct AskView: View {
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Environment(\.modelContext) private var context
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var assistant: FinanceAssistant?
    @State private var assistantDataCount = -1
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "Where am I spending the most in shopping?",
        "How can I save $1,500 a month?",
        "How much did I spend on food last month?",
        "What are my subscriptions costing me?",
        "What did I buy on Amazon recently?",
        "Credit cards vs debit this month?",
        "What was my biggest purchase this month?"
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch LocalLLM.status {
                case .ready:
                    chat
                case .unavailable where CloudAI.isReady:
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat") {
                            messages = []
                            assistant?.reset()
                        }
                    }
                }
            }
        }
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty {
                        intro
                    }
                    ForEach(messages) { m in
                        Bubble(message: m).id(m.id)
                    }
                    if thinking {
                        TypingIndicator().id("typing")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: thinking) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: inputFocused) { _, focused in
                if focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ask about your money", systemImage: "sparkles").font(.title3.bold())
            Text("Numbers are calculated from your transactions on this iPhone; the on-device AI explains them. Nothing leaves your phone.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { s in
                Button { send(s) } label: {
                    HStack {
                        Text(s).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(entries.isEmpty)
            }
            if entries.isEmpty {
                Text("Import some transactions first.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your money…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(input) }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
            Button { send(input) } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking || entries.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
                let reply = await assistant!.ask(q)
                messages.append(ChatMessage(text: reply.text, fromUser: false, source: reply.source.label))
            }
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let fromUser: Bool
    var source: String? = nil
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.fromUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(message.text))
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(message.fromUser ? Color.white : Color.primary)
                .background(message.fromUser ? Color.accentColor : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                if let source = message.source {
                    Text(source).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 6)
                }
            }
            if !message.fromUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 8, height: 8)
                    .opacity(0.3 + 0.7 * abs(sin(phase + Double(i) * 0.6)))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi }
        }
    }
}
