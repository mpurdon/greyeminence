import SwiftUI
import SwiftData

/// The conversation itself: turns stacked oldest-first with a composer pinned
/// to the bottom.
struct AskChatView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("askSnippetCount") private var snippetCount: Int = 15
    @AppStorage("askContextWindow") private var contextWindow: Int = 2
    @AppStorage("askDateFilter") private var defaultDateFilterRaw: String = AskDateFilter.anyTime.rawValue
    @AppStorage("showInspector") private var showInspector = true

    @Bindable var viewModel: AskViewModel

    @Environment(\.openWindow) private var openWindow
    @FocusState private var composerFocused: Bool

    private static let starters = [
        "What did I commit to this week?",
        "What's still unresolved about the document service?",
        "Summarise everything I've discussed with the OLP team",
        "What was on screen when we talked about the schema?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let number = AskCitations.number(fromURL: url) else { return .systemAction }
            viewModel.selectedSourceNumber = number
            viewModel.focusedTurnID = nil
            showInspector = true
            return .handled
        })
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if let conversation = viewModel.currentConversation, !conversation.turns.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.turns) { turn in
                            turnView(turn, conversation: conversation)
                                .id(turn.id)
                        }
                        if viewModel.isBusy {
                            activityRow
                                .id(Self.activityAnchor)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: conversation.turns.count) { _, _ in
                    scrollToEnd(proxy, conversation: conversation)
                }
                .onChange(of: viewModel.phase) { _, _ in
                    scrollToEnd(proxy, conversation: conversation)
                }
                .onAppear {
                    scrollToEnd(proxy, conversation: conversation, animated: false)
                }
            }
        } else {
            emptyState
        }
    }

    private static let activityAnchor = "ask-activity"

    private func scrollToEnd(_ proxy: ScrollViewProxy, conversation: AskConversation, animated: Bool = true) {
        let target: AnyHashable? = viewModel.isBusy
            ? Self.activityAnchor
            : conversation.turns.last?.id
        guard let target else { return }
        // A frame's delay lets the new row exist before we scroll to it.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Ask about your meetings")
                    .font(.title3.weight(.semibold))
                Text("Answers are grounded in your transcripts and screen shares. Follow up to go deeper — the conversation keeps its sources.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("How search works, and how to improve it") {
                    openWindow(id: "help-doc", value: HelpDoc.search)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            VStack(spacing: 8) {
                ForEach(Self.starters, id: \.self) { starter in
                    Button {
                        viewModel.draft = starter
                        submit()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text(starter)
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 420, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - One turn

    @ViewBuilder
    private func turnView(_ turn: AskTurn, conversation: AskConversation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            questionBubble(turn)

            if let answer = turn.answer {
                answerView(turn, answer: answer, conversation: conversation)
            } else if let error = turn.errorMessage {
                errorView(turn, message: error, conversation: conversation)
            }
        }
    }

    @ViewBuilder
    private func questionBubble(_ turn: AskTurn) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                Text(turn.question)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                if let rewritten = turn.searchQuery, rewritten != turn.question {
                    // Surfacing the rewrite explains an otherwise mysterious
                    // set of results when a follow-up gets expanded.
                    Label("Searched: \(rewritten)", systemImage: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                if !turn.personFilterNames.isEmpty {
                    // A restriction this strong has to be visible: it is why a
                    // question about a widely-discussed topic can come back
                    // with only a handful of snippets.
                    Label(
                        "Scoped to \(turn.personFilterNames.formatted(.list(type: .and))) · \(turn.personFilterMeetingCount) meetings + mentions",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .help("Searched the meetings they attended plus anywhere they're named, and ranked on the rest of your question")
                }
                if let note = turn.retrievalNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .multilineTextAlignment(.trailing)
                        .help("Vector search needs the embedding model; only exact and near-exact wording could be matched for this question")
                }
            }
            .frame(maxWidth: 520, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func answerView(_ turn: AskTurn, answer: String, conversation: AskConversation) -> some View {
        let known = Set(conversation.sources.map(\.number))
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText(markdown: AskCitations.linkify(answer, known: known))
                .font(.body)
            answerFooter(turn, answer: answer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func answerFooter(_ turn: AskTurn, answer: String) -> some View {
        HStack(spacing: 10) {
            if !turn.promptedNumbers.isEmpty {
                Button {
                    viewModel.focusedTurnID = viewModel.focusedTurnID == turn.id ? nil : turn.id
                    viewModel.selectedSourceNumber = nil
                    showInspector = true
                } label: {
                    Label(
                        turn.citedNumbers.isEmpty
                            ? "\(turn.promptedNumbers.count) sources"
                            : "\(turn.promptedNumbers.count) sources · \(turn.citedNumbers.count) cited",
                        systemImage: "text.magnifyingglass"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.focusedTurnID == turn.id ? Color.accentColor : .secondary)
                .help("Show the snippets behind this answer")
            }

            CopyButton(content: answer, label: "Copy")

            if turn.id == viewModel.currentConversation?.turns.last?.id {
                Button {
                    viewModel.retryLastTurn(
                        mainContext: modelContext,
                        snippetCount: snippetCount,
                        contextWindow: contextWindow
                    )
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(viewModel.isBusy)
                .help("Ask this again")
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func errorView(_ turn: AskTurn, message: String, conversation: AskConversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if turn.id == conversation.turns.last?.id {
                Button {
                    viewModel.retryLastTurn(
                        mainContext: modelContext,
                        snippetCount: snippetCount,
                        contextWindow: contextWindow
                    )
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .disabled(viewModel.isBusy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var activityRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(phaseLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var phaseLabel: String {
        switch viewModel.phase {
        case .idle: ""
        case .condensing: "Working out what to search for…"
        case .searching: "Searching your meetings…"
        case .answering: "Reading the snippets…"
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    viewModel.currentConversation?.turns.isEmpty == false
                        ? "Ask a follow-up…"
                        : "Ask anything about your meetings…",
                    text: $viewModel.draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($composerFocused)
                .onSubmit(submit)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                if viewModel.isBusy {
                    Button {
                        viewModel.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.4))
                    .disabled(!canSubmit)
                    .help("Ask (Return)")
                }
            }
            Text("Return to send · Shift-Return for a new line")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background)
        .onAppear { composerFocused = true }
    }

    private var canSubmit: Bool {
        !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isBusy
    }

    private func submit() {
        guard canSubmit else { return }
        viewModel.submitDraft(
            mainContext: modelContext,
            snippetCount: snippetCount,
            contextWindow: contextWindow,
            defaultFilter: AskDateFilter(rawValue: defaultDateFilterRaw) ?? .anyTime
        )
    }
}
