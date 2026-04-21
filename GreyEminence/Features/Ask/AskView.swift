import SwiftUI
import SwiftData

struct AskView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("embeddingProvider") private var providerRaw: String = EmbeddingProvider.nlEmbedding.rawValue
    @AppStorage("askSnippetCount") private var snippetCount: Int = 15
    @AppStorage("askContextWindow") private var contextWindow: Int = 2
    @AppStorage("askDateFilter") private var dateFilterRaw: String = AskDateFilter.anyTime.rawValue

    @Bindable var viewModel: AskViewModel
    var onResultSelected: ((SearchResult) -> Void)?

    @State private var showHistory: Bool = true

    private var provider: EmbeddingProvider {
        EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
    }

    private var dateFilter: AskDateFilter {
        AskDateFilter(rawValue: dateFilterRaw) ?? .anyTime
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if showHistory {
                    historySidebar
                        .frame(width: 200)
                    Divider()
                }
                mainContent
            }
        }
    }

    // MARK: - History sidebar

    @ViewBuilder
    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !viewModel.history.isEmpty {
                    Button {
                        viewModel.clearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear history")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            Divider()

            if viewModel.history.isEmpty {
                Text("Past searches will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.history) { entry in
                            historyRow(entry)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ entry: AskHistoryEntry) -> some View {
        let isCurrent = entry.query == viewModel.query && !viewModel.results.isEmpty
        Button {
            viewModel.restore(entry)
            if let raw = entry.dateFilterRaw, AskDateFilter(rawValue: raw) != nil {
                dateFilterRaw = raw
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.query)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(entry.timestamp, format: .relative(presentation: .numeric))
                    Text("·")
                    Text("\(entry.results.count) results")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isCurrent ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                viewModel.deleteHistory(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isSearching && viewModel.results.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Searching your meetings…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty && viewModel.synthesizedAnswer == nil && !viewModel.isSynthesizing {
            ContentUnavailableView(
                "Ask a question",
                systemImage: "sparkles.square.filled.on.square",
                description: Text("Try: \"What did I want to bring up with Erin in my next 1:1?\" or \"Open questions about authentication\"")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            resultsList
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showHistory.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .help(showHistory ? "Hide history" : "Show history")

                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Ask anything about your meetings…", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit(runSearch)

                Menu {
                    ForEach(AskDateFilter.allCases) { option in
                        Button {
                            dateFilterRaw = option.rawValue
                        } label: {
                            if option == dateFilter {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    Label(dateFilter.label, systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Limit search to meetings within a date range")

                if viewModel.isSearching || viewModel.isSynthesizing {
                    ProgressView().controlSize(.small)
                }
                Button("Ask") { runSearch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSearching)
                    .keyboardShortcut(.return, modifiers: [])
            }

            HStack(spacing: 10) {
                if let err = viewModel.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Top \(snippetCount) snippets ±\(contextWindow) context · \(dateFilter.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Provider: \(provider.shortLabel)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background)
    }

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isSynthesizing {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Synthesizing answer from \(viewModel.results.prefix(snippetCount).count) snippets…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else if let answer = viewModel.synthesizedAnswer {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Answer", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(answer)
                            .textSelection(.enabled)
                            .font(.body)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if !viewModel.results.isEmpty {
                    HStack {
                        Text("Ranked snippets")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("(\(viewModel.results.count))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("most relevant first")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { i, result in
                    Button {
                        onResultSelected?(result)
                    } label: {
                        resultRow(result, index: i + 1, sentToLLM: i < snippetCount)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SearchResult, index: Int, sentToLLM: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(index)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(kindLabel(result.sourceKind))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(kindColor(result.sourceKind).opacity(0.18), in: Capsule())
                    .foregroundStyle(kindColor(result.sourceKind))
                Text(result.meetingTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(result.meetingDate, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if sentToLLM {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .help("Included in the LLM context")
                }
                Text(percentage(result.score))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(scoreColor(result.score))
            }
            Text(result.text)
                .font(.callout)
                .lineLimit(3)
                .foregroundStyle(.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func kindLabel(_ kind: EmbeddingRecord.SourceKind) -> String {
        switch kind {
        case .transcriptSegment: "TRANSCRIPT"
        case .actionItem: "TASK"
        case .followUpQuestion: "QUESTION"
        case .meetingSummary: "SUMMARY"
        }
    }

    private func kindColor(_ kind: EmbeddingRecord.SourceKind) -> Color {
        switch kind {
        case .transcriptSegment: .indigo
        case .actionItem: .orange
        case .followUpQuestion: .teal
        case .meetingSummary: .purple
        }
    }

    private func percentage(_ score: Float) -> String {
        let pct = Int((max(0, min(1, score)) * 100).rounded())
        return "\(pct)%"
    }

    private func scoreColor(_ score: Float) -> Color {
        if score >= 0.7 { return .green }
        if score >= 0.5 { return .primary }
        if score >= 0.3 { return .secondary }
        return .secondary.opacity(0.6)
    }

    private func runSearch() {
        Task {
            await viewModel.runSearch(
                mainContext: modelContext,
                snippetCount: snippetCount,
                contextWindow: contextWindow,
                dateFilter: dateFilter
            )
        }
    }
}
