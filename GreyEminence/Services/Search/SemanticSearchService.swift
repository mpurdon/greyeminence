import Foundation

struct SearchResult: Identifiable {
    let id: String
    let sourceKind: EmbeddingRecord.SourceKind
    let sourceID: UUID
    let meetingID: UUID
    let meetingTitle: String
    let meetingDate: Date
    let text: String
    let score: Float
}

@MainActor
final class SemanticSearchService {
    let store: EmbeddingStore
    let service: EmbeddingService

    init(store: EmbeddingStore, service: EmbeddingService) {
        self.store = store
        self.service = service
    }

    func search(_ query: String, topK: Int = 25, dateRange: ClosedRange<Date>? = nil) async -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let queryVec = await service.embed(trimmed) else { return [] }

        let records = store.allRecords(for: service.modelIdentifier).filter { rec in
            guard let range = dateRange else { return true }
            return range.contains(rec.meetingDate)
        }

        let scored: [SearchResult] = records.compactMap { rec in
            let recVec = rec.vectorArray
            guard recVec.count == queryVec.count else { return nil }
            let score = Self.cosineSimilarity(recVec, queryVec)
            return SearchResult(
                id: rec.id,
                sourceKind: rec.sourceKind,
                sourceID: rec.sourceID,
                meetingID: rec.meetingID,
                meetingTitle: rec.meetingTitle,
                meetingDate: rec.meetingDate,
                text: rec.text,
                score: score
            )
        }

        return Array(scored.sorted { $0.score > $1.score }.prefix(topK))
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        var aMag: Float = 0
        var bMag: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            aMag += a[i] * a[i]
            bMag += b[i] * b[i]
        }
        let denom = sqrt(aMag) * sqrt(bMag)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
