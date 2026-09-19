import Foundation

/// A search hit, flattened for persistence. `SearchResult` carries a
/// non-Codable enum and is rebuilt from disk on load.
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

    var sourceKind: EmbeddingRecord.SourceKind {
        EmbeddingRecord.SourceKind(rawValue: sourceKindRaw) ?? .transcriptSegment
    }

    var toSearchResult: SearchResult {
        SearchResult(
            id: id,
            sourceKind: sourceKind,
            sourceID: sourceID,
            meetingID: meetingID,
            meetingTitle: meetingTitle,
            meetingDate: meetingDate,
            text: text,
            score: score
        )
    }
}

/// One snippet in a conversation's source pool.
///
/// `number` is the citation number the model was told to use, and it is
/// assigned once and never reused: `[3]` means the same snippet in the tenth
/// answer as it did in the first. That stability is what lets a follow-up
/// question ("say more about the second point") be grounded in a snippet
/// retrieved several turns ago, and what lets a citation tapped in any
/// message resolve against the sources panel.
struct AskSource: Codable, Identifiable {
    var number: Int
    var result: CodableSearchResult
    /// Turn that first pulled this snippet in — shown as "from turn N" so the
    /// panel can be read as a history of what the search actually found.
    var firstSeenTurn: UUID

    var id: String { result.id }
}

/// One question-and-answer exchange.
struct AskTurn: Codable, Identifiable {
    var id: UUID = UUID()
    var question: String
    /// The standalone query actually sent to the retriever. Differs from
    /// `question` whenever the question leaned on conversational context
    /// ("what about hers?") and had to be condensed first.
    var searchQuery: String?
    var answer: String?
    var errorMessage: String?
    /// Source numbers retrieved for this turn, best first.
    var retrievedNumbers: [Int] = []
    /// Source numbers actually placed in the model's context — a subset of
    /// the pool, so the UI can be honest about what grounded the answer.
    var promptedNumbers: [Int] = []
    /// Source numbers the answer cites, parsed out of the response text.
    var citedNumbers: [Int] = []
    /// People the question named, resolved against the contact roster. When
    /// non-empty the search was restricted to meetings they attended and their
    /// names were removed from the query text.
    var personFilterNames: [String] = []
    /// How many meetings that restriction left. Shown alongside the names so a
    /// narrow search is visible rather than mysterious.
    var personFilterMeetingCount: Int = 0
    /// Set when retrieval ran below full strength — the query could not be
    /// embedded, so only the keyword pass ranked. Shown under the question so
    /// a thin answer is explained by the cause, not by the index.
    var retrievalNote: String?
    var createdAt: Date = .now
}

/// A threaded Ask session: an ordered list of turns plus the pool of snippets
/// retrieved across all of them.
struct AskConversation: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var dateFilterRaw: String = AskDateFilter.anyTime.rawValue
    var turns: [AskTurn] = []
    var sources: [AskSource] = []

    /// A pool this large is already past the point where more snippets help
    /// the answer, and it keeps the on-disk file from growing without bound
    /// over a long-running thread.
    static let maxSources = 200

    var dateFilter: AskDateFilter {
        AskDateFilter(rawValue: dateFilterRaw) ?? .anyTime
    }

    func source(number: Int) -> AskSource? {
        sources.first { $0.number == number }
    }

    /// Every source number cited by the last `count` answered turns. These are
    /// carried into the next prompt regardless of what the new search returns,
    /// so a follow-up can still see the evidence it is being asked about.
    func recentlyCitedNumbers(lastTurns count: Int) -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for turn in turns.suffix(count) {
            for number in turn.citedNumbers where !seen.contains(number) {
                seen.insert(number)
                ordered.append(number)
            }
        }
        return ordered
    }

    /// Fold new search results into the pool, returning their numbers in rank
    /// order. A snippet already in the pool keeps its original number — and
    /// takes the better of the two scores, since relevance is relative to a
    /// query and a later turn may have matched it far more sharply.
    mutating func absorb(_ results: [SearchResult], turnID: UUID) -> [Int] {
        var numbers: [Int] = []
        var nextNumber = (sources.map(\.number).max() ?? 0) + 1

        for result in results {
            if let index = sources.firstIndex(where: { $0.id == result.id }) {
                if result.score > sources[index].result.score {
                    sources[index].result.score = result.score
                }
                numbers.append(sources[index].number)
            } else {
                sources.append(AskSource(
                    number: nextNumber,
                    result: CodableSearchResult(result),
                    firstSeenTurn: turnID
                ))
                numbers.append(nextNumber)
                nextNumber += 1
            }
        }

        if sources.count > Self.maxSources {
            // Cited snippets are kept unconditionally — evicting one turns a
            // citation in an existing answer into a dead link. Everything else
            // competes on score for the remaining slots, this turn's own
            // results included: sparing them would make the cap
            // unenforceable whenever a single turn returned more than it.
            let cited = Set(turns.flatMap(\.citedNumbers))
            let protected = sources.filter { cited.contains($0.number) }
            let survivors = sources
                .filter { !cited.contains($0.number) }
                .sorted { $0.result.score > $1.result.score }
                .prefix(max(0, Self.maxSources - protected.count))
            let keep = Set(protected.map(\.number)).union(survivors.map(\.number))
            sources.removeAll { !keep.contains($0.number) }
            numbers = numbers.filter { keep.contains($0) }
        }

        return numbers
    }

    /// First line of the opening question, clipped at a word boundary. Titling
    /// from the question is instant and predictable; an AI-generated title
    /// would cost a round trip on the very turn the user is waiting on.
    static func title(fromFirstQuestion question: String) -> String {
        let flat = question
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return "New conversation" }
        guard flat.count > 52 else { return flat }
        let clipped = flat.prefix(52)
        if let space = clipped.lastIndex(of: " ") {
            return clipped[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return clipped + "…"
    }
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
