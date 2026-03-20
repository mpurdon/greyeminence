import Foundation

protocol AIClient: Sendable {
    func sendMessage(system: String, userContent: String, maxTokens: Int) async throws -> String
}

extension AIClient {
    func sendMessage(system: String, userContent: String) async throws -> String {
        try await sendMessage(system: system, userContent: userContent, maxTokens: 2048)
    }
}
