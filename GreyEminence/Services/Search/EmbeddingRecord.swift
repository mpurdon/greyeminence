import Foundation
import SwiftData

/// Lives in its own `ModelContainer` (see `EmbeddingStore`) so the main store
/// stays small and portable — embeddings can be wiped and rebuilt independently,
/// and swapping embedding providers doesn't require a main-schema migration.
@Model
final class EmbeddingRecord {
    enum SourceKind: String, Codable, CaseIterable {
        case transcriptSegment
        case actionItem
        case followUpQuestion
        case meetingSummary
    }

    /// Stable composite id, e.g. "segment:<uuid>" — lets us upsert in place
    /// when re-indexing without scanning for matching source+kind.
    @Attribute(.unique) var id: String
    var sourceID: UUID
    var sourceKindRaw: String
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var text: String
    var vector: Data
    var modelIdentifier: String
    var indexedAt: Date

    var sourceKind: SourceKind {
        SourceKind(rawValue: sourceKindRaw) ?? .transcriptSegment
    }

    init(
        id: String,
        sourceID: UUID,
        sourceKind: SourceKind,
        meetingID: UUID,
        meetingTitle: String,
        meetingDate: Date,
        text: String,
        vector: [Float],
        modelIdentifier: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceKindRaw = sourceKind.rawValue
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate
        self.text = text
        self.vector = Self.encode(vector)
        self.modelIdentifier = modelIdentifier
        self.indexedAt = .now
    }

    var vectorArray: [Float] {
        Self.decode(vector)
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}
