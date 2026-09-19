import Foundation

/// Amazon Titan Text Embeddings V2, over Bedrock.
///
/// Reuses the AWS credentials the app already holds, so meeting text never
/// leaves the account that already analyses it. A trained sentence encoder
/// rather than Apple's word-averaged `NLEmbedding`, which is what makes
/// paraphrase retrieval work: "couldn't process due to costs" and "there's no
/// way we can turn this on" share no vocabulary.
///
/// Titan's `InvokeModel` accepts exactly one string — verified against the
/// live API, which rejects an array with "expected type: String, found:
/// JSONArray". A full index is therefore one request per chunk. Where request
/// count matters, `CohereEmbeddingService` embeds 96 at a time.
final class TitanEmbeddingService: EmbeddingService, @unchecked Sendable {
    /// Titan v2 is Matryoshka-trained, so 256 / 512 / 1024 are all valid and
    /// larger is better. 1024 costs 4 KB per record — about 139 MB across a
    /// 34,000-record index, which is acceptable for the quality.
    static let dimensions = 1024

    private static let modelID = "amazon.titan-embed-text-v2:0"

    /// Baked into the identifier because it's part of the vector's meaning:
    /// records embedded at a different width can't be compared, and the
    /// identifier gates which records a search consults. Changing the model or
    /// the width forces a reindex rather than silently mixing shapes.
    let modelIdentifier = "bedrock:\(TitanEmbeddingService.modelID):\(TitanEmbeddingService.dimensions)"

    /// Titan v2 accepts 8,192 tokens. Transcript chunks are ~600 characters,
    /// but a meeting summary runs far longer, so clamp well inside the limit
    /// rather than let one oversized record fail a whole meeting.
    static let maxInputCharacters = 24_000

    /// A ceiling, not a target — the transport's adaptive limiter decides how
    /// much of it is used.
    let maxConcurrency = 12

    let resolvedRegion: String
    let resolvedProfile: String
    private let transport: BedrockEmbeddingTransport

    static let profileKey = BedrockEmbeddingAccount.profileKey
    static let regionKey = BedrockEmbeddingAccount.regionKey

    init(region: String? = nil, profile: String? = nil) {
        let account = BedrockEmbeddingAccount.resolved(region: region, profile: profile)
        self.resolvedRegion = account.region
        self.resolvedProfile = account.profile
        self.transport = BedrockEmbeddingTransport(region: account.region, profile: account.profile)
    }

    /// Configured, not proven — verifying would mean a network round trip on a
    /// synchronous property. Deliberately not tied to the app's AI provider:
    /// embeddings may run on a different AWS account entirely.
    var isAvailable: Bool {
        !AWSCredentialLoader.usableProfiles().isEmpty
    }

    /// Titan is symmetric — it has no document/query distinction — so the
    /// purpose is accepted and ignored rather than pretended to matter.
    func embed(_ text: String, as purpose: EmbeddingPurpose) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clamped = String(trimmed.prefix(Self.maxInputCharacters))

        do {
            let body = try JSONEncoder().encode(RequestBody(
                inputText: clamped,
                dimensions: Self.dimensions,
                normalize: true
            ))
            let response = try await transport.invoke(modelID: BedrockEmbeddingAccount.modelID(for: .titan, foundation: Self.modelID), body: body)
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: response.data)
            guard decoded.embedding.count == Self.dimensions else {
                throw BedrockAPIError.invalidResponse
            }
            if let tokens = decoded.inputTextTokenCount ?? response.inputTokens {
                await AIUsageContext.attribute(.embedding) {
                    UsageRecorder.record(
                        modelIdentifier: modelIdentifier,
                        usage: AIUsage(inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
                    )
                }
            }
            return decoded.embedding
        } catch {
            // Name the credentials, not just the error: with two accounts in
            // play, "not authorized" is meaningless without knowing which.
            LogManager.send(
                "Titan embedding failed (profile \(resolvedProfile), \(resolvedRegion)): \(error.localizedDescription)",
                category: .ai,
                level: .warning
            )
            return nil
        }
    }

    private struct RequestBody: Encodable {
        let inputText: String
        let dimensions: Int
        let normalize: Bool
    }

    private struct ResponseBody: Decodable {
        let embedding: [Float]
        let inputTextTokenCount: Int?
    }
}

/// Voyage AI embeddings — deliberately not built.
///
/// Voyage benchmarks better and its free tier would have covered this corpus
/// outright, but it means shipping meeting transcripts to a third party. The
/// Bedrock models run inside the AWS account the app already talks to, under
/// whatever agreement already covers it. Revisit only if retrieval quality
/// stalls and the data-handling question has an answer.
final class VoyageEmbeddingService: EmbeddingService, @unchecked Sendable {
    let modelIdentifier = "voyage-4"
    var isAvailable: Bool { false }
    func embed(_ text: String, as purpose: EmbeddingPurpose) async -> [Float]? { nil }
}
