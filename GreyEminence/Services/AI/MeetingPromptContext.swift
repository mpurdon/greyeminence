import Foundation

/// What a prompt about one meeting is built from — shared by refinement
/// reports and diagrams, which read the same transcript the same way.
enum MeetingPromptContext {
    @MainActor
    static func transcript(for meeting: Meeting) -> String {
        AIPromptTemplates.formatSegments(TranscriptFile.from(meeting: meeting).segments)
    }

    /// Roster names with "me" labelled, so the model can match the "Me"
    /// speaker label in the transcript to a person.
    static func participants(roster: MeetingRoster) -> [String] {
        var names: [String] = []
        if let me = roster.myName, !me.isEmpty { names.append("\(me) (\"Me\" in the transcript)") }
        names.append(contentsOf: roster.otherAttendees)
        return names
    }

    /// The shared-screen recap as a prompt block, `note` saying what it's
    /// for. Empty when there's none, leaving no orphaned heading.
    static func screenContextBlock(_ context: String?, note: String = "What was on screen during the meeting.") -> String {
        guard let context = context?.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else { return "" }
        return """

            SHARED SCREEN
            \(note)
            \(context)

            """
    }

    /// Stable across launches (unlike `Hasher`), so a stored result can be
    /// compared against today's transcript.
    static func fingerprint(of transcript: String) -> String {
        AWSSigV4Signer.sha256Hex(Data(transcript.utf8))
    }
}

/// Past meetings as a numbered list of summaries — how the backfills ask
/// about twenty meetings in one call — and their answers mapped back.
enum MeetingSummaryCatalogue {
    /// Enough to tell a design discussion from a status update, short
    /// enough that a batch stays small.
    static let summaryCharacterLimit = 1_200

    struct Entry: Sendable, Equatable {
        let title: String
        let date: Date
        let topics: [String]
        let summary: String
    }

    @MainActor
    static func entry(for meeting: Meeting) -> Entry {
        let insight = meeting.latestInsight
        return Entry(
            title: meeting.title,
            date: meeting.date,
            topics: insight?.topics ?? [],
            summary: flatten(summary: insight?.summary ?? "")
        )
    }

    /// Stored summaries are JSON sections (or a legacy bullet string);
    /// a classifier only needs the words.
    static func flatten(summary raw: String) -> String {
        let text: String
        if let sections = SummarySection.parse(raw) {
            text = sections.map { section in
                ([section.title] + section.points.map { "\($0.label): \($0.detail)" }).joined(separator: "; ")
            }.joined(separator: " | ")
        } else {
            text = raw.replacingOccurrences(of: "\n", with: " ")
        }
        guard text.count > summaryCharacterLimit else { return text }
        return String(text.prefix(summaryCharacterLimit)) + "…"
    }

    /// "M1 | Title | 2026-09-23", topics, summary — one block per meeting.
    static func catalogue(_ entries: [Entry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return entries.enumerated().map { index, entry in
            var lines = ["M\(index + 1) | \(entry.title) | \(formatter.string(from: entry.date))"]
            if !entry.topics.isEmpty { lines.append("Topics: \(entry.topics.prefix(12).joined(separator: ", "))") }
            lines.append("Summary: \(entry.summary)")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// `{"meetings":[{"id":"M3", …}]}` → batch index 2 → `item`'s reading
    /// of it. Unknown identifiers and unreadable entries are dropped; the
    /// rest of the batch still counts.
    static func parse<T>(response: String, count: Int, item: ([String: Any]) -> T?) -> [Int: T] {
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let items = object["meetings"] as? [[String: Any]] else { return [:] }
        var result: [Int: T] = [:]
        for entry in items {
            guard let id = entry["id"] as? String,
                  let index = ReportComposerService.index(from: id, prefix: "M"),
                  (1...count).contains(index),
                  let value = item(entry) else { continue }
            result[index - 1] = value
        }
        return result
    }
}

/// One AI call that can take a while: attributed in the usage ledger,
/// retried on transient failures, and given `timeoutSeconds` both as the
/// outer limit and as the transport's idle timeout — a non-streaming
/// response sends nothing until it's done.
enum AILongRequest {
    static func send(
        _ client: any AIClient,
        system: String,
        prompt: String,
        maxTokens: Int,
        timeoutSeconds: Int,
        purpose: AIUsagePurpose,
        label: String,
        meetingID: UUID? = nil
    ) async throws -> String {
        try await AIUsageContext.attribute(purpose, meetingID: meetingID) {
            try await AIRetry.run(label: label, meetingID: meetingID) { [client, system, prompt] in
                try await withTimeout(seconds: timeoutSeconds) {
                    try await AIRequestTimeout.$seconds.withValue(TimeInterval(timeoutSeconds)) {
                        try await client.sendMessage(system: system, userContent: prompt, maxTokens: maxTokens)
                    }
                }
            }
        }
    }
}

/// Everything an analysis result records beyond the insight — on the
/// meeting (title, refinement judgement) and beside it (what to draw). One
/// call so a new save site can't record one part and forget another.
@MainActor
enum MeetingAnalysisRecorder {
    static func record(_ result: AnalysisResult, on meeting: Meeting) {
        meeting.applyAnalysisFields(result)
        DiagramIndexStore.shared.record(result.diagrams, for: meeting.id)
    }
}
