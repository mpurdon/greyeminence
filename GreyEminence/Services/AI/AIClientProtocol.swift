import Foundation

protocol AIClient: Sendable {
    /// Stable identifier for the model this client is bound to. Persisted with AI
    /// output as provenance so re-runs can be compared against older output.
    var modelIdentifier: String { get }

    func sendMessage(system: String, userContent: String, maxTokens: Int) async throws -> String
}

extension AIClient {
    func sendMessage(system: String, userContent: String) async throws -> String {
        try await sendMessage(system: system, userContent: userContent, maxTokens: 4096)
    }
}
