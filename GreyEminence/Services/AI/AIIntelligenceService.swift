import Foundation

// MARK: - Lightweight Sendable Snapshot Types

struct SegmentSnapshot: Sendable, Codable {
    let speaker: Speaker
    let text: String
    let formattedTimestamp: String
    let isFinal: Bool
}

struct AnalysisResult: Sendable {
    let title: String?
    let summary: String          // JSON-encoded [SummarySection], or legacy "- bullet" string
    let actionItems: [ParsedActionItem]
    let followUps: [String]
    let topics: [String]
}

struct ParsedActionItem: Sendable {
    let text: String
    let assignee: String?
}

// MARK: - Structured Summary Types

struct SummaryPoint: Sendable, Codable {
    let label: String
    let detail: String
}

struct SummarySection: Sendable, Codable {
    let title: String
    let intro: String?
    let points: [SummaryPoint]
}

extension SummarySection {
    /// Parse a stored summary string into structured sections.
    /// Returns nil for legacy flat-string summaries (backward compat).
    static func parse(_ raw: String) -> [SummarySection]? {
        guard raw.hasPrefix("["),
              let data = raw.data(using: .utf8),
              let sections = try? JSONDecoder().decode([SummarySection].self, from: data),
              !sections.isEmpty else {
            return nil
        }
        return sections
    }
}

// MARK: - Intelligence Service

actor AIIntelligenceService {
    private let client: any AIClient
    private let prepContext: MeetingPrepContext?
    private let meetingID: UUID?
    private var previousSummary: String = ""
    private var previousActionItems: [ParsedActionItem] = []
    private var previousFollowUps: [String] = []
    private var previousTopics: [String] = []
    private var lastAnalyzedSegmentCount: Int = 0

    init(client: any AIClient, prepContext: MeetingPrepContext? = nil, meetingID: UUID? = nil) {
        self.client = client
        self.prepContext = prepContext
        self.meetingID = meetingID
    }

    private var effectiveSystemPrompt: String {
        AIPromptTemplates.systemPromptWithContext(prep: prepContext)
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

        LogManager.send("AI analysis starting (\(nonEmpty.count) segments)", category: .ai, meetingID: meetingID)
        let response = try await withTimeout(seconds: 90) {
            try await self.client.sendMessage(
                system: self.effectiveSystemPrompt,
                userContent: userPrompt
            )
        }
        LogManager.send("AI raw response (\(response.count) chars): \(response.prefix(500))", category: .ai, meetingID: meetingID)

        let result = try parseResponse(response)
        previousSummary = result.summary
        previousActionItems = result.actionItems
        previousFollowUps = result.followUps
        previousTopics = result.topics
        lastAnalyzedSegmentCount = nonEmpty.count
        LogManager.send("AI analysis complete", category: .ai, meetingID: meetingID)
        return result
    }

    func performFinalAnalysis(segments: [SegmentSnapshot]) async throws -> AnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return nil }

        // Single final pass with the full transcript. If we have prior accumulated context,
        // use the cleanup prompt; otherwise fall back to initial analysis.
        guard !previousSummary.isEmpty else {
            return try await analyze(segments: segments)
        }

        // Final cleanup pass: send full transcript + all accumulated insights
        let fullTranscript = AIPromptTemplates.formatSegments(nonEmpty)
        let userPrompt = AIPromptTemplates.finalCleanupPrompt(
            fullTranscript: fullTranscript,
            currentSummary: previousSummary,
            currentActionItems: previousActionItems,
            currentFollowUps: previousFollowUps,
            currentTopics: previousTopics
        )

        LogManager.send("AI final cleanup starting (\(nonEmpty.count) segments)", category: .ai, meetingID: meetingID)
        let response = try await withTimeout(seconds: 90) {
            try await self.client.sendMessage(
                system: self.effectiveSystemPrompt,
                userContent: userPrompt
            )
        }
        LogManager.send("AI final cleanup raw response (\(response.count) chars): \(response.prefix(500))", category: .ai, meetingID: meetingID)

        let result = try parseResponse(response)
        LogManager.send("AI final cleanup complete", category: .ai, meetingID: meetingID)
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
            LogManager.send("AI parse failed — raw response: \(cleaned.prefix(1000))", category: .ai, level: .error, meetingID: meetingID)
            throw AIParseError.invalidJSON
        }

        let title = json["title"] as? String

        // summary is now a JSON array of section objects; re-encode to string for storage.
        // Fall back to plain string for any model that returns the old format.
        let summary: String
        if let sectionsArray = json["summary"] as? [[String: Any]],
           let reEncoded = try? JSONSerialization.data(withJSONObject: sectionsArray),
           let jsonString = String(data: reEncoded, encoding: .utf8) {
            summary = jsonString
        } else {
            summary = json["summary"] as? String ?? ""
        }

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
            title: title,
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

enum AITimeoutError: LocalizedError {
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "AI request timed out after \(seconds) seconds"
        }
    }
}

/// Runs the given async throwing closure with a timeout. Throws `AITimeoutError.timedOut` if exceeded.
func withTimeout<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AITimeoutError.timedOut(seconds: seconds)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
