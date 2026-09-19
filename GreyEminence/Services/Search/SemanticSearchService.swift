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
    let service: EmbeddingService
    /// Candidate records for a model identifier — the store in the app, a
    /// fixture in tests.
    private let records: (String) -> [EmbeddingRecord]

    /// Weight on the dense (vector) score in the hybrid blend. The lexical
    /// (BM25) score takes (1 - vectorWeight). 0.5 balances exact-keyword
    /// recall (BM25's strength) with paraphrase recall (vector's strength).
    /// On-device NLEmbedding is weak enough that the lexical half does most
    /// of the heavy lifting for keyword-y queries.
    var vectorWeight: Float = 0.5

    /// Added to the blended score of a record that names the person asked
    /// about. Being named is a strong, rare signal — on a real index only
    /// ~1.6% of records mention any given colleague — and it is the *only*
    /// signal when they are being quoted rather than speaking. Stripping the
    /// name from the query stops it dominating the lexical pass; this hands
    /// back a bounded share of what that removed, enough to lift a
    /// mid-ranked mention into the model's context but never enough to float
    /// an irrelevant snippet over a strong topical match.
    var mentionBoost: Float = 0.15

    init(store: EmbeddingStore, service: EmbeddingService) {
        self.service = service
        self.records = { store.allRecords(for: $0) }
    }

    init(records: @escaping (String) -> [EmbeddingRecord], service: EmbeddingService) {
        self.service = service
        self.records = records
    }

    /// Narrows the candidate set to material connected to a particular person,
    /// before any scoring happens.
    ///
    /// Connected means one of two things, and both are needed. They were in
    /// the meeting — or they are *named in the text*. Attendance alone is not
    /// enough, because people are quoted in rooms they were never in: the
    /// snippet that answers "what did Stephen say we couldn't process" is
    /// someone else relaying it in a meeting Stephen did not attend.
    struct PersonScope: Sendable {
        /// Meetings the person attended.
        let meetingIDs: Set<UUID>
        /// Lowercased names to look for in the record text — full name plus
        /// the parts, matched on word boundaries so "Gene" doesn't match
        /// "generate" and "Huh" doesn't match every hesitation in a transcript.
        let mentionNames: [String]

        /// Whether a record belongs to this scope. Exposed so the union rule —
        /// the part that a hard attendance filter got wrong — is testable
        /// without a store.
        nonisolated static func admitsForTesting(_ scope: PersonScope, meetingID: UUID, text: String) -> Bool {
            scope.meetingIDs.contains(meetingID)
                || SemanticSearchService.mentions(text, regex: scope.mentionRegex)
        }

        fileprivate var mentionRegex: NSRegularExpression? {
            let alternatives = mentionNames
                .filter { !$0.isEmpty }
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            guard !alternatives.isEmpty else { return nil }
            return try? NSRegularExpression(
                pattern: "\\b(?:\(alternatives))\\b",
                options: [.caseInsensitive]
            )
        }
    }

    /// What a search had to do without. Surfaces on the Ask turn so a
    /// credential problem reads as a credential problem, not as "nothing
    /// matched".
    enum Degradation: Equatable, Sendable {
        /// The query could not be embedded; only the keyword pass ran.
        case keywordOnly(reason: String?)
    }

    struct Outcome: Sendable {
        let results: [SearchResult]
        let degradation: Degradation?
    }

    func search(
        _ query: String,
        topK: Int = 25,
        dateRange: ClosedRange<Date>? = nil,
        kinds: Set<EmbeddingRecord.SourceKind>? = nil,
        personScope: PersonScope? = nil
    ) async -> [SearchResult] {
        await searchReporting(query, topK: topK, dateRange: dateRange, kinds: kinds, personScope: personScope).results
    }

    /// `search`, plus whether it ran at full strength.
    ///
    /// The index is hybrid — cosine over stored vectors blended with BM25
    /// over stored text — and the text half needs no network. When the
    /// query embedding fails (an expired AWS session is the usual cause) the
    /// keyword pass still runs alone: a distinctive phrase is found either
    /// way, and the user is told the ranking was keyword-only.
    func searchReporting(
        _ query: String,
        topK: Int = 25,
        dateRange: ClosedRange<Date>? = nil,
        kinds: Set<EmbeddingRecord.SourceKind>? = nil,
        personScope: PersonScope? = nil
    ) async -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Outcome(results: [], degradation: nil) }

        let queryVec = await service.embedQuery(trimmed)
        var degradation: Degradation?
        if queryVec == nil {
            let reason = service.lastFailureDescription
            degradation = .keywordOnly(reason: reason)
            LogManager.send(
                "Search: query embedding unavailable (\(reason ?? "no reason recorded")) — keyword-only pass",
                category: .general,
                level: .warning
            )
        }

        let mentionRegex = personScope?.mentionRegex
        var candidates: [(record: EmbeddingRecord, namesPerson: Bool)] = []
        for rec in records(service.modelIdentifier) {
            if let kinds, !kinds.contains(rec.sourceKind) { continue }
            if let range = dateRange, !range.contains(rec.meetingDate) { continue }
            guard personScope != nil else {
                candidates.append((rec, false))
                continue
            }
            // Named in the text, or in a meeting they attended — either can
            // carry the answer. The mention is evaluated for every candidate,
            // not just the ones attendance misses, because it also feeds the
            // ranking boost below.
            let namesPerson = Self.mentions(rec.text, regex: mentionRegex)
            let attended = personScope?.meetingIDs.contains(rec.meetingID) ?? false
            guard namesPerson || attended else { continue }
            candidates.append((rec, namesPerson))
        }
        let records = candidates.map(\.record)
        guard !records.isEmpty else { return Outcome(results: [], degradation: degradation) }

        // Dense (vector) pass — cosine over each candidate. Skipped entirely
        // when there is no query vector; the blend below then runs on the
        // keyword axis alone.
        var vecScores: [Float] = Array(repeating: 0, count: records.count)
        if let queryVec {
            for (i, rec) in records.enumerated() {
                let recVec = rec.vectorArray
                guard recVec.count == queryVec.count else { continue }
                vecScores[i] = Self.cosineSimilarity(recVec, queryVec)
            }
        }

        // Lexical (BM25) pass — query-time tokenization of each candidate's
        // display text plus its meeting title (so title-word matches help).
        let queryTokens = Self.tokenize(trimmed)
        let docTokens: [[String]] = records.map { rec in
            Self.tokenize(rec.text + " " + rec.meetingTitle)
        }
        let lexScores = Self.bm25Scores(queryTokens: queryTokens, docs: docTokens)

        // Min-max normalize each score axis to [0,1] before blending so the
        // raw BM25 scale (unbounded) doesn't dominate cosine (already [-1,1]).
        let normVec = Self.minMaxNormalize(vecScores)
        let normLex = Self.minMaxNormalize(lexScores)
        let alpha: Float = queryVec == nil ? 0 : max(0, min(1, vectorWeight))

        let boost = personScope == nil ? 0 : mentionBoost
        let scored: [SearchResult] = records.enumerated().map { (i, rec) in
            let blended = alpha * normVec[i] + (1 - alpha) * normLex[i]
                + (candidates[i].namesPerson ? boost : 0)
            return SearchResult(
                id: rec.id,
                sourceKind: rec.sourceKind,
                sourceID: rec.sourceID,
                meetingID: rec.meetingID,
                meetingTitle: rec.meetingTitle,
                meetingDate: rec.meetingDate,
                text: rec.text,
                score: blended
            )
        }

        // Keyword-only: a candidate with no query term in it has no evidence
        // at all, and min-max would otherwise promote the least-irrelevant of
        // them to a full score.
        let ranked = scored
            .enumerated()
            .filter { queryVec != nil || lexScores[$0.offset] > 0 }
            .map(\.element)
        return Outcome(
            results: Array(ranked.sorted { $0.score > $1.score }.prefix(topK)),
            degradation: degradation
        )
    }

    nonisolated fileprivate static func mentions(_ text: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Cosine

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

    // MARK: - Lexical (BM25)

    private static let stopwords: Set<String> = [
        "a","an","the","and","or","but","if","then","else","of","in","on","at","to",
        "for","with","without","is","are","was","were","be","been","being","am",
        "i","me","my","mine","we","us","our","ours","you","your","yours","he","him",
        "his","she","her","hers","it","its","they","them","their","theirs","this",
        "that","these","those","do","does","did","done","doing","have","has","had",
        "having","will","would","shall","should","can","could","may","might","must",
        "so","than","because","as","about","into","over","under","up","down","out",
        "from","by","not","no","yes","very","just","also","there","here","what",
        "which","who","whom","whose","when","where","why","how","s","t","d","ll",
        "m","ve","re","got","get","go","goes","going","gone","like","really",
        "uh","um","okay","ok","yeah","yep","nope"
    ]

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                if current.count >= 2 && !stopwords.contains(current) {
                    tokens.append(current)
                }
                current = ""
            }
        }
        if !current.isEmpty, current.count >= 2, !stopwords.contains(current) {
            tokens.append(current)
        }
        return tokens
    }

    /// Classic Okapi BM25 over an in-memory corpus. k1=1.5, b=0.75 — standard
    /// defaults that work well without per-corpus tuning at this scale.
    private static func bm25Scores(queryTokens: [String], docs: [[String]]) -> [Float] {
        let n = docs.count
        guard n > 0, !queryTokens.isEmpty else { return Array(repeating: 0, count: n) }

        let k1: Float = 1.5
        let b: Float = 0.75

        let docLengths = docs.map { Float($0.count) }
        let totalLen = docLengths.reduce(0, +)
        let avgdl = totalLen > 0 ? totalLen / Float(n) : 1

        // Document frequency per unique query term.
        let querySet = Set(queryTokens)
        var df: [String: Int] = [:]
        for doc in docs {
            let docSet = Set(doc)
            for t in querySet where docSet.contains(t) {
                df[t, default: 0] += 1
            }
        }

        // BM25+ IDF, floored at 0 so common-everywhere terms don't drag scores negative.
        var idf: [String: Float] = [:]
        for t in querySet {
            let dft = Float(df[t] ?? 0)
            let value = log(((Float(n) - dft + 0.5) / (dft + 0.5)) + 1)
            idf[t] = max(0, value)
        }

        var scores: [Float] = Array(repeating: 0, count: n)
        for (i, doc) in docs.enumerated() {
            guard !doc.isEmpty else { continue }
            var tf: [String: Int] = [:]
            for t in doc where querySet.contains(t) {
                tf[t, default: 0] += 1
            }
            if tf.isEmpty { continue }
            let dl = docLengths[i]
            var s: Float = 0
            for (term, count) in tf {
                let termIdf = idf[term] ?? 0
                let f = Float(count)
                let denom = f + k1 * (1 - b + b * dl / avgdl)
                if denom > 0 {
                    s += termIdf * (f * (k1 + 1)) / denom
                }
            }
            scores[i] = s
        }
        return scores
    }

    private static func minMaxNormalize(_ values: [Float]) -> [Float] {
        guard let mn = values.min(), let mx = values.max(), mx > mn else {
            return Array(repeating: 0, count: values.count)
        }
        let range = mx - mn
        return values.map { ($0 - mn) / range }
    }
}
