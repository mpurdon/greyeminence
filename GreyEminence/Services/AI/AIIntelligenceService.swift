import Foundation

// MARK: - Lightweight Sendable Snapshot Types

struct SegmentSnapshot: Sendable, Codable {
    let speaker: Speaker
    let text: String
    let formattedTimestamp: String
    let isFinal: Bool
    /// Seconds elapsed since the recording started. Used by interview phase
    /// scoping to bound analysis to a phase's time window.
    var startTime: TimeInterval = 0
}

struct AnalysisResult: Sendable {
    let title: String?
    let summary: String          // JSON-encoded [SummarySection], or legacy "- bullet" string
    let actionItems: [ParsedActionItem]
    let followUps: [String]
    let topics: [String]
    /// Raw text returned by the model, kept alongside the parsed result so callers
    /// can persist it for debugging / replay. Present whenever parsing succeeded.
    let rawResponse: String
    /// Whether the meeting refined a software feature. Final pass only; nil
    /// from live passes and whenever the model left it out.
    var refinement: RefinementSignal? = nil
}

/// The final analysis's judgement of whether a meeting refined features —
/// what puts it on the Refinements list, once per feature.
struct RefinementSignal: Sendable, Equatable {
    /// At most this many features per meeting; past that the model is
    /// listing topics, not refinements.
    static let maxFeatures = 4

    let likelihood: Double
    /// Most time spent first. Empty when nothing was refined.
    let features: [String]

    init(likelihood: Double, features: [String]) {
        self.likelihood = min(max(likelihood, 0), 1)
        var seen = Set<String>()
        self.features = features
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "null" }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(Self.maxFeatures)
            .map { $0 }
    }

    /// Tolerant of the shapes a model actually returns: a number or numeric
    /// string for the likelihood. Anything without a readable likelihood is
    /// no signal at all.
    static func parse(_ value: Any?) -> RefinementSignal? {
        guard let object = value as? [String: Any] else { return nil }
        let likelihood: Double
        switch object["likelihood"] {
        case let number as NSNumber: likelihood = number.doubleValue
        case let string as String:
            guard let parsed = Double(string.trimmingCharacters(in: .whitespaces)) else { return nil }
            likelihood = parsed
        default: return nil
        }
        let features = (object["features"] as? [Any])?.compactMap { $0 as? String } ?? []
        return RefinementSignal(likelihood: likelihood, features: features)
    }
}

struct ParsedActionItem: Sendable {
    let text: String
    let assignee: String?
    /// Verbatim transcript snippet used to anchor the item to a source segment.
    let sourceQuote: String?
}

/// Who's in the meeting, from the tool user's perspective. Grounds the
/// action-item ownership rules: the tool serves one user, so items another
/// attendee owns are excluded — except in a 1:1, where the other person's
/// commitments are promises to the user.
struct MeetingRoster: Sendable {
    let myName: String?
    let otherAttendees: [String]

    var isOneOnOne: Bool { otherAttendees.count == 1 }

    /// Snapshot from a meeting's attendee list, with "me" resolved via the
    /// My Profile contact. Taken fresh at each analysis pass because the
    /// attendee list can change mid-recording (calendar link/unlink).
    @MainActor
    static func snapshot(for meeting: Meeting) -> MeetingRoster {
        let myID = Meeting.storedMyContactID
        // Present attendees only: an invitee who never joined must not be
        // handed action items or offered to the model as someone who spoke.
        let present = meeting.presentAttendees
        return MeetingRoster(
            myName: present.first { $0.id == myID }?.name,
            otherAttendees: present.filter { $0.id != myID }.map(\.name)
        )
    }
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
    /// Called with the meeting's accumulated topics at final-analysis time;
    /// returns formatted transcript snippets from other meetings (or nil) used
    /// to ground blind-spot follow-up questions.
    typealias RelatedContextProvider = @Sendable ([String]) async -> String?

    private let client: any AIClient
    private let prepContext: MeetingPrepContext?
    private let meetingID: UUID?
    private let suppressedActionItems: [String]
    private let suppressedFollowUps: [String]
    private let relatedContextProvider: RelatedContextProvider?
    private var previousSummary: String = ""
    private var previousActionItems: [ParsedActionItem] = []
    private var previousFollowUps: [String] = []
    private var previousTopics: [String] = []
    private var lastAnalyzedSegmentCount: Int = 0

    init(
        client: any AIClient,
        prepContext: MeetingPrepContext? = nil,
        meetingID: UUID? = nil,
        suppressedActionItems: [String] = [],
        suppressedFollowUps: [String] = [],
        relatedContextProvider: RelatedContextProvider? = nil
    ) {
        self.client = client
        self.prepContext = prepContext
        self.meetingID = meetingID
        self.suppressedActionItems = suppressedActionItems
        self.suppressedFollowUps = suppressedFollowUps
        self.relatedContextProvider = relatedContextProvider
    }

