import Foundation

// MARK: - Lightweight Sendable Snapshot Types

struct SegmentSnapshot: Sendable {
    let speaker: Speaker
    let text: String
    let formattedTimestamp: String
    let isFinal: Bool
}

struct AnalysisResult: Sendable {
    let summary: String
    let actionItems: [ParsedActionItem]
    let followUps: [String]
    let topics: [String]
}

struct ParsedActionItem: Sendable {
    let text: String
    let assignee: String?
}

// MARK: - Intelligence Service

actor AIIntelligenceService {
    private let client: ClaudeAPIClient
    private var previousSummary: String = ""
    private var previousActionItems: [ParsedActionItem] = []
    private var previousFollowUps: [String] = []
    private var previousTopics: [String] = []
    private var lastAnalyzedSegmentCount: Int = 0

    init(client: ClaudeAPIClient) {
        self.client = client
    }

    func analyze(segments: [SegmentSnapshot]) async throws -> AnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count > lastAnalyzedSegmentCount else {
            return nil
        }

        let newSegments = Array(nonEmpty.dropFirst(lastAnalyzedSegmentCount))
        guard !newSegments.isEmpty else { return nil }

        let transcript: String
        let userPrompt: String

        if previousSummary.isEmpty {
            transcript = AIPromptTemplates.formatSegments(Array(nonEmpty))
            userPrompt = AIPromptTemplates.initialAnalysisPrompt(transcript: transcript)
        } else {
            transcript = AIPromptTemplates.formatSegments(newSegments)
            userPrompt = AIPromptTemplates.rollingAnalysisPrompt(
                previousSummary: previousSummary,
                previousActionItems: previousActionItems,
                previousFollowUps: previousFollowUps,
                previousTopics: previousTopics,
                newTranscript: transcript
            )
        }

        LogManager.send("AI analysis starting (\(nonEmpty.count) segments)", category: .ai)
        let response = try await client.sendMessage(
            system: AIPromptTemplates.systemPrompt,
            userContent: userPrompt
        )

        let result = try parseResponse(response)
        previousSummary = result.summary
        previousActionItems = result.actionItems
        previousFollowUps = result.followUps
        previousTopics = result.topics
        lastAnalyzedSegmentCount = nonEmpty.count
        LogManager.send("AI analysis complete", category: .ai)
        return result
    }

    func performFinalAnalysis(segments: [SegmentSnapshot]) async throws -> AnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return nil }

        // If there are unanalyzed segments, run a rolling analysis first
        if nonEmpty.count > lastAnalyzedSegmentCount {
            _ = try await analyze(segments: segments)
        }

        // Nothing accumulated — skip cleanup
        guard !previousSummary.isEmpty else { return nil }

        // Final cleanup pass: send full transcript + all accumulated insights
        let fullTranscript = AIPromptTemplates.formatSegments(nonEmpty)
        let userPrompt = AIPromptTemplates.finalCleanupPrompt(
            fullTranscript: fullTranscript,
            currentSummary: previousSummary,
            currentActionItems: previousActionItems,
            currentFollowUps: previousFollowUps,
            currentTopics: previousTopics
        )

        LogManager.send("AI final cleanup starting (\(nonEmpty.count) segments)", category: .ai)
        let response = try await client.sendMessage(
            system: AIPromptTemplates.systemPrompt,
            userContent: userPrompt
        )

        let result = try parseResponse(response)
        LogManager.send("AI final cleanup complete", category: .ai)
        return result
    }

    // MARK: - Private

    private func parseResponse(_ raw: String) throws -> AnalysisResult {
        // Strip markdown fences if present
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIParseError.invalidJSON
        }

        let summary = json["summary"] as? String ?? ""

        var actionItems: [ParsedActionItem] = []
        if let items = json["action_items"] as? [[String: Any]] {
            for item in items {
                if let text = item["text"] as? String {
                    let assignee = item["assignee"] as? String
                    actionItems.append(ParsedActionItem(text: text, assignee: assignee))
                }
            }
        }

        let followUps = json["follow_ups"] as? [String] ?? []
        let topics = json["topics"] as? [String] ?? []

        return AnalysisResult(
            summary: summary,
            actionItems: actionItems,
            followUps: followUps,
            topics: topics
        )
    }
}

enum AIParseError: LocalizedError {
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Failed to parse AI response as JSON"
        }
    }
}
