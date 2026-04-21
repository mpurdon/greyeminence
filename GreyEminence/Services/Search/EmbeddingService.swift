import Foundation
@preconcurrency import NaturalLanguage

protocol EmbeddingService: Sendable {
    var modelIdentifier: String { get }
    var isAvailable: Bool { get }
    func embed(_ text: String) async -> [Float]?
}

/// Apple's built-in sentence embedding. Offline, free, ~300-dim vectors.
/// Quality is adequate for personal meeting search but lags behind current
/// API-based models (Voyage v3, Titan v2). Good default.
final class NLEmbeddingService: EmbeddingService, @unchecked Sendable {
    let modelIdentifier = "apple-nlembedding-sentence-en"

    private let embedding: NLEmbedding?

    init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    var isAvailable: Bool { embedding != nil }

    func embed(_ text: String) async -> [Float]? {
        guard let embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let vec = embedding.vector(for: trimmed) else { return nil }
        return vec.map { Float($0) }
    }
}

/// TODO: Voyage AI embeddings.
/// - Endpoint: https://api.voyageai.com/v1/embeddings
/// - Recommended model: voyage-3 (1024 dims)
/// - API key in Keychain under "voyageAPIKey"
/// - Anthropic recommends Voyage for RAG with Claude.
final class VoyageEmbeddingService: EmbeddingService, @unchecked Sendable {
    let modelIdentifier = "voyage-3"
    var isAvailable: Bool { false }
    func embed(_ text: String) async -> [Float]? { nil }
}

/// TODO: AWS Bedrock Titan Text Embeddings V2.
/// - Model id: amazon.titan-embed-text-v2:0 (configurable 256/512/1024 dims)
/// - Reuses existing AWS SSO credentials from `AWSCredentialLoader`.
final class TitanEmbeddingService: EmbeddingService, @unchecked Sendable {
    let modelIdentifier = "amazon.titan-embed-text-v2:0"
    var isAvailable: Bool { false }
    func embed(_ text: String) async -> [Float]? { nil }
}
