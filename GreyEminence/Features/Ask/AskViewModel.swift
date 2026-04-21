import Foundation
import SwiftData

struct AskHistoryEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var query: String
    var timestamp: Date
    var results: [CodableSearchResult]
    var synthesizedAnswer: String?
    var dateFilterRaw: String?
}

enum AskDateFilter: String, CaseIterable, Identifiable {
    case anyTime
    case last7Days
    case last30Days
    case last3Months
    case lastYear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anyTime: "Any time"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .last3Months: "Last 3 months"
        case .lastYear: "Last year"
        }
    }

    func range(now: Date = .now) -> ClosedRange<Date>? {
        let cal = Calendar.current
        switch self {
        case .anyTime: return nil
        case .last7Days: return (cal.date(byAdding: .day, value: -7, to: now) ?? now)...now
        case .last30Days: return (cal.date(byAdding: .day, value: -30, to: now) ?? now)...now
        case .last3Months: return (cal.date(byAdding: .month, value: -3, to: now) ?? now)...now
        case .lastYear: return (cal.date(byAdding: .year, value: -1, to: now) ?? now)...now
        }
    }
}

struct CodableSearchResult: Codable {
    var id: String
    var sourceKindRaw: String
    var sourceID: UUID
    var meetingID: UUID
    var meetingTitle: String
    var meetingDate: Date
    var text: String
    var score: Float

    init(_ r: SearchResult) {
        self.id = r.id
        self.sourceKindRaw = r.sourceKind.rawValue
        self.sourceID = r.sourceID
        self.meetingID = r.meetingID
        self.meetingTitle = r.meetingTitle
        self.meetingDate = r.meetingDate
        self.text = r.text
        self.score = r.score
    }

    var toSearchResult: SearchResult {
        SearchResult(
            id: id,
            sourceKind: EmbeddingRecord.SourceKind(rawValue: sourceKindRaw) ?? .transcriptSegment,
            sourceID: sourceID,
            meetingID: meetingID,
            meetingTitle: meetingTitle,
            meetingDate: meetingDate,
            text: text,
            score: score
        )
    }
}

@Observable
@MainActor
final class AskViewModel {
    var query: String = ""
    var results: [SearchResult] = []
    var synthesizedAnswer: String?
    var isSearching: Bool = false
    var isSynthesizing: Bool = false
    var errorMessage: String?
    var history: [AskHistoryEntry] = []

    private let historyKey = "askHistory"
    private let maxHistoryItems = 30

    init() {
        loadHistory()
    }

    func runSearch(mainContext: ModelContext, snippetCount: Int, contextWindow: Int, dateFilter: AskDateFilter) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let store = EmbeddingStore.shared else {
            errorMessage = "Embedding store unavailable"
            return
        }

        let providerRaw = UserDefaults.standard.string(forKey: "embeddingProvider") ?? EmbeddingProvider.nlEmbedding.rawValue
        let provider = EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
        let service = provider.makeService()
        guard service.isAvailable else {
            errorMessage = "The \(provider.shortLabel) provider isn't implemented yet. Switch to On-device in Settings."
            return
        }

        isSearching = true
        errorMessage = nil
        synthesizedAnswer = nil
        defer { isSearching = false }

        let search = SemanticSearchService(store: store, service: service)
        let found = await search.search(trimmed, topK: 40, dateRange: dateFilter.range())
        results = found

        guard !found.isEmpty else {
            errorMessage = dateFilter == .anyTime
                ? "No matches. Try \"Reindex all meetings\" in Settings to backfill embeddings."
                : "No matches in \(dateFilter.label.lowercased()). Try widening the date range."
            return
        }

        await synthesize(found: found, mainContext: mainContext, snippetCount: snippetCount, contextWindow: contextWindow)

        saveToHistory(query: trimmed, results: found, answer: synthesizedAnswer, dateFilter: dateFilter)
    }

    private func synthesize(found: [SearchResult], mainContext: ModelContext, snippetCount: Int, contextWindow: Int) async {
        guard let client = try? await AIClientFactory.makeClient() else {
            errorMessage = "AI client unavailable — showing ranked snippets only."
            return
        }
        isSynthesizing = true
        defer { isSynthesizing = false }

        let context = buildContext(from: Array(found.prefix(snippetCount)), mainContext: mainContext, contextWindow: contextWindow)

        let prompt = """
        You are answering a question based only on snippets from the user's past meetings.

        QUESTION:
        \(query)

        SNIPPETS (ordered by relevance, most relevant first):
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

    private func buildContext(from results: [SearchResult], mainContext: ModelContext, contextWindow: Int) -> String {
        results.enumerated().map { i, r in
            let number = i + 1
            let prefix = "[\(number)] (\(r.meetingTitle), \(DateFormatter.shortDate.string(from: r.meetingDate)))"
            if r.sourceKind == .transcriptSegment, contextWindow > 0 {
                let neighbors = fetchSegmentContext(
                    meetingID: r.meetingID,
                    segmentID: r.sourceID,
                    window: contextWindow,
                    mainContext: mainContext
                )
                return "\(prefix) \(neighbors)"
            }
            return "\(prefix) \(r.text)"
        }.joined(separator: "\n\n")
    }

    private func fetchSegmentContext(meetingID: UUID, segmentID: UUID, window: Int, mainContext: ModelContext) -> String {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        guard let meeting = try? mainContext.fetch(descriptor).first else { return "" }
        let sorted = meeting.segments.sorted { $0.startTime < $1.startTime }
        guard let idx = sorted.firstIndex(where: { $0.id == segmentID }) else { return "" }
        let lo = max(0, idx - window)
        let hi = min(sorted.count - 1, idx + window)
        return sorted[lo...hi].map { $0.text }.joined(separator: " ")
    }

    // MARK: - History

    func restore(_ entry: AskHistoryEntry) {
        query = entry.query
        results = entry.results.map { $0.toSearchResult }
        synthesizedAnswer = entry.synthesizedAnswer
        errorMessage = nil
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    func deleteHistory(_ entry: AskHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        persistHistory()
    }

    private func saveToHistory(query: String, results: [SearchResult], answer: String?, dateFilter: AskDateFilter) {
        history.removeAll { $0.query.caseInsensitiveCompare(query) == .orderedSame }
        let entry = AskHistoryEntry(
            query: query,
            timestamp: .now,
            results: results.map { CodableSearchResult($0) },
            synthesizedAnswer: answer,
            dateFilterRaw: dateFilter == .anyTime ? nil : dateFilter.rawValue
        )
        history.insert(entry, at: 0)
        if history.count > maxHistoryItems {
            history = Array(history.prefix(maxHistoryItems))
        }
        persistHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return }
        history = (try? JSONDecoder().decode([AskHistoryEntry].self, from: data)) ?? []
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }
}
