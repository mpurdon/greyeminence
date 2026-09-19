import Foundation
@preconcurrency import NaturalLanguage

protocol EmbeddingService: Sendable {
    var modelIdentifier: String { get }
    var isAvailable: Bool { get }
    /// Why the most recent `embed` returned nil, for surfaces that need to
    /// tell the user rather than log. Nil when the last call succeeded or
    /// the provider doesn't track it.
    var lastFailureDescription: String? { get }
    func embed(_ text: String, as purpose: EmbeddingPurpose) async -> [Float]?

    /// How many `embed` calls may be in flight at once. On-device embedding
    /// is CPU-bound and must be serialized; a network provider is latency-
    /// bound and a full reindex is unusable without concurrency — 34,000
    /// sequential round trips is the better part of an hour.
    var maxConcurrency: Int { get }

    /// Embed many texts, honouring `maxConcurrency`. Results are positional:
    /// index i is the vector for texts[i], or nil if that one failed.
    func embedAll(_ texts: [String], as purpose: EmbeddingPurpose) async -> [[Float]?]
}

extension EmbeddingService {
    var maxConcurrency: Int { 1 }

    /// Convenience for the common cases, so call sites read as what they are.
    func embedDocument(_ text: String) async -> [Float]? { await embed(text, as: .document) }
    var lastFailureDescription: String? { nil }

    func embedQuery(_ text: String) async -> [Float]? { await embed(text, as: .query) }

    func embedAll(_ texts: [String], as purpose: EmbeddingPurpose) async -> [[Float]?] {
        guard maxConcurrency > 1 else {
            var results: [[Float]?] = []
            results.reserveCapacity(texts.count)
            for text in texts {
                results.append(await embed(text, as: purpose))
            }
            return results
        }

        // Bounded fan-out: seed the group to the concurrency limit, then feed
        // one more in as each finishes. A group of 34,000 child tasks would
        // queue every request up front and lose the back-pressure.
        var results = [[Float]?](repeating: nil, count: texts.count)
        await withTaskGroup(of: (Int, [Float]?).self) { group in
            var next = 0
            let limit = min(maxConcurrency, texts.count)
            while next < limit {
                let index = next
                group.addTask { (index, await self.embed(texts[index], as: purpose)) }
                next += 1
            }
            while let (index, vector) = await group.next() {
                results[index] = vector
                if next < texts.count {
                    let index = next
                    group.addTask { (index, await self.embed(texts[index], as: purpose)) }
                    next += 1
                }
            }
        }
        return results
    }
}

/// Apple's built-in sentence embedding. Offline, free, ~300-dim vectors.
/// Quality is adequate for personal meeting search but lags behind current
/// API-based models (Voyage v3, Titan v2). Good default.
final class NLEmbeddingService: EmbeddingService, @unchecked Sendable {
    let modelIdentifier = "apple-nlembedding-sentence-en-chunked-v1"

    private let embedding: NLEmbedding?

    /// Process-wide serialization for `NLEmbedding.vector(for:)`.
    /// `NLEmbedding.sentenceEmbedding(for:)` returns a cached singleton
    /// shared across every `NLEmbeddingService` instance, and the
    /// framework's `vector(for:)` internally fans out via `libBNNS`'s
    /// `dispatch_apply`. Two concurrent Tasks calling it simultaneously
    /// trip Swift's exclusive-access check inside CoreNLP and abort the
    /// process. Holding this lock across each call serializes at the
    /// framework boundary; the work is CPU-bound and short.
    private static let embeddingLock = NSLock()

    init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    var isAvailable: Bool { embedding != nil }

    /// Symmetric model: a document and a query embed identically, so the
    /// purpose is accepted and ignored rather than pretended to matter.
    func embed(_ text: String, as purpose: EmbeddingPurpose) async -> [Float]? {
        guard let embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let vec = Self.synchronizedVector(embedding: embedding, text: trimmed) else { return nil }
        return vec.map { Float($0) }
    }

    /// Sync wrapper — `NSLock.lock()` isn't callable from an async frame
    /// under Swift 6, but the body is short and CPU-bound so a static
    /// helper is the simpler fix than refactoring to actor isolation.
    private static func synchronizedVector(embedding: NLEmbedding, text: String) -> [Double]? {
        embeddingLock.lock()
        defer { embeddingLock.unlock() }
        return embedding.vector(for: text)
    }
}
