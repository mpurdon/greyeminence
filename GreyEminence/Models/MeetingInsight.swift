import Foundation
import SwiftData

@Model
final class MeetingInsight {
    var id: UUID
    var summary: String
    var followUpQuestions: [String]
    var topics: [String]
    var createdAt: Date

    // MARK: - Provenance
    // All optional so existing stores migrate without loss (lightweight migration).

    /// Raw text returned by the model that produced this insight. Persisted so the
    /// user can inspect failed or surprising runs, and so the insight can be re-parsed
    /// later if the parser improves.
    var rawLLMResponse: String?

    /// Model that produced this insight, e.g. `"anthropic:claude-sonnet-4-20250514"`
    /// or `"bedrock:us-east-1:anthropic.claude-opus-4-20250514-v1:0"`.
    var modelIdentifier: String?

    /// Version of the built-in prompt that produced this insight (e.g. `"meeting.v1"`).
    /// Lets us show "this insight was produced with an older prompt, regenerate?" UX.
    var promptVersion: String?

    var meeting: Meeting?

    init(
        summary: String,
        followUpQuestions: [String] = [],
        topics: [String] = [],
        rawLLMResponse: String? = nil,
        modelIdentifier: String? = nil,
        promptVersion: String? = nil
    ) {
        self.id = UUID()
        self.summary = summary
        self.followUpQuestions = followUpQuestions
        self.topics = topics
        self.createdAt = .now
        self.rawLLMResponse = rawLLMResponse
        self.modelIdentifier = modelIdentifier
        self.promptVersion = promptVersion
    }
}
