import SwiftUI
import SwiftData

struct AskSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("embeddingProvider") private var embeddingProviderRaw = EmbeddingProvider.nlEmbedding.rawValue
    @AppStorage("askSnippetCount") private var askSnippetCount: Int = 15
    @AppStorage("askContextWindow") private var askContextWindow: Int = 2
    @AppStorage("autoReprocessMeetings") private var autoReprocessMeetings: Bool = true

    @State private var reindexTotal = 0
    @State private var reindexDone = 0
    @State private var isReindexing = false
    @State private var embeddingCount = 0

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $embeddingProviderRaw) {
                    ForEach(EmbeddingProvider.allCases) { provider in
                        Text(provider.label).tag(provider.rawValue)
                    }
                }
                if let provider = EmbeddingProvider(rawValue: embeddingProviderRaw), !provider.isAvailable {
                    Text("This provider isn't implemented yet — falling back to on-device for searches.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Indexed items") {
                    Text("\(embeddingCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(isReindexing ? "Reindexing…" : "Reindex all meetings") {
                        Task { await reindexAll() }
                    }
                    .disabled(isReindexing)
                    if isReindexing && reindexTotal > 0 {
                        ProgressView(value: Double(reindexDone), total: Double(reindexTotal))
                            .frame(width: 120)
                        Text("\(reindexDone)/\(reindexTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Embeddings are stored in a separate database from your meetings so wiping or re-indexing can't corrupt your main store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Index", systemImage: "rectangle.stack")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                Toggle("Re-transcribe meetings after recording", isOn: $autoReprocessMeetings)
                Text("Live transcription uses a fast model (FluidAudio Parakeet). When a meeting ends, the audio is re-transcribed in the background with WhisperKit large-v3, and AI insights + embeddings are rebuilt on the upgraded transcript. Re-processing pauses automatically while another recording is in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("First run downloads the large-v3 model (~1.5 GB).")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } header: {
                Label("High-accuracy re-transcription", systemImage: "waveform.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                Stepper(
                    "Snippets sent to LLM: \(askSnippetCount)",
                    value: $askSnippetCount,
                    in: 3...50,
                    step: 1
                )
                Stepper(
                    "Transcript context (segments before/after): \(askContextWindow)",
                    value: $askContextWindow,
                    in: 0...10,
                    step: 1
                )
                Text("More snippets give the LLM broader coverage; more context gives it richer conversational flow around each match. Both cost more tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Synthesis", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
        .onAppear { embeddingCount = EmbeddingStore.shared?.count() ?? 0 }
    }

    @MainActor
    private func reindexAll() async {
        guard let store = EmbeddingStore.shared else { return }
        let provider = EmbeddingProvider(rawValue: embeddingProviderRaw) ?? .nlEmbedding
        let service = provider.makeService()
        guard service.isAvailable else { return }

        isReindexing = true
        defer {
            isReindexing = false
            embeddingCount = store.count()
        }
        let indexer = EmbeddingIndexer(store: store, service: service)
        await indexer.reindexAll(mainContext: modelContext) { done, total in
            reindexDone = done
            reindexTotal = total
        }
    }
}
