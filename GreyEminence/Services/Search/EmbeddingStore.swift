import Foundation
import SwiftData

/// Thin wrapper around the second `ModelContainer` that owns embeddings.
/// Kept out of the main SwiftData container so the primary store stays simple
/// and so wiping/re-indexing doesn't risk the user's meeting data.
@MainActor
final class EmbeddingStore {
    static let shared: EmbeddingStore? = {
        try? EmbeddingStore()
    }()

    let container: ModelContainer

    init() throws {
        let schema = Schema([EmbeddingRecord.self])
        let url = Self.storeURL()
        let config = ModelConfiguration(
            "GreyEminenceEmbeddings",
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        self.container = try ModelContainer(for: schema, configurations: [config])
    }

    var context: ModelContext { container.mainContext }

    private static func storeURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GreyEminence", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Embeddings.store")
    }

    func upsert(_ record: EmbeddingRecord) {
        let id = record.id
        let existing = try? context.fetch(
            FetchDescriptor<EmbeddingRecord>(predicate: #Predicate { $0.id == id })
        ).first
        if let existing {
            existing.vector = record.vector
            existing.text = record.text
            existing.meetingTitle = record.meetingTitle
            existing.meetingDate = record.meetingDate
            existing.modelIdentifier = record.modelIdentifier
            existing.indexedAt = .now
        } else {
            context.insert(record)
        }
    }

    func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            LogManager.send("EmbeddingStore save failed: \(error.localizedDescription)", category: .general, level: .error)
        }
    }

    func deleteAll() {
        try? context.delete(model: EmbeddingRecord.self)
        save()
    }

    func deleteRecords(matching modelIdentifier: String) {
        let predicate = #Predicate<EmbeddingRecord> { $0.modelIdentifier != modelIdentifier }
        try? context.delete(model: EmbeddingRecord.self, where: predicate)
        save()
    }

    func allRecords(for modelIdentifier: String) -> [EmbeddingRecord] {
        let descriptor = FetchDescriptor<EmbeddingRecord>(
            predicate: #Predicate { $0.modelIdentifier == modelIdentifier }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func count() -> Int {
        (try? context.fetchCount(FetchDescriptor<EmbeddingRecord>())) ?? 0
    }
}
