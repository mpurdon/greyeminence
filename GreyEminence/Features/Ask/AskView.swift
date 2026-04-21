import SwiftUI
import SwiftData

struct AskView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("embeddingProvider") private var providerRaw: String = EmbeddingProvider.nlEmbedding.rawValue

    @State private var query: String = ""
    @State private var results: [SearchResult] = []
    @State private var synthesizedAnswer: String?
    @State private var isSearching = false
    @State private var isSynthesizing = false
    @State private var indexStatus: String = ""

    var onMeetingSelected: ((UUID) -> Void)?

    private var provider: EmbeddingProvider {
        EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if results.isEmpty && synthesizedAnswer == nil && !isSearching {
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
        .onAppear(perform: refreshStatus)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Ask anything about your meetings…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit(runSearch)
                if isSearching || isSynthesizing {
                    ProgressView().controlSize(.small)
                }
                Button("Ask") { runSearch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }

            HStack(spacing: 10) {
                Text(indexStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Provider: \(provider.shortLabel)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let answer = synthesizedAnswer {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Answer", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(answer)
                            .textSelection(.enabled)
                            .font(.body)
                    }
                    .padding(12)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if !results.isEmpty {
                    Text("Relevant snippets (\(results.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ForEach(results) { result in
                    Button {
                        onMeetingSelected?(result.meetingID)
                    } label: {
                        resultRow(result)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
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
                Text(String(format: "%.2f", result.score))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
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

    private func refreshStatus() {
        guard let store = EmbeddingStore.shared else {
            indexStatus = "Embedding store unavailable"
            return
        }
        let count = store.count()
        indexStatus = "\(count) items indexed"
    }

    private func runSearch() {
        guard let store = EmbeddingStore.shared else { return }
        let service = provider.makeService()
        guard service.isAvailable else {
            synthesizedAnswer = "This provider isn't implemented yet. Switch to On-device in Settings."
            results = []
            return
        }

        Task {
            isSearching = true
            defer { isSearching = false }
            let search = SemanticSearchService(store: store, service: service)
            let found = await search.search(query)
            results = found
            synthesizedAnswer = nil
            await synthesize(using: found)
        }
    }

    private func synthesize(using found: [SearchResult]) async {
        guard !found.isEmpty else { return }
        guard let client = try? await AIClientFactory.makeClient() else { return }
        isSynthesizing = true
        defer { isSynthesizing = false }

        let context = found.prefix(15).enumerated().map { i, r in
            "[\(i + 1)] (\(r.meetingTitle), \(DateFormatter.shortDate.string(from: r.meetingDate))) \(r.text)"
        }.joined(separator: "\n\n")

        let prompt = """
        You are answering a question based only on snippets from the user's past meetings.

        QUESTION:
        \(query)

        SNIPPETS:
        \(context)

        Give a concise, direct answer grounded in the snippets. Cite snippets by their bracket number [1], [2] inline. If the snippets don't contain enough to answer, say so briefly.
        """

        do {
            let response = try await client.sendMessage(
                system: "You help the user recall things from their past meetings.",
                userContent: prompt
            )
            synthesizedAnswer = response
        } catch {
            synthesizedAnswer = "Couldn't synthesize an answer: \(error.localizedDescription)"
        }
    }
}
