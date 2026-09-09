import Foundation

/// Repairs speech-recognition mis-hearings after a transcript exists.
///
/// The recogniser's confidence cannot find these: "suffering" for "software
/// engineering" is fluent English and scores well. What finds them is the
/// surrounding conversation, so the whole transcript goes in (input is the
/// cheap side) and only a diff comes back — line number plus the corrected
/// line — so cost scales with the number of fixes, not the meeting length.
/// Every accepted change keeps the original in `originalText`, so it is
/// visible on the row and reversible.
actor TranscriptCorrectionService {

    struct Line: Sendable {
        let index: Int
        let speaker: String
        let text: String
        let confidence: Float
        /// The user changed this line by hand; the model may read it for
        /// context but never overrides it.
        var isUserEdited: Bool = false
    }

    /// What the model should know about the meeting: the same nouns the
    /// Whisper prompt carries, so both passes pull toward the same words.
    struct Context: Sendable {
        var title: String
        var participants: [String]
        var vocabulary: [String]
        var topics: [String]

        var rendered: String {
            var lines: [String] = []
            if !title.isEmpty { lines.append("Meeting: \(title)") }
            if !participants.isEmpty { lines.append("Participants: \(participants.joined(separator: ", "))") }
            if !vocabulary.isEmpty { lines.append("Terms and names to expect: \(vocabulary.joined(separator: ", "))") }
            if !topics.isEmpty { lines.append("Topics discussed: \(topics.joined(separator: ", "))") }
            return lines.isEmpty ? "No additional context." : lines.joined(separator: "\n")
        }

        @MainActor
        static func make(for meeting: Meeting) -> Context {
            Context(
                title: meeting.title,
                participants: meeting.attendees.map(\.name),
                vocabulary: VocabularyManager().terms.map(\.text),
                topics: meeting.latestInsight?.topics ?? []
            )
        }
    }

    struct Correction: Sendable, Equatable {
        let index: Int
        let text: String
    }

    enum CorrectionError: LocalizedError {
        case unparseableResponse
        var errorDescription: String? { "The transcript-correction response could not be read" }
    }

    /// Below this the row shows a marker and the prompt flags the line.
    /// Whisper's average token probability: clean speech sits around 0.7–0.9.
    static let lowConfidenceThreshold: Float = 0.5
    /// Lines per model call. A two-hour meeting is a few calls; each call
    /// still sees a long run of context around every line.
    static let linesPerCall = 300
    /// A correction may replace at most this fraction of a line's words.
    /// Anything larger is a rewrite, which the prompt forbids and the model
    /// occasionally does anyway.
    static let maxChangedFraction = 0.5

    private let client: any AIClient

    init(client: any AIClient) {
        self.client = client
    }

    func corrections(
        for lines: [Line],
        context: Context,
        meetingID: UUID?
    ) async throws -> [Correction] {
        guard !lines.isEmpty else { return [] }
        let byIndex = Dictionary(uniqueKeysWithValues: lines.map { ($0.index, $0) })
        var accepted: [Correction] = []

        for batchStart in stride(from: 0, to: lines.count, by: Self.linesPerCall) {
            let batch = Array(lines[batchStart..<min(batchStart + Self.linesPerCall, lines.count)])
            let prompt = AIPromptTemplates.transcriptCorrectionPrompt(
                context: context.rendered,
                lines: Self.renderLines(batch)
            )
            let response = try await AIUsageContext.attribute(.transcriptCorrection, meetingID: meetingID) {
                try await AIRetry.run(label: "transcriptCorrection", meetingID: meetingID) { [client, prompt] in
                    try await withTimeout(seconds: 120) {
                        try await client.sendMessage(
                            system: AIPromptTemplates.transcriptCorrectionSystemPrompt,
                            userContent: prompt,
                            maxTokens: 8192
                        )
                    }
                }
            }
            guard let parsed = Self.parse(response: response) else {
                LogManager.send(
                    "Transcript correction parse failed — raw: \(response.prefix(400))",
                    category: .transcription,
                    level: .warning,
                    meetingID: meetingID
                )
                throw CorrectionError.unparseableResponse
            }
            for correction in parsed {
                guard let line = byIndex[correction.index],
                      Self.decision(original: line.text, corrected: correction.text, isUserEdited: line.isUserEdited) else { continue }
                accepted.append(correction)
            }
        }
        return accepted
    }

    // MARK: - Pure helpers (unit-tested)

    /// "L12 [Ann] (low confidence) the text". One-based, matching how the
    /// model is asked to answer; short so a long meeting stays cheap.
    static func renderLines(_ lines: [Line]) -> String {
        lines.map { line in
            let flag = line.confidence < lowConfidenceThreshold ? " (low confidence)" : ""
            return "L\(line.index + 1) [\(line.speaker)]\(flag) \(line.text)"
        }
        .joined(separator: "\n")
    }

    /// Accepts `{"corrections":[{"line":"L12","text":"…"}]}` wherever it sits
    /// in the response; "12" and " l12 " are tolerated. Indices come back
    /// zero-based to match `Line.index`.
    static func parse(response: String) -> [Correction]? {
        guard let json = ReportComposerService.extractJSONObject(from: response),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawResponse.self, from: data) else {
            return nil
        }
        return decoded.corrections.compactMap { raw in
            guard let ordinal = ReportComposerService.index(from: raw.line, prefix: "L"), ordinal >= 1 else { return nil }
            return Correction(index: ordinal - 1, text: raw.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private struct RawResponse: Decodable {
        struct Entry: Decodable {
            let line: String
            let text: String
        }
        let corrections: [Entry]
    }

    /// Whether a proposed replacement is a mis-hearing fix rather than a
    /// rewrite, and is allowed to land at all.
    static func decision(original: String, corrected: String, isUserEdited: Bool) -> Bool {
        guard !isUserEdited else { return false }
        let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return changedFraction(from: original, to: trimmed) <= maxChangedFraction
    }

    /// Share of the longer line's words that are not shared with the other,
    /// as a multiset. "got into suffering" → "got into software engineering"
    /// changes 2 of 4.
    static func changedFraction(from original: String, to corrected: String) -> Double {
        let before = words(original), after = words(corrected)
        let longest = max(before.count, after.count)
        guard longest > 0 else { return 0 }
        var pool = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        var shared = 0
        for word in after where (pool[word] ?? 0) > 0 {
            pool[word]! -= 1
            shared += 1
        }
        return 1 - Double(shared) / Double(longest)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    /// Write accepted corrections onto the live segments. The first
    /// correction of a line keeps its original; a later one keeps the
    /// earliest original, so "revert" always means the recogniser's text.
    /// `isEdited` is left alone: it means the user changed the line.
    @MainActor
    static func apply(_ corrections: [Correction], to segments: [TranscriptSegment]) -> Int {
        var applied = 0
        for correction in corrections {
            guard segments.indices.contains(correction.index) else { continue }
            let segment = segments[correction.index]
            guard decision(original: segment.text, corrected: correction.text, isUserEdited: segment.isEdited) else { continue }
            if segment.originalText == nil { segment.originalText = segment.text }
            segment.text = correction.text
            applied += 1
        }
        return applied
    }
}
