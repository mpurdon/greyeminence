import Foundation

struct ClaudeAPIClient: AIClient, Sendable {
    private let apiKey: String
    private let model: String

    var modelIdentifier: String { "anthropic:\(model)" }

    init(apiKey: String, model: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey
        self.model = model
    }

    func sendMessage(
        system: String,
        userContent: String,
        maxTokens: Int = 4096
    ) async throws -> String {
        let body = RequestBody(
            model: model,
            max_tokens: maxTokens,
            system: system,
            messages: [Message(role: "user", content: userContent)]
        )

        let request = try buildRequest(body: body)

        // Log outgoing payload
        if let jsonData = request.httpBody,
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

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)

        guard let textBlock = apiResponse.content.first(where: { $0.type == "text" }) else {
            throw ClaudeAPIError.noTextContent
        }

        // Log response payload
        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            LogManager.send("API response", category: .ai, detail: prettyString)
        }

        return textBlock.text
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
        request.timeoutInterval = 30

        return request
    }

    // MARK: - Request Types

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    // MARK: - Response Types

    private struct APIResponse: Decodable {
        let content: [ContentBlock]
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String
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
    case noTextContent

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
        case .noTextContent:
            "No text content in API response"
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