    private func effectiveSystemPrompt(roster: MeetingRoster?) -> String {
        AIPromptTemplates.systemPromptWithContext(prep: prepContext, roster: roster)
    }

    /// `screenObservations` is a pre-rendered block of screen-share
    /// observations (new-since-last-pass for rolling calls) — appended after
    /// the rendered template so user prompt overrides keep working untouched.
    func analyze(segments: [SegmentSnapshot], roster: MeetingRoster? = nil, screenObservations: String? = nil) async throws -> AnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count > lastAnalyzedSegmentCount else {
            return nil
        }

        let newSegments = Array(nonEmpty.dropFirst(lastAnalyzedSegmentCount))
        guard !newSegments.isEmpty else { return nil }

        let transcript: String
        var userPrompt: String

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
                newTranscript: transcript,
                suppressedActionItems: suppressedActionItems,
                suppressedFollowUps: suppressedFollowUps
            )
        }
        userPrompt += AIPromptTemplates.screenObservationBlock(screenObservations)

        LogManager.send("AI analysis starting (\(nonEmpty.count) segments)", category: .ai, meetingID: meetingID)
        let capturedMeetingID = meetingID
        let purpose: AIUsagePurpose = previousSummary.isEmpty ? .transcriptInitial : .transcriptRolling
        let systemPrompt = effectiveSystemPrompt(roster: roster)
        let response = try await AIUsageContext.attribute(purpose, meetingID: capturedMeetingID) {
            try await AIRetry.run(label: "analyze", meetingID: capturedMeetingID) { [client, systemPrompt, userPrompt] in
                try await withTimeout(seconds: 90) {
                    try await client.sendMessage(
                        system: systemPrompt,
                        userContent: userPrompt
                    )
                }
            }
        }
        LogManager.send("AI raw response (\(response.count) chars): \(response.prefix(500))", category: .ai, meetingID: meetingID)

        let parsed = enforceActionItemOwnership(on: try parseResponse(response, raw: response), roster: roster, segments: nonEmpty)
        let result = applyResultPreservingPrevious(parsed)
        previousSummary = result.summary
        previousActionItems = result.actionItems
        previousFollowUps = result.followUps
        previousTopics = result.topics
        lastAnalyzedSegmentCount = nonEmpty.count
        LogManager.send("AI analysis complete", category: .ai, meetingID: meetingID)
        return result
    }

    /// Guard against a structurally-valid response that ships an empty
    /// summary array overwriting non-empty accumulated state. Claude
    /// occasionally returns `{"summary": []}` for short delta passes; we'd
    /// rather keep the prior pass's summary than wipe the user's screen.
    private func applyResultPreservingPrevious(_ parsed: AnalysisResult) -> AnalysisResult {
        let isEmptySummary = parsed.summary.isEmpty || parsed.summary == "[]"
        guard isEmptySummary, !previousSummary.isEmpty else { return parsed }
        LogManager.send("AI returned empty summary — keeping previous accumulated state", category: .ai, level: .warning, meetingID: meetingID)
        return AnalysisResult(
            title: parsed.title,
            summary: previousSummary,
            actionItems: parsed.actionItems.isEmpty ? previousActionItems : parsed.actionItems,
            followUps: parsed.followUps.isEmpty ? previousFollowUps : parsed.followUps,
            topics: parsed.topics.isEmpty ? previousTopics : parsed.topics,
            rawResponse: parsed.rawResponse,
            refinement: parsed.refinement
        )
    }

    /// `screenObservations` is the full session-grouped observation block for
    /// the meeting (see `ScreenObservationFormatter.finalBlock`).
    func performFinalAnalysis(segments: [SegmentSnapshot], roster: MeetingRoster? = nil, screenObservations: String? = nil) async throws -> AnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return nil }

        // Single final pass with the full transcript. If we have prior accumulated context,
        // use the cleanup prompt; otherwise fall back to initial analysis.
        guard !previousSummary.isEmpty else {
            return try await analyze(segments: segments, roster: roster, screenObservations: screenObservations)
        }

        // Related discussions from other meetings, retrieved with the topics
        // accumulated during rolling analysis. Grounds blind-spot follow-ups;
        // nil (store empty, provider unavailable) degrades to prompt-only.
        var relatedContext: String? = nil
        if let relatedContextProvider {
            relatedContext = await relatedContextProvider(previousTopics)
            if let relatedContext {
                LogManager.send("Related-meeting context attached (\(relatedContext.count) chars)", category: .ai, meetingID: meetingID)
            }
        }

        // Final cleanup pass: send full transcript + all accumulated insights
        let fullTranscript = AIPromptTemplates.formatSegments(nonEmpty)
        var userPrompt = AIPromptTemplates.finalCleanupPrompt(
            fullTranscript: fullTranscript,
            currentSummary: previousSummary,
            currentActionItems: previousActionItems,
            currentFollowUps: previousFollowUps,
            currentTopics: previousTopics,
            suppressedActionItems: suppressedActionItems,
            suppressedFollowUps: suppressedFollowUps,
            relatedContext: relatedContext
        )
        userPrompt += AIPromptTemplates.screenObservationBlock(screenObservations)

        LogManager.send("AI final cleanup starting (\(nonEmpty.count) segments)", category: .ai, meetingID: meetingID)
        let capturedMeetingID = meetingID
        let systemPrompt = effectiveSystemPrompt(roster: roster)
        let response = try await AIUsageContext.attribute(.transcriptFinal, meetingID: capturedMeetingID) {
            try await AIRetry.run(label: "finalCleanup", meetingID: capturedMeetingID) { [client, systemPrompt, userPrompt] in
                try await withTimeout(seconds: 90) {
                    try await client.sendMessage(
                        system: systemPrompt,
                        userContent: userPrompt
                    )
                }
            }
        }
        LogManager.send("AI final cleanup raw response (\(response.count) chars): \(response.prefix(500))", category: .ai, meetingID: meetingID)

        let parsed = enforceActionItemOwnership(on: try parseResponse(response, raw: response), roster: roster, segments: nonEmpty)
        let result = applyResultPreservingPrevious(parsed)
        LogManager.send("AI final cleanup complete", category: .ai, meetingID: meetingID)
        return result
    }

    // MARK: - Action-item ownership

    /// Belt-and-braces enforcement of the prompt's ownership rules: drop items
    /// another attendee owns unless the meeting is a 1:1. The prompt is the
    /// primary mechanism; this catches the model ignoring it.
    private func enforceActionItemOwnership(
        on result: AnalysisResult,
        roster: MeetingRoster?,
        segments: [SegmentSnapshot]
    ) -> AnalysisResult {
        let effective = Self.rosterForFiltering(roster, segments: segments)
        let kept = result.actionItems.filter { Self.keepsActionItem(assignee: $0.assignee, roster: effective) }
        let dropped = result.actionItems.count - kept.count
        guard dropped > 0 else { return result }
        LogManager.send("Dropped \(dropped) action item(s) owned by other attendees", category: .ai, meetingID: meetingID)
        return AnalysisResult(
            title: result.title,
            summary: result.summary,
            actionItems: kept,
            followUps: result.followUps,
            topics: result.topics,
            rawResponse: result.rawResponse,
            refinement: result.refinement
        )
    }

    /// The roster used for filtering. When no attendee roster is available
    /// (no calendar link), fall back to the distinct non-"Me" speakers in the
    /// transcript so the 1:1 exception still works from diarization alone.
    nonisolated static func rosterForFiltering(_ roster: MeetingRoster?, segments: [SegmentSnapshot]) -> MeetingRoster {
        if let roster, !roster.otherAttendees.isEmpty { return roster }
        let others = Set(segments.map(\.speaker.displayName)).subtracting(["Me"])
        return MeetingRoster(myName: roster?.myName, otherAttendees: Array(others))
    }

    /// Whether an action item survives the ownership filter. Unowned items and
    /// the user's own items always stay; diarization placeholders count as
    /// unclear ownership (they could be anyone); anything clearly owned by
    /// another person stays only in a 1:1.
    nonisolated static func keepsActionItem(assignee: String?, roster: MeetingRoster) -> Bool {
        guard let raw = assignee?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return true }
        if raw == "me" || raw == "null" || raw == "unknown" { return true }
        if raw.hasPrefix("speaker ") { return true }
        if let my = roster.myName?.lowercased(), !my.isEmpty,
           my.contains(raw) || raw.contains(my) { return true }
        return roster.isOneOnOne
    }

    // MARK: - Private

    private func parseResponse(_ response: String, raw: String) throws -> AnalysisResult {
        let json: [String: Any]
        do {
            json = try AIResponseDecoder.objectFrom(response)
        } catch {
            LogManager.send(
                "AI parse failed (\(error.localizedDescription)) — raw response: "
                    + AIResponseDecoder.failureExcerpt(response),
                category: .ai,
                level: .error,
                meetingID: meetingID
            )
            throw error
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
                    let sourceQuote = item["source_quote"] as? String
                    actionItems.append(ParsedActionItem(text: text, assignee: assignee, sourceQuote: sourceQuote))
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
            topics: topics,
            rawResponse: raw,
            refinement: RefinementSignal.parse(json["refinement"])
        )
    }
}

enum AIParseError: LocalizedError {
    case invalidJSON(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let reason):
            "AI response was not valid JSON (\(reason))"
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

/// A transport timeout for calls that generate for minutes. A non-streaming
/// response sends nothing until generation finishes, so the client's idle
/// timeout caps generation time; a caller expecting long output sets this
/// around the call and the clients use it in place of their default.
enum AIRequestTimeout {
    @TaskLocal static var seconds: TimeInterval?
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
