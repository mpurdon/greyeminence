import Foundation

struct ClaudeAPIClient: AIClient, Sendable {
    private let apiKey: String
    private let model: String

    var modelIdentifier: String { "anthropic:\(model)" }

    init(apiKey: String, model: String = AIModelCatalog.defaultMainModel) {
        self.apiKey = apiKey
        self.model = model
    }

    var supportsImages: Bool { true }

    func sendMessage(
        system: String,
        userContent: String,
        maxTokens: Int = 8192
    ) async throws -> String {
        try await send(system: system, blocks: [.text(userContent)], maxTokens: maxTokens)
    }

    func sendMessage(
        system: String,
        userContent: String,
        images: [AIImageContent],
        maxTokens: Int
    ) async throws -> String {
        try await send(
            system: system,
            blocks: AIMessageContentBlock.blocks(images: images, text: userContent),
            maxTokens: maxTokens
        )
    }

    func sendConversation(
        system: String,
        messages: [AIChatMessage],
        maxTokens: Int
    ) async throws -> String {
        try await send(
            system: system,
            messages: messages.map { Message(role: $0.role.rawValue, content: [.text($0.text)]) },
            maxTokens: maxTokens
        )
    }

    private func send(
        system: String,
        blocks: [AIMessageContentBlock],
        maxTokens: Int
    ) async throws -> String {
        try await send(
            system: system,
            messages: [Message(role: "user", content: blocks)],
            maxTokens: maxTokens
        )
    }

    private func send(
        system: String,
        messages: [Message],
        maxTokens: Int
    ) async throws -> String {
        let blocks = messages.flatMap(\.content)
        let body = RequestBody(
            model: model,
            max_tokens: maxTokens,
            system: SystemPromptBlock.cached(system),
            messages: messages,
            thinking: .disabled
        )

        let request = try buildRequest(body: body)

        // Log outgoing payload. Requests with images skip the pretty JSON
        // dump — megabytes of base64 would swamp the activity log — and log
        // a size summary plus the text prompt instead.
        let imageCount = blocks.count(where: { if case .image = $0 { true } else { false } })
        if imageCount > 0 {
            let bytes = request.httpBody?.count ?? 0
            let text = blocks.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n")
            LogManager.send(
                "API request payload (\(imageCount) images, \(bytes / 1024) KB)",
                category: .ai,
                detail: text
            )
        } else if let jsonData = request.httpBody,
           let jsonObject = try? JSONSerialization.jsonObject(with: jsonData),
           let pretty = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            LogManager.send("API request payload", category: .ai, detail: prettyString)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw ClaudeAPIError.apiError(
                    statusCode: httpResponse.statusCode,
                    message: apiError.error.message
                )
            }
            throw ClaudeAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        // Log the raw response *before* decoding. A model-side shape change
        // (e.g. a new content-block type) otherwise fails with an opaque
        // Decodable error and no payload in the log to diagnose it from.
        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            LogManager.send("API response", category: .ai, detail: prettyString)
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)

        guard let text = apiResponse.content.first(where: { $0.type == "text" })?.text else {
            throw ClaudeAPIError.noTextContent(stopReason: apiResponse.stop_reason)
        }

        if let usage = AIUsage.decode(fromResponseBody: data) {
            UsageRecorder.record(modelIdentifier: modelIdentifier, usage: usage)
            LogManager.send(
                "usage: \(usage.inputTokens.formatted()) in / \(usage.outputTokens.formatted()) out, cache \(usage.cacheReadTokens.formatted()) read / \(usage.cacheWriteTokens.formatted()) written (\(model))",
                category: .ai
            )
        }

        return text
    }

    private func buildRequest(body: RequestBody) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw ClaudeAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)
        // Larger max_tokens (8192) means generation can run longer, so the
        // per-request ceiling is 60s. Still inside the outer 90s withTimeout
        // that wraps each individual sendMessage attempt.
        request.timeoutInterval = 60

        return request
    }

    // MARK: - Request Types

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: [SystemPromptBlock]
        let messages: [Message]
        let thinking: ThinkingConfig
    }

    private struct Message: Encodable {
        let role: String
        let content: [AIMessageContentBlock]
    }

    // MARK: - Response Types

    private struct APIResponse: Decodable {
        let content: [ContentBlock]
        let stop_reason: String?
    }

    /// `text` is optional because Claude 5-era models interleave non-text
    /// blocks — `thinking` (adaptive thinking is on by default on Sonnet 5),
    /// `tool_use` — ahead of the text block. A non-optional `text` makes the
    /// whole array fail to decode with an opaque "data couldn't be read
    /// because it is missing" (DecodingError.keyNotFound).
    private struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    private struct APIErrorResponse: Decodable {
        let error: APIErrorDetail
    }

    private struct APIErrorDetail: Decodable {
        let type: String
        let message: String
    }
}

enum ClaudeAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case apiError(statusCode: Int, message: String)
    case noTextContent(stopReason: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API URL"
        case .invalidResponse:
            "Invalid response from API"
        case .httpError(let statusCode):
            Self.friendlyHTTPMessage(statusCode)
        case .apiError(let statusCode, let message):
            Self.friendlyAPIMessage(statusCode: statusCode, message: message)
        case .noTextContent(let stopReason):
            // Name the usual cause rather than just the symptom: the model can
            // exhaust max_tokens before emitting any text.
            stopReason == "max_tokens"
                ? "The model hit its output limit before answering — try again, or raise max tokens"
                : "No text content in API response\(stopReason.map { " (stop reason: \($0))" } ?? "")"
        }
    }

    private static func friendlyHTTPMessage(_ statusCode: Int) -> String {
        switch statusCode {
        case 429: "API rate limit reached — try again shortly"
        case 529: "API is overloaded — try again shortly"
        case 401: "Invalid API key — check Settings"
        case 403: "API access denied — check your API key permissions"
        default: "HTTP error \(statusCode)"
        }
    }

    private static func friendlyAPIMessage(statusCode: Int, message: String) -> String {
        switch statusCode {
        case 429: "API rate limit reached — try again shortly"
        case 529: "API is overloaded — try again shortly"
        default: message
        }
    }
}
