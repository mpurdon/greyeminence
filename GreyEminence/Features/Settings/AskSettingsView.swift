import AppKit
import SwiftUI
import SwiftData

struct AskSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @AppStorage("embeddingProvider") private var embeddingProviderRaw = EmbeddingProvider.nlEmbedding.rawValue
    @AppStorage("askSnippetCount") private var askSnippetCount: Int = 15
    @AppStorage("askContextWindow") private var askContextWindow: Int = 2

    private var reindex = EmbeddingReindexController.shared
    private var navigation = SettingsNavigation.shared

    private var provider: EmbeddingProvider {
        EmbeddingProvider(rawValue: embeddingProviderRaw) ?? .nlEmbedding
    }

    /// One line saying what the index is built with and whose account
    /// pays — chosen in Settings → AI, alongside every other model.
    private var methodSummary: String {
        switch provider {
        case .titan, .cohere:
            let account = AIAccountSettings.resolved(for: .embeddings)
            return "\(provider.shortLabel) via \(account.profile) · \(account.region)"
        case .nlEmbedding, .voyage:
            return provider.shortLabel
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Method") {
                    HStack(spacing: 6) {
                        Text(methodSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Change in AI settings") {
                            navigation.pane = .ai
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                if !provider.isAvailable {
                    Label(provider.unavailableReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LabeledContent("Indexed items") {
                    Text("\(reindex.embeddingCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Indexed with this method") {
                    Text(reindex.coverage.label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(reindex.coverage.indexed == 0 ? .orange : .secondary)
                }
                LabeledContent("Last reindex") {
                    Text(reindex.lastReindexAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reindexError = reindex.error {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reindexError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                            Button("Troubleshooting") {
                                openWindow(id: "help-doc", value: HelpDoc.search)
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
                HStack {
                    Button(reindex.isReindexing ? "Reindexing…" : "Reindex all meetings") {
                        Task { await reindex.reindexAll(modelContext: modelContext) }
                    }
                    .disabled(reindex.isReindexing || !provider.isAvailable)
                    if reindex.isReindexing && reindex.total > 0 {
                        ProgressView(value: Double(reindex.done), total: Double(reindex.total))
                            .frame(width: 120)
                        Text("\(reindex.done)/\(reindex.total) meetings")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Embeddings are stored in a separate database from your meetings so wiping or re-indexing can't corrupt your main store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let failure = EmbeddingStore.initFailureMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Embedding store can't open: \(failure)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Rebuild embedding store") {
                                reindex.rebuildStore()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                // Help sits where the setup happens, not only under the Help
                // menu — this pane is where someone is when they get stuck.
                Button {
                    openWindow(id: "help-doc", value: HelpDoc.search)
                } label: {
                    Label("How to set this up", systemImage: "questionmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.link)
            } header: {
                Label("Index", systemImage: "rectangle.stack")
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
                    "Transcript lead-in (segments before each chunk): \(askContextWindow)",
                    value: $askContextWindow,
                    in: 0...10,
                    step: 1
                )
                Text("Each ranked snippet is now a paragraph-sized chunk that already includes surrounding turns. The lead-in adds extra segments before the chunk for cases where the answer hinges on what was said just before. Both settings cost more tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Synthesis", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                HStack {
                    Button(isMaintaining ? "Cleaning…" : "Run cleanup now") {
                        Task { await runMaintenance() }
                    }
                    .disabled(isMaintaining)
                    if let summary = maintenanceSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Text("Removes orphan embeddings, prunes stale segment chunks left behind by older re-processing runs, clears stuck analysis flags, and backfills the conversation context for legacy tasks. Runs automatically once per day at launch — this button forces it now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Maintenance", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
        .onAppear { reindex.refreshCounts() }
    }

    @State private var isMaintaining = false
    @State private var maintenanceSummary: String?

    @MainActor
    private func runMaintenance() async {
        isMaintaining = true
        defer {
            isMaintaining = false
            reindex.refreshCounts()
        }
        let report = await MaintenanceService.runStartupMaintenance(modelContext: modelContext, force: true)
        maintenanceSummary = report.summary
    }
}
