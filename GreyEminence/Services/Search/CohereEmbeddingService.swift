import Foundation

/// Cohere Embed English v3, over Bedrock.
///
/// The reason to prefer it over Titan is request count. Titan's `InvokeModel`
/// takes one string — the live API rejects an array outright — so indexing
/// this library means ~34,000 round trips, which is what drew 12,379 throttle
/// responses. Cohere accepts 96 texts per call, turning the same work into
/// roughly 355 requests. Two orders of magnitude fewer chances to be throttled,
/// and far less waiting on the network.
///
/// It is also asymmetric: a stored document and a search query must be sent
/// with different `input_type` values. Getting that wrong costs recall
/// silently, which is why `EmbeddingPurpose` is threaded through the protocol
/// rather than defaulted.
final class CohereEmbeddingService: EmbeddingService, @unchecked Sendable {
    static let dimensions = 1024
    private static let modelID = "cohere.embed-english-v3"

    /// Verified against the live API: 96 succeeds.
    static let batchSize = 96

    /// v3 truncates at 512 tokens per text anyway; clamping first keeps the
    /// request small and the truncation predictable.
    static let maxInputCharacters = 2_000

    let modelIdentifier = "bedrock:\(CohereEmbeddingService.modelID):\(CohereEmbeddingService.dimensions)"

    /// Batches, not records. Each in-flight request already carries 96 texts,
    /// so a handful of concurrent batches saturates the quota.
    let maxConcurrency = 4

    let resolvedRegion: String
    let resolvedProfile: String
    private let transport: BedrockEmbeddingTransport

    /// Last batch failure, so Ask can say "credentials rejected for profile
    /// gitf" instead of "nothing matched". Lock-guarded: batches run
    /// concurrently and the class is `@unchecked Sendable`.
    private let failureLock = NSLock()
    private var _lastFailure: String?
    var lastFailureDescription: String? {
        failureLock.withLock { _lastFailure }
    }
    private func recordFailure(_ description: String?) {
        failureLock.withLock { _lastFailure = description }
    }

    init(region: String? = nil, profile: String? = nil) {
        let account = BedrockEmbeddingAccount.resolved(region: region, profile: profile)
        self.resolvedRegion = account.region
        self.resolvedProfile = account.profile
        self.transport = BedrockEmbeddingTransport(region: account.region, profile: account.profile)
    }

    var isAvailable: Bool {
        !AWSCredentialLoader.usableProfiles().isEmpty
    }

    func embed(_ text: String, as purpose: EmbeddingPurpose) async -> [Float]? {
        await embedAll([text], as: purpose).first ?? nil
    }

    /// Batched. Overrides the protocol's per-item fan-out entirely — that
    /// default exists for models that can only take one string at a time.
    func embedAll(_ texts: [String], as purpose: EmbeddingPurpose) async -> [[Float]?] {
        var results = [[Float]?](repeating: nil, count: texts.count)

        // Empty strings can't be embedded and Cohere rejects a batch
        // containing one, so they're filtered out here and left nil — while
        // every surviving text keeps its original index.
        let indexed = texts.enumerated().compactMap { index, text -> (Int, String)? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (index, String(trimmed.prefix(Self.maxInputCharacters)))
        }
        guard !indexed.isEmpty else { return results }

        let batches = stride(from: 0, to: indexed.count, by: Self.batchSize).map {
            Array(indexed[$0..<min($0 + Self.batchSize, indexed.count)])
        }

        await withTaskGroup(of: [(Int, [Float])].self) { group in
            var next = 0
            let limit = min(maxConcurrency, batches.count)
            while next < limit {
                let batch = batches[next]
                group.addTask { await self.embedBatch(batch, purpose: purpose) }
                next += 1
            }
            while let done = await group.next() {
                for (index, vector) in done { results[index] = vector }
                if next < batches.count {
                    let batch = batches[next]
                    group.addTask { await self.embedBatch(batch, purpose: purpose) }
                    next += 1
                }
            }
        }
        return results
    }

    private func embedBatch(_ batch: [(Int, String)], purpose: EmbeddingPurpose) async -> [(Int, [Float])] {
        do {
            let body = try JSONEncoder().encode(RequestBody(
                texts: batch.map(\.1),
                input_type: purpose == .query ? "search_query" : "search_document",
                truncate: "END"
            ))
            let data = try await transport.invoke(modelID: BedrockEmbeddingAccount.modelID(for: .cohere, foundation: Self.modelID), body: body)
            let vectors = try Self.decodeEmbeddings(from: data)

            // A short batch would silently pair vectors with the wrong texts.
            // Dropping the batch loses 96 records that the per-record coverage
            // check will retry; mis-pairing corrupts the index invisibly.
            guard vectors.count == batch.count else {
                LogManager.send(
                    "Cohere returned \(vectors.count) vectors for \(batch.count) texts — dropping the batch rather than mispairing",
                    category: .ai,
                    level: .warning
                )
                recordFailure("Cohere returned \(vectors.count) vectors for \(batch.count) texts")
                return []
            }
            recordFailure(nil)
            return zip(batch.map(\.0), vectors).map { ($0, $1) }
        } catch {
            let description = "profile \(resolvedProfile), \(resolvedRegion): \(error.localizedDescription)"
            LogManager.send(
                "Cohere embedding failed (\(description), \(batch.count) texts)",
                category: .ai,
                level: .warning
            )
            recordFailure(description)
            return []
        }
    }

    /// Decode tolerantly. v3 returns `embeddings: [[Float]]`; the v4-era shape
    /// nests them under a type key (`embeddings: {"float": [[Float]]}`). A
    /// model swap behind an inference profile has changed response shapes on
    /// this codebase before, so accept both rather than fail opaquely.
    static func decodeEmbeddings(from data: Data) throws -> [[Float]] {
        if let flat = try? JSONDecoder().decode(FlatResponse.self, from: data) {
            return flat.embeddings
        }
        if let typed = try? JSONDecoder().decode(TypedResponse.self, from: data) {
            return typed.embeddings.float
        }
        LogManager.send(
            "Cohere response in an unrecognised shape",
            category: .ai,
            level: .warning,
            detail: String(data: data, encoding: .utf8) ?? "<non-utf8>"
        )
        throw BedrockAPIError.invalidResponse
    }

    private struct RequestBody: Encodable {
        let texts: [String]
        let input_type: String
        let truncate: String
    }

    private struct FlatResponse: Decodable {
        let embeddings: [[Float]]
    }

    private struct TypedResponse: Decodable {
        struct Embeddings: Decodable { let float: [[Float]] }
        let embeddings: Embeddings
    }
}
