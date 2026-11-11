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
                    ForEach($messages) { $m in
                        VStack(alignment: .leading, spacing: 8) {
                            Bubble(message: m)
                            if m.proposal != nil {
                                ProposalCard(message: $m,
                                             onApply: { apply(messageID: m.id) },
                                             onUndo: { undo(messageID: m.id) })
                            }
                        }
                        .id(m.id)
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
            Text(CloudAI.isReady
                 ? "Claude looks up your transactions on this iPhone (read-only) and answers. It may ask a quick question if something's unclear."
                 : "Numbers are calculated from your transactions on this iPhone; the on-device AI explains them. Nothing leaves your phone.")
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

    private func refreshAssistant(note: String) {
        let catalog = CategoryCatalog.load(context)
        let budgets = ((try? context.fetch(FetchDescriptor<CategoryBudget>())) ?? []).map {
            (name: catalog.info(key: $0.categoryRaw).name, key: $0.categoryRaw, limit: $0.monthlyLimit)
        }
        assistant?.dataChanged(facts: AppData.facts(context: context), budgets: budgets, catalog: catalog, note: note)
        assistantDataCount = entries.count
    }

    private func apply(messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }), let p = messages[i].proposal else { return }
        let selected = messages[i].selected
        let record = ChangeApplier.apply(p, selected: selected, context: context)
        messages[i].proposalState = .applied(record)
        let applied = p.items.filter { selected.contains($0.id) }.map(\.title)
        refreshAssistant(note: "I applied these changes: " + applied.joined(separator: "; "))
    }

    private func undo(messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              case .applied(let record) = messages[i].proposalState else { return }
        ChangeApplier.undo(record, context: context)
        messages[i].proposalState = .undone
        refreshAssistant(note: "I undid the changes you proposed earlier.")
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        input = ""
        messages.append(ChatMessage(text: q, fromUser: true))
        if assistant == nil || assistantDataCount != entries.count {
            let catalog = CategoryCatalog.load(context)
            let budgets = ((try? context.fetch(FetchDescriptor<CategoryBudget>())) ?? []).map {
                (name: catalog.info(key: $0.categoryRaw).name, key: $0.categoryRaw, limit: $0.monthlyLimit)
            }
            assistant = FinanceAssistant(facts: AppData.facts(context: context), budgets: budgets, catalog: catalog)
            assistantDataCount = entries.count
        }
        thinking = true
        Task {
            defer { thinking = false }
            do {
                let reply = await assistant!.ask(q)
                var message = ChatMessage(text: reply.text, fromUser: false, source: reply.source.label)
                message.proposal = reply.proposal
                if let p = reply.proposal { message.selected = Set(p.items.map(\.id)) }
                messages.append(message)
            }
        }
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let fromUser: Bool
    var source: String? = nil
    var proposal: ChangeProposal? = nil
    var selected: Set<UUID> = []
    var proposalState: ProposalState = .pending

    enum ProposalState {
        case pending, dismissed, undone
        case applied(UndoRecord)
    }
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

/// Claude's proposed changes, shown for confirmation. Nothing changes until Apply.
private struct ProposalCard: View {
    @Binding var message: ChatMessage
    let onApply: () -> Void
    let onUndo: () -> Void

    var body: some View {
        if let p = message.proposal {
            VStack(alignment: .leading, spacing: 10) {
                Label("Proposed changes", systemImage: "wand.and.stars").font(.subheadline.bold())
                Text(p.summary).font(.caption).foregroundStyle(.secondary)
                ForEach(p.items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        if case .pending = message.proposalState {
                            Button {
                                if message.selected.contains(item.id) { message.selected.remove(item.id) }
                                else { message.selected.insert(item.id) }
                            } label: {
                                Image(systemName: message.selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(p.warnings, id: \.self) { w in
                    Label(w, systemImage: "info.circle").font(.caption2).foregroundStyle(.orange)
                }
                switch message.proposalState {
                case .pending:
                    HStack {
                        Button {
                            onApply()
                        } label: {
                            Text(message.selected.count == p.items.count ? "Apply all" : "Apply \(message.selected.count)")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(message.selected.isEmpty)
                        Button("Dismiss") { message.proposalState = .dismissed }
                            .buttonStyle(.bordered)
                    }
                case .applied:
                    HStack {
                        Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Undo", action: onUndo).buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                case .dismissed:
                    Text("Dismissed — nothing was changed.").font(.caption).foregroundStyle(.secondary)
                case .undone:
                    Text("Undone — everything is back as it was.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.4)))
        }
    }
}
