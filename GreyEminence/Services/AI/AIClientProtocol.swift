import Foundation

/// One image attachment for a vision request.
struct AIImageContent: Sendable {
    let mediaType: String
    let base64Data: String

    init(mediaType: String, base64Data: String) {
        self.mediaType = mediaType
        self.base64Data = base64Data
    }

    init(jpegData: Data) {
        self.mediaType = "image/jpeg"
        self.base64Data = jpegData.base64EncodedString()
    }
}

enum AIClientError: LocalizedError {
    case imagesNotSupported(clientName: String)

    var errorDescription: String? {
        switch self {
        case .imagesNotSupported(let clientName):
            "\(clientName) does not support image analysis"
        }
    }
}

/// One turn in a multi-turn exchange. Text only: the conversational surfaces
/// (Ask) are grounded in retrieved snippets, not images, and keeping the type
/// text-only means the flattening fallback below is always lossless.
struct AIChatMessage: Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let text: String

    init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

protocol AIClient: Sendable {
    /// Stable identifier for the model this client is bound to. Persisted with AI
    /// output as provenance so re-runs can be compared against older output.
    var modelIdentifier: String { get }

    /// Whether the vision overload below actually sends images. Callers that
    /// depend on vision (screen-frame analysis) check this up front and
    /// degrade instead of throwing mid-meeting.
    var supportsImages: Bool { get }

    func sendMessage(system: String, userContent: String, maxTokens: Int) async throws -> String

    /// Vision variant: `images` are placed before the text content, per API
    /// guidance. Default implementation throws `imagesNotSupported`.
    func sendMessage(system: String, userContent: String, images: [AIImageContent], maxTokens: Int) async throws -> String

    /// Multi-turn variant. `messages` must alternate starting with `.user` and
    /// end with a `.user` turn — the Anthropic API rejects anything else, and
    /// callers building a chat naturally satisfy it. The default implementation
    /// flattens the exchange into a single labelled user message so a client
    /// that only knows how to send one message still answers in context.
    func sendConversation(system: String, messages: [AIChatMessage], maxTokens: Int) async throws -> String
}

extension AIClient {
    var supportsImages: Bool { false }

    func sendMessage(system: String, userContent: String) async throws -> String {
        try await sendMessage(system: system, userContent: userContent, maxTokens: 8192)
    }

    func sendMessage(system: String, userContent: String, images: [AIImageContent], maxTokens: Int) async throws -> String {
        throw AIClientError.imagesNotSupported(clientName: modelIdentifier)
    }

    func sendConversation(system: String, messages: [AIChatMessage], maxTokens: Int) async throws -> String {
        let flattened = messages
            .map { message in
                let label = message.role == .user ? "User" : "Assistant"
                return "\(label): \(message.text)"
            }
            .joined(separator: "\n\n")
        return try await sendMessage(system: system, userContent: flattened, maxTokens: maxTokens)
    }

    func sendConversation(system: String, messages: [AIChatMessage]) async throws -> String {
        try await sendConversation(system: system, messages: messages, maxTokens: 8192)
    }
}

/// The Anthropic messages-API content block, shared by the direct API client
/// and Bedrock (which speaks the same JSON). Encodes as either
/// `{"type":"text","text":...}` or
/// `{"type":"image","source":{"type":"base64","media_type":...,"data":...}}`.
enum AIMessageContentBlock: Encodable {
    case text(String)
    case image(AIImageContent)

    private enum CodingKeys: String, CodingKey {
        case type, text, source
    }

    private struct ImageSource: Encodable {
        let type = "base64"
        let media_type: String
        let data: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let image):
            try container.encode("image", forKey: .type)
            try container.encode(
                ImageSource(media_type: image.mediaType, data: image.base64Data),
                forKey: .source
            )
        }
    }

    /// Standard block order for a vision message: images first, prompt last.
    static func blocks(images: [AIImageContent], text: String) -> [AIMessageContentBlock] {
        images.map { .image($0) } + [.text(text)]
    }
}

/// Extended-thinking configuration sent with every request.
///
/// We always disable it. The analysis prompts ask for a fixed JSON schema, not
/// open-ended reasoning, and adaptive thinking is ON BY DEFAULT on Claude 5-era
/// models — which share `max_tokens` between thinking and the answer. On a long
/// transcript Sonnet 5 spent the entire 8192-token budget thinking and returned
/// a response with no text block at all (`stop_reason: "max_tokens"`), so
/// analysis failed outright. Disabling is deterministic; capping effort only
/// reduces thinking rather than eliminating it.
///
/// Revisit if a model is adopted where thinking measurably improves the
/// extraction — and raise `maxTokens` well above the answer size if so.
struct ThinkingConfig: Encodable {
    let type: String

    static let disabled = ThinkingConfig(type: "disabled")
}

/// System prompt as a content-block array so the last block can carry a
/// prompt-cache breakpoint. The system prompt is the only part of a request
/// that repeats verbatim across a meeting's rolling passes (the user turn
/// carries the growing summary and new transcript), and the 45-second cadence
/// keeps the 5-minute cache entry warm. Cache reads bill at 10% of input.
/// Bedrock rejects top-level automatic caching, so the marker is explicit.
struct SystemPromptBlock: Encodable {
    let type = "text"
    let text: String
    let cache_control: CacheControl?

    struct CacheControl: Encodable {
        let type: String
        static let ephemeral = CacheControl(type: "ephemeral")
    }

    /// One block holding the whole prompt, marked as the cache breakpoint.
    /// Prompts shorter than the model's cacheable minimum (1,024 tokens on
    /// Sonnet 5, 4,096 on Haiku 4.5) are silently sent uncached — no error.
    static func cached(_ text: String) -> [SystemPromptBlock] {
        [SystemPromptBlock(text: text, cache_control: .ephemeral)]
    }
}
