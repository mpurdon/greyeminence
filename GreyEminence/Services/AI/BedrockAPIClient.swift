import CryptoKit
import Foundation

struct BedrockAPIClient: AIClient, Sendable {
    private let credentials: AWSCredentials
    private let region: String
    private let model: String

    init(credentials: AWSCredentials, region: String, model: String) {
        self.credentials = credentials
        self.region = region
        self.model = model
    }

    func sendMessage(
        system: String,
        userContent: String,
        maxTokens: Int = 4096
    ) async throws -> String {
        let body = RequestBody(
            anthropic_version: "bedrock-2023-05-31",
            max_tokens: maxTokens,
            system: system,
            messages: [Message(role: "user", content: userContent)]
        )

        let bodyData = try JSONEncoder().encode(body)
        let encodedModel = sigv4EncodeSegment(model)
        let path = "/model/\(encodedModel)/invoke"
        let host = "bedrock-runtime.\(region).amazonaws.com"

        guard let url = URL(string: "https://\(host)\(path)") else {
            throw BedrockAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 120

        request = try signRequest(request: request, body: bodyData, host: host, path: path)

        if let jsonObject = try? JSONSerialization.jsonObject(with: bodyData),
           let pretty = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            LogManager.send("Bedrock request payload", category: .ai, detail: prettyString)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BedrockAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BedrockAPIError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)

        guard let textBlock = apiResponse.content.first(where: { $0.type == "text" }) else {
            throw BedrockAPIError.noTextContent
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            LogManager.send("Bedrock response", category: .ai, detail: prettyString)
        }

        return textBlock.text
    }

    // MARK: - AWS Signature V4

    private func signRequest(
        request: URLRequest,
        body: Data,
        host: String,
        path: String
    ) throws -> URLRequest {
        var req = request
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: now)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: now)

        let service = "bedrock"
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        let payloadHash = sha256Hex(body)

        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        req.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        if let sessionToken = credentials.sessionToken {
            req.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // Build canonical headers (must be sorted by lowercase header name)
        var signedHeaderNames = ["content-type", "host", "x-amz-content-sha256", "x-amz-date"]
        if credentials.sessionToken != nil {
            signedHeaderNames.append("x-amz-security-token")
        }
        let signedHeaders = signedHeaderNames.joined(separator: ";")

        var canonicalHeaders = ""
        for name in signedHeaderNames {
            let value = req.value(forHTTPHeaderField: name) ?? ""
            canonicalHeaders += "\(name):\(value)\n"
        }

        let canonicalURI = sigv4EncodePath(path)

        let canonicalRequest = [
            "POST",
            canonicalURI,
            "",  // empty query string
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let canonicalRequestHash = sha256Hex(Data(canonicalRequest.utf8))

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            canonicalRequestHash,
        ].joined(separator: "\n")

        // Derive signing key
        let kDate = hmacSHA256(key: Data("AWS4\(credentials.secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))

        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        req.setValue(authorization, forHTTPHeaderField: "Authorization")

        return req
    }

    /// Encode a single path segment (model ID / ARN) — encodes : and / too
    private func sigv4EncodeSegment(_ segment: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// URI-encode full path per SigV4 canonical URI rules — preserves / as path separator, re-encodes %
    private func sigv4EncodePath(_ path: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(mac)
    }

    // MARK: - Types

    private struct RequestBody: Encodable {
        let anthropic_version: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct APIResponse: Decodable {
        let content: [ContentBlock]
    }

    private struct ContentBlock: Decodable {
        let type: String
        let text: String
    }
}

enum BedrockAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case noTextContent

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid Bedrock API URL"
        case .invalidResponse:
            "Invalid response from Bedrock"
        case .httpError(let statusCode, let body):
            "Bedrock HTTP \(statusCode): \(body)"
        case .noTextContent:
            "No text content in Bedrock response"
        }
    }
}
