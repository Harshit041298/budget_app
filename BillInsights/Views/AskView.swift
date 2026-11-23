import SwiftUI
import SwiftData
import BillCore

struct AskView: View {
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Environment(\.modelContext) private var context
    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var liveSteps: [String] = []
    @State private var assistant: FinanceAssistant?
    @State private var assistantDataCount = -1
    @State private var currentThreadID: UUID?
    @State private var showingChats = false
    @State private var didRestore = false
    @AppStorage("lastChatThread") private var lastThreadID = ""
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingChats = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Chats")
                }
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat") { startNewChat() }
                    }
                }
            }
            .sheet(isPresented: $showingChats) {
                ChatListView(currentID: currentThreadID) { thread in
                    open(thread)
                } onNew: {
                    startNewChat()
                }
            }
            .onAppear(perform: restoreLastChat)
        }
    }

    // MARK: Saved chats

    private func restoreLastChat() {
        guard !didRestore else { return }
        didRestore = true
        guard let id = UUID(uuidString: lastThreadID),
              let thread = try? context.fetch(FetchDescriptor<ChatThread>(predicate: #Predicate<ChatThread> { $0.id == id })).first
        else { return }
        open(thread)
    }

    private func makeAssistant() -> FinanceAssistant {
        let catalog = CategoryCatalog.load(context)
        let budgets = ((try? context.fetch(FetchDescriptor<CategoryBudget>())) ?? []).map {
            (name: catalog.info(key: $0.categoryRaw).name, key: $0.categoryRaw, limit: $0.monthlyLimit)
        }
        assistantDataCount = entries.count
        return FinanceAssistant(facts: AppData.facts(context: context), budgets: budgets, catalog: catalog)
    }

    private func open(_ thread: ChatThread) {
        messages = (try? JSONDecoder().decode([ChatMessage].self, from: thread.messagesData)) ?? []
        let history = (try? JSONSerialization.jsonObject(with: thread.agentHistoryData)) as? [[String: Any]] ?? []
        let a = makeAssistant()
        let lastUser = messages.last(where: { $0.fromUser })?.text
        let lastAnswer = messages.last(where: { !$0.fromUser })?.text
        a.restore(agentHistory: history, lastQuestion: lastUser, lastAnswer: lastAnswer)
        assistant = a
        currentThreadID = thread.id
        lastThreadID = thread.id.uuidString
    }

    private func startNewChat() {
        saveChat()
        messages = []
        assistant = makeAssistant()
        currentThreadID = nil
        lastThreadID = ""
    }

    private func saveChat() {
        guard !messages.isEmpty else { return }
        let thread: ChatThread
        if let id = currentThreadID,
           let existing = try? context.fetch(FetchDescriptor<ChatThread>(predicate: #Predicate<ChatThread> { $0.id == id })).first {
            thread = existing
        } else {
            let first = messages.first(where: { $0.fromUser })?.text ?? "Chat"
            thread = ChatThread(title: String(first.prefix(60)))
            context.insert(thread)
            currentThreadID = thread.id
            lastThreadID = thread.id.uuidString
        }
        thread.messagesData = (try? JSONEncoder().encode(messages)) ?? Data()
        if let history = assistant?.agentHistory, JSONSerialization.isValidJSONObject(history) {
            thread.agentHistoryData = (try? JSONSerialization.data(withJSONObject: history)) ?? Data()
        }
        thread.updatedAt = Date()
        try? context.save()
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if messages.isEmpty {
                        intro
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                    ForEach($messages) { $m in
                        VStack(alignment: .leading, spacing: 10) {
                            if m.fromUser {
                                UserMessageView(message: m)
                            } else {
                                AssistantMessageView(message: m)
                            }
                            if m.proposal != nil {
                                ProposalCard(message: $m,
                                             onApply: { apply(messageID: m.id) },
                                             onUndo: { undo(messageID: m.id) })
                                    .padding(.leading, 38)
                            }
                            if !m.fromUser && m.id == messages.last?.id && !thinking {
                                followUps.padding(.leading, 38)
                            }
                        }
                        .id(m.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                    }
                    if thinking {
                        ThinkingView(steps: liveSteps)
                            .id("typing")
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: messages.count)
                .animation(.easeInOut(duration: 0.25), value: thinking)
                .animation(.easeInOut(duration: 0.25), value: liveSteps)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: thinking) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: liveSteps.count) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: inputFocused) { _, focused in
                if focused {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: messages.count)
            .safeAreaInset(edge: .bottom) { inputBar }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AIAvatar(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask about your money").font(.title2.bold())
                    Text(CloudAI.isReady ? "Powered by \(CloudAI.model.displayName)" : "On-device")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(CloudAI.isReady
                 ? "I look up your transactions on this iPhone (read-only) and answer. If something's unclear, I'll ask."
                 : "Numbers are calculated from your transactions on this iPhone; nothing leaves your phone.")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Self.starters, id: \.text) { s in
                    Button { send(s.text) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: s.icon).font(.title3).foregroundStyle(.tint)
                            Text(s.text).font(.subheadline).multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(entries.isEmpty)
                }
            }
            if entries.isEmpty {
                Text("Import some transactions first.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    struct Starter: Hashable { let icon: String; let text: String }
    static let starters: [Starter] = [
        Starter(icon: "bag", text: "Where am I spending the most in shopping?"),
        Starter(icon: "banknote", text: "How can I save $1,500 a month?"),
        Starter(icon: "fork.knife", text: "How much did I spend on food last month?"),
        Starter(icon: "repeat", text: "What are my subscriptions costing me?"),
        Starter(icon: "creditcard", text: "Credit cards vs debit this month?"),
        Starter(icon: "tag", text: "Fix categories that look wrong")
    ]

    private var followUps: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["Tell me more", "Show the transactions", "How can I improve this?"], id: \.self) { f in
                    Button { send(f) } label: {
                        Text(f).font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .transition(.opacity)
    }

    private var inputBar: some View {
        let canSend = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !thinking && !entries.isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your money…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(input) }
                .padding(.leading, 16)
                .padding(.vertical, 11)
            Button { send(input) } label: {
                Image(systemName: thinking ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.gray.opacity(0.4)))
                    .symbolEffect(.pulse, isActive: thinking)
            }
            .disabled(!canSend)
            .padding(.trailing, 6)
            .padding(.bottom, 5)
            .animation(.spring(response: 0.3), value: canSend)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(inputFocused ? 0.15 : 0.06)))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func refreshAssistant(note: String?) {
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
        saveChat()
        let applied = p.items.filter { selected.contains($0.id) }.map(\.title)
        refreshAssistant(note: "I applied these changes: " + applied.joined(separator: "; "))
    }

    private func undo(messageID: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }),
              case .applied(let record) = messages[i].proposalState else { return }
        ChangeApplier.undo(record, context: context)
        messages[i].proposalState = .undone
        saveChat()
        refreshAssistant(note: "I undid the changes you proposed earlier.")
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        input = ""
        withAnimation { messages.append(ChatMessage(text: q, fromUser: true)) }
        if assistant == nil {
            assistant = makeAssistant()
        } else if assistantDataCount != entries.count {
            refreshAssistant(note: nil)   // new imports: refresh data, keep the conversation
        }
        liveSteps = []
        thinking = true
        Task {
            let reply = await assistant!.ask(q) { step in
                withAnimation { liveSteps.append(step) }
            }
            var message = ChatMessage(text: reply.text, fromUser: false, source: reply.source.label)
            message.proposal = reply.proposal
            message.steps = reply.steps.isEmpty ? nil : reply.steps
            if let p = reply.proposal { message.selected = Set(p.items.map(\.id)) }
            withAnimation {
                thinking = false
                messages.append(message)
            }
            liveSteps = []
            saveChat()
        }
    }
}

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let text: String
    let fromUser: Bool
    var source: String? = nil
    var proposal: ChangeProposal? = nil
    var selected: Set<UUID> = []
    var proposalState: ProposalState = .pending
    /// Steps Claude took (optional so chats saved by older builds still load).
    var steps: [String]? = nil

    enum ProposalState: Codable {
        case pending, dismissed, undone
        case applied(UndoRecord)
    }
}

