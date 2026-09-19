import Foundation
import SwiftData

/// Progress and outcome of rebuilding the Ask index, shared by the two
/// panes that can start one: Settings → AI (on switching the embedding
/// method) and Settings → Ask (the Reindex button). One object so a rebuild
/// started from either pane shows its progress in both.
@Observable
@MainActor
final class EmbeddingReindexController {
    static let shared = EmbeddingReindexController()

    static let lastReindexKey = "lastReindexAt"

    private(set) var isReindexing = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var error: String?
    private(set) var embeddingCount = 0
    private(set) var coverage = Coverage(indexed: 0, total: 0)

    /// How much of the index the *currently selected* method has produced.
    /// The headline count includes records from every method ever used, so
    /// on its own it hides exactly the problem the panes need to show.
    struct Coverage: Equatable {
        let indexed: Int
        let total: Int

        var label: String {
            total == 0 ? "\(indexed)" : "\(indexed) of \(total)"
        }
    }

    private init() {}

    var lastReindexAt: Date? {
        let stamp = UserDefaults.standard.double(forKey: Self.lastReindexKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    static var currentProvider: EmbeddingProvider {
        EmbeddingProvider(rawValue: UserDefaults.standard.string(forKey: "embeddingProvider") ?? "") ?? .nlEmbedding
    }

    func refreshCounts() {
        guard let store = EmbeddingStore.shared else {
            embeddingCount = 0
            coverage = Coverage(indexed: 0, total: 0)
            return
        }
        let total = store.count()
        embeddingCount = total
        let identifier = Self.currentProvider.makeService().modelIdentifier
        coverage = Coverage(indexed: store.count(forModel: identifier), total: total)
    }

    func rebuildStore() {
        do {
            try EmbeddingStore.resetOnDisk()
        } catch {
            // resetOnDisk surfaced the error; the banner stays for a retry.
        }
        refreshCounts()
    }

    func reindexAll(modelContext: ModelContext) async {
        guard !isReindexing, let store = EmbeddingStore.shared else { return }
        let service = Self.currentProvider.makeService()
        isReindexing = true
        error = nil
        done = 0
        total = 0
        defer {
            isReindexing = false
            refreshCounts()
        }
        let indexer = EmbeddingIndexer(store: store, service: service)
        let outcome = await indexer.reindexAll(mainContext: modelContext) { [weak self] done, total in
            self?.done = done
            self?.total = total
        }
        switch outcome {
        case .completed:
            error = nil
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastReindexKey)
        case .unavailable(let message), .aborted(let message):
            error = message
        }
    }
}