private struct UserMessageView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(message.text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

private struct AssistantMessageView: View {
    let message: ChatMessage
    @State private var showSteps = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AIAvatar(size: 26)
            VStack(alignment: .leading, spacing: 8) {
                RichText(text: message.text)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    if let steps = message.steps, !steps.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.35)) { showSteps.toggle() }
                        } label: {
                            Label("\(steps.count) step\(steps.count == 1 ? "" : "s")",
                                  systemImage: showSteps ? "chevron.up" : "list.bullet.indent")
                        }
                        .buttonStyle(.plain)
                    }
                    if let source = message.source {
                        Text(source).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                if showSteps, let steps = message.steps {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Label(step, systemImage: "checkmark.circle").font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

/// Lightweight markdown: paragraphs, **bold**/_italic_, bullet and numbered lists, headings.
private struct RichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t):
                    Text(LocalizedStringKey(t)).font(.headline).padding(.top, 4)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(y: -2)
                        Text(LocalizedStringKey(t))
                    }
                case .numbered(let n, let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        Text(LocalizedStringKey(t))
                    }
                case .paragraph(let t):
                    Text(LocalizedStringKey(t))
                }
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }

    enum Block { case heading(String), bullet(String), numbered(Int, String), paragraph(String) }

    var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                out.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]), n < 100,
                      line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                out.append(.numbered(n, String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }
}

private struct AIAvatar: View {
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Circle()
            )
    }
}

/// Shown while Claude works: animated dots plus the live steps it's taking.
private struct ThinkingView: View {
    let steps: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AIAvatar(size: 26)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Label(step, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                HStack(spacing: 8) {
                    TypingDots()
                    Text(steps.isEmpty ? "Thinking…" : "Working on it…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.6 + 0.4 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.8)))
                        .opacity(0.4 + 0.6 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .foregroundStyle(.tint)
        }
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25), value: configuration.isPressed)
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

/// Saved conversations, newest first.
private struct ChatListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    let currentID: UUID?
    let onOpen: (ChatThread) -> Void
    let onNew: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button { onNew(); dismiss() } label: { Label("New chat", systemImage: "square.and.pencil") }
                if threads.isEmpty {
                    Text("No saved chats yet.").foregroundStyle(.secondary)
                }
                ForEach(threads) { t in
                    Button { onOpen(t); dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title).foregroundStyle(.primary).lineLimit(2)
                                Text(t.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if t.id == currentID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(threads[i]) }
                    try? context.save()
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
