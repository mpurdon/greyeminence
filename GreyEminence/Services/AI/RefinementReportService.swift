import Foundation

/// What a feature-refinement meeting actually decided, as opposed to what
/// the ticket said going in. Structured so the Refinements view can lay it
/// out (labelled criteria, decision cards) and so Markdown and Jira
/// descriptions are built from it rather than asked of the model twice.
struct RefinementReportContent: Codable, Sendable, Equatable {
    /// Where a criterion or decision came from.
    enum Basis: String, Codable, Sendable, CaseIterable {
        case explicit, emergent, inferred

        /// Models write "EXPLICIT", "Emergent" and the occasional
        /// "inferred (medium)"; anything unreadable is treated as inferred,
        /// the label that promises least.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            self = Self.allCases.first { raw.hasPrefix($0.rawValue) } ?? .inferred
        }
    }

    enum Confidence: String, Codable, Sendable, CaseIterable {
        case low, medium, high

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            self = Self.allCases.first { raw.hasPrefix($0.rawValue) } ?? .low
        }
    }

    struct Criterion: Codable, Sendable, Equatable {
        var text: String
        var basis: Basis
        var confidence: Confidence?
        var evidence: String?
        /// Moments in the transcript, "7:52" or "7:01-7:10". Older reports
        /// have none; their timestamps are read out of `evidence` instead.
        var citations: [String]?
    }

    struct Decision: Codable, Sendable, Equatable {
        var decision: String
        var category: String?
        var reason: String?
        var alternatives: String?
        var effect: String?
        var basis: Basis
        var citations: [String]?
    }

    struct RejectedApproach: Codable, Sendable, Equatable {
        var approach: String
        var reason: String?
        var citations: [String]?
    }

    struct Constraint: Codable, Sendable, Equatable {
        var text: String
        var source: String?
        var citations: [String]?
    }

    struct OpenQuestion: Codable, Sendable, Equatable {
        var question: String
        var owner: String?
        var citations: [String]?
    }

    struct Spec: Codable, Sendable, Equatable {
        var intent: String
        var acceptanceCriteria: [String]
        var decisions: [String]
        var constraints: [String]
        var openQuestions: [String]

        init(intent: String = "", acceptanceCriteria: [String] = [], decisions: [String] = [], constraints: [String] = [], openQuestions: [String] = []) {
            self.intent = intent
            self.acceptanceCriteria = acceptanceCriteria
            self.decisions = decisions
            self.constraints = constraints
            self.openQuestions = openQuestions
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            intent = (try? c.decodeIfPresent(String.self, forKey: .intent)) ?? ""
            acceptanceCriteria = c.lossyStrings(.acceptanceCriteria)
            decisions = c.lossyStrings(.decisions)
            constraints = c.lossyStrings(.constraints)
            openQuestions = c.lossyStrings(.openQuestions)
        }

        /// The spec's listed parts, titled once so the view and the
        /// Markdown can't drift apart.
        enum List: CaseIterable {
            case criteria, decisions, constraints, questions

            var title: String {
                switch self {
                case .criteria: "Acceptance Criteria"
                case .decisions: "Important Decisions"
                case .constraints: "Constraints / Non-goals"
                case .questions: "Open Questions"
                }
            }
        }

        func items(_ list: List) -> [String] {
            switch list {
            case .criteria: acceptanceCriteria
            case .decisions: decisions
            case .constraints: constraints
            case .questions: openQuestions
            }
        }
    }

    var isRefinement: Bool
    var intent: String
    var acceptanceCriteria: [Criterion]
    var decisions: [Decision]
    var rejectedApproaches: [RejectedApproach]
    var constraints: [Constraint]
    var reviewerNotes: [String]
    var openQuestions: [OpenQuestion]
    var spec: Spec

    init(
        isRefinement: Bool = true,
        intent: String,
        acceptanceCriteria: [Criterion] = [],
        decisions: [Decision] = [],
        rejectedApproaches: [RejectedApproach] = [],
        constraints: [Constraint] = [],
        reviewerNotes: [String] = [],
        openQuestions: [OpenQuestion] = [],
        spec: Spec = Spec()
    ) {
        self.isRefinement = isRefinement
        self.intent = intent
        self.acceptanceCriteria = acceptanceCriteria
        self.decisions = decisions
        self.rejectedApproaches = rejectedApproaches
        self.constraints = constraints
        self.reviewerNotes = reviewerNotes
        self.openQuestions = openQuestions
        self.spec = spec
    }

    /// Every collection is optional and element-lossy: one malformed
    /// decision should cost that decision, not the whole report.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isRefinement = (try? c.decodeIfPresent(Bool.self, forKey: .isRefinement)) ?? true
        intent = (try? c.decodeIfPresent(String.self, forKey: .intent)) ?? ""
        acceptanceCriteria = c.lossy(Criterion.self, .acceptanceCriteria)
        decisions = c.lossy(Decision.self, .decisions)
        rejectedApproaches = c.lossy(RejectedApproach.self, .rejectedApproaches)
        constraints = c.lossy(Constraint.self, .constraints)
        reviewerNotes = c.lossyStrings(.reviewerNotes)
        openQuestions = c.lossy(OpenQuestion.self, .openQuestions)
        spec = (try? c.decodeIfPresent(Spec.self, forKey: .spec)) ?? Spec()
    }

    var isEmpty: Bool {
        intent.isEmpty && acceptanceCriteria.isEmpty && decisions.isEmpty && spec.intent.isEmpty
    }
}

/// A decoded element that may have failed — lets an array keep its good
/// entries when one is malformed.
private struct LossyElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent([LossyElement<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }

    func lossyStrings(_ key: Key) -> [String] {
        lossy(String.self, key)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The Jira issue created from a report, so the view can link to it instead
/// of offering to create a duplicate.
struct JiraIssueLink: Codable, Sendable, Equatable {
    let key: String
    let url: URL
    let createdAt: Date
}

/// A meeting's reports, keyed by `RefinementReportShelf.key(for:)` of the
/// feature each covers.
struct RefinementReportShelf: Codable, Sendable, Equatable {
    /// Where a report written before meetings held several features lives.
    /// It belongs to the meeting's first feature.
    static let legacyKey = ""

    var reports: [String: RefinementReport] = [:]

    static func key(for feature: String) -> String {
        feature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The report for `feature`. The first feature also inherits a report
    /// nothing else claims — the legacy single report, or one written under
    /// a feature name a later analysis changed — so a report never silently
    /// disappears because a name moved.
    func report(for feature: String, isFirst: Bool, knownFeatures: [String] = []) -> RefinementReport? {
        if let exact = reports[Self.key(for: feature)] { return exact }
        guard isFirst else { return nil }
        if let legacy = reports[Self.legacyKey] { return legacy }
        let known = Set(knownFeatures.map(Self.key(for:)))
        return reports
            .filter { !known.contains($0.key) }
            .max { $0.value.generatedAt < $1.value.generatedAt }?
            .value
    }

    mutating func store(_ report: RefinementReport, for feature: String, isFirst: Bool) {
        reports[Self.key(for: feature)] = report
        if isFirst { reports[Self.legacyKey] = nil }
    }
}

/// A stored report: the content plus where it came from.
struct RefinementReport: Codable, Sendable, Equatable {
    var content: RefinementReportContent
    let generatedAt: Date
    let modelIdentifier: String
    let promptVersion: String
    /// Hash of the transcript the report was written from. A re-transcription
    /// or speaker fix changes it, which is how the view knows to say the
    /// report may be out of date — without throwing away a report someone
    /// paid for and may already have filed.
    let transcriptFingerprint: String
    var jiraIssue: JiraIssueLink?
    /// Where the report is in review. Nil on reports from before statuses
    /// existed — read as New, or Filed when a ticket was created.
    var reviewStatus: RefinementStatus?

    var status: RefinementStatus {
        reviewStatus ?? (jiraIssue == nil ? .new : .filed)
    }
}

/// Where a refinement is in review. A topic with no report is `.notBuilt`;
/// building one makes it New, opening it makes it Read, and creating its
/// Jira ticket makes it Filed. Follow-up, Approved and Rejected are the
/// reviewer's to set, and any status can be set by hand.
enum RefinementStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case new, followUp, read, notBuilt, approved, filed, rejected

    var id: String { rawValue }

    /// Every status but `.notBuilt`, which only the absence of a report means.
    static let settable: [RefinementStatus] = [.new, .read, .followUp, .approved, .filed, .rejected]

    var label: String {
        switch self {
        case .notBuilt: "No Report"
        case .new: "New"
        case .read: "Read"
        case .followUp: "Follow-up"
        case .approved: "Approved"
        case .filed: "Filed in Jira"
        case .rejected: "Rejected"
        }
    }

    var systemImage: String {
        switch self {
        case .notBuilt: "doc"
        case .new: "circle.fill"
        case .read: "doc.text"
        case .followUp: "flag.fill"
        case .approved: "checkmark.seal.fill"
        case .filed: "ticket.fill"
        case .rejected: "xmark.circle.fill"
        }
    }

    /// A status written by a newer version reads as Read rather than
    /// costing the whole report its decode.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RefinementStatus(rawValue: raw) ?? .read
    }
}

struct RefinementReportService: Sendable {
    /// Bump on any change to the default prompts, so a stored report records
    /// which wording produced it.
    static let promptVersion = "refinement.v4"

    /// Eight sections with per-item evidence run long on an hour-long
    /// meeting — well past the 8192 the analysis passes use.
    static let maxTokens = 16_000

    /// Generation at this length takes minutes, not seconds.
    static let timeoutSeconds = 300

    enum ServiceError: LocalizedError {
        case emptyTranscript
        case unreadableResponse

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: "This meeting has no transcript to analyze."
            case .unreadableResponse: "The model's report couldn't be read. Try generating it again."
            }
        }
    }

    /// Everything the prompt needs, snapshotted off the main actor's model
    /// objects so generation can run without holding them.
    struct Input: Sendable {
        let title: String
        let date: Date
        let participants: [String]
        let screenContext: String?
        let transcript: String
        /// The feature to report on, when the meeting refined several.
        var feature: String? = nil
        /// Every feature the meeting refined, for context in the focus note.
        var allFeatures: [String] = []

        var fingerprint: String { RefinementReportService.fingerprint(of: transcript) }
    }

    let client: any AIClient

    @MainActor
    static func input(for meeting: Meeting, feature: String? = nil) -> Input {
        Input(
            title: meeting.title,
            date: meeting.date,
            participants: participants(roster: MeetingRoster.snapshot(for: meeting)),
            screenContext: ScreenObservationFormatter.finalBlock(for: meeting),
            transcript: transcript(for: meeting),
            feature: feature,
            allFeatures: meeting.refinementFeatures
        )
    }

    @MainActor
    static func transcript(for meeting: Meeting) -> String {
        AIPromptTemplates.formatSegments(TranscriptFile.from(meeting: meeting).segments)
    }

    func generate(_ input: Input, meetingID: UUID) async throws -> RefinementReport {
        guard !input.transcript.isEmpty else { throw ServiceError.emptyTranscript }

        let system = AIPromptTemplates.refinementSystemPrompt
        let prompt = Self.userPrompt(for: input)
        let response = try await AIUsageContext.attribute(.refinementReport, meetingID: meetingID) {
            try await AIRetry.run(label: "refinementReport", meetingID: meetingID) { [client, system, prompt] in
                try await withTimeout(seconds: Self.timeoutSeconds) {
                    try await AIRequestTimeout.$seconds.withValue(TimeInterval(Self.timeoutSeconds)) {
                        try await client.sendMessage(system: system, userContent: prompt, maxTokens: Self.maxTokens)
                    }
                }
            }
        }

        guard let content = Self.parse(response: response), !content.isEmpty else {
            LogManager.send(
                "Refinement report unreadable — raw response: " + AIResponseDecoder.failureExcerpt(response),
                category: .ai,
                level: .error,
                meetingID: meetingID
            )
            throw ServiceError.unreadableResponse
        }

        LogManager.send(
            "Refinement report generated (\(content.acceptanceCriteria.count) criteria, \(content.decisions.count) decisions, \(client.modelIdentifier))",
            category: .ai,
            meetingID: meetingID
        )
        return RefinementReport(
            content: content,
            generatedAt: .now,
            modelIdentifier: client.modelIdentifier,
            promptVersion: Self.promptVersion,
            transcriptFingerprint: input.fingerprint
        )
    }

    // MARK: - Pure helpers (unit-tested)

    static func userPrompt(for input: Input) -> String {
        AIPromptTemplates.refinementReportPrompt(
            meetingTitle: input.title,
            meetingDate: input.date.formatted(date: .long, time: .shortened),
            participants: input.participants.isEmpty ? "Not recorded" : input.participants.joined(separator: ", "),
            screenContext: screenContextBlock(input.screenContext),
            focus: focusBlock(feature: input.feature, allFeatures: input.allFeatures),
            transcript: input.transcript
        )
    }

    /// Narrows the report to one feature when the meeting refined several.
    /// Empty for a single-feature meeting, whose report covers the meeting.
    static func focusBlock(feature: String?, allFeatures: [String]) -> String {
        guard let feature, allFeatures.count > 1 else { return "" }
        let others = allFeatures.filter { RefinementReportShelf.key(for: $0) != RefinementReportShelf.key(for: feature) }
        return """

            FOCUS
            This meeting refined several features: \(allFeatures.joined(separator: "; ")). \
            This report covers ONE of them: "\(feature)". Analyze only the \
            discussion of that feature. Leave out criteria, decisions and \
            questions that belong to \(others.joined(separator: " or ")); mention \
            them only where they constrain "\(feature)". The intent and the \
            spec are about "\(feature)" alone.

            """
    }

    /// Decodes through `AIResponseDecoder`, which already copes with fences,
    /// prose around the object and a truncated tail.
    static func parse(response: String) -> RefinementReportContent? {
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(RefinementReportContent.self, from: data)
    }

    /// A ticket or spec shown on screen is usually the "original request" the
    /// prompt asks the model to compare against, so the screen recap goes in
    /// when there is one. Empty otherwise, leaving no orphaned heading.
    static func screenContextBlock(_ context: String?) -> String {
        guard let context = context?.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else { return "" }
        return """

            SHARED SCREEN
            What was on screen during the meeting. A ticket, spec or design \
            shown here counts as the original requirements.
            \(context)

            """
    }

    /// Roster names with "me" labelled, so the model can match the "Me"
    /// speaker label in the transcript to a person.
    static func participants(roster: MeetingRoster) -> [String] {
        var names: [String] = []
        if let me = roster.myName, !me.isEmpty { names.append("\(me) (\"Me\" in the transcript)") }
        names.append(contentsOf: roster.otherAttendees)
        return names
    }

    /// "Claude Sonnet" rather than a Bedrock inference-profile ARN, which is
    /// what the model identifier is on an org that routes through profiles.
    /// Profile ARNs hide the family, so they are matched against the
    /// trajector-settings slots — the same matching the usage ledger prices by.
    static func modelLabel(_ identifier: String, settings: TrajectorSettings? = TrajectorSettings.load()) -> String {
        switch AIPricing.family(forModelIdentifier: identifier, settings: settings) {
        case AIPricing.opus: "Claude Opus"
        case AIPricing.sonnet: "Claude Sonnet"
        case AIPricing.haiku: "Claude Haiku"
        default: identifier.contains("arn:") ? "Claude via Bedrock" : identifier
        }
    }

    /// Stable across launches (unlike `Hasher`), so a stored report can be
    /// compared against today's transcript.
    static func fingerprint(of transcript: String) -> String {
        AWSSigV4Signer.sha256Hex(Data(transcript.utf8))
    }
}

// MARK: - Markdown

/// The report as Markdown, for Copy / Save and as the starting point of a
/// Jira description. Built from the structure, so what is exported is
/// exactly what the view shows.
enum RefinementReportMarkdown {

    static func full(_ content: RefinementReportContent, title: String, date: Date) -> String {
        "# Refinement: \(title)\n\n_\(date.formatted(date: .long, time: .shortened))_\n\n" + sections(content)
    }

    /// The eight sections without the document title — for a ticket, whose
    /// summary already names the feature.
    static func sections(_ content: RefinementReportContent) -> String {
        var out: [String] = []
        out.append("## 1. Intent")
        out.append(orNone(content.intent))

        out.append("## 2. Acceptance criteria that emerged")
        out.append(list(content.acceptanceCriteria.map(criterionLine)))

        out.append("## 3. Decisions made during refinement")
        if content.decisions.isEmpty {
            out.append(none)
        } else {
            for decision in content.decisions {
                var lines = ["- **Decision:** \(decision.decision)"]
                if let category = decision.category?.nonEmpty { lines[0] += " _(\(category))_" }
                lines.append("  - **Reason/evidence:** \(decision.reason?.nonEmpty ?? "Not stated")")
                lines.append("  - **Alternatives considered:** \(decision.alternatives?.nonEmpty ?? "None discussed")")
                if let effect = decision.effect?.nonEmpty { lines.append("  - **Effect on behavior:** \(effect)") }
                lines.append("  - **Explicit or inferred:** \(decision.basis == .inferred ? "Inferred" : "Explicit")")
                out.append(lines.joined(separator: "\n"))
            }
        }

        out.append("## 4. Rejected approaches")
        out.append(list(content.rejectedApproaches.map { item in
            item.reason?.nonEmpty.map { "\(item.approach) — \($0)" } ?? item.approach
        }))

        out.append("## 5. Constraints discovered")
        out.append(list(content.constraints.map { item in
            item.source?.nonEmpty.map { "\(item.text) _(\($0))_" } ?? item.text
        }))

        out.append("## 6. Implementer- and reviewer-relevant information")
        out.append(list(content.reviewerNotes))

        out.append("## 7. Unresolved questions")
        out.append(list(content.openQuestions.map(questionLine)))

        out.append("## 8. Effective session spec")
        out.append(spec(content.spec, headingLevel: 3))

        return out.joined(separator: "\n\n") + "\n"
    }

    /// Section 8 on its own — what goes in a ticket or PR.
    static func spec(_ spec: RefinementReportContent.Spec, headingLevel: Int = 2) -> String {
        let h = String(repeating: "#", count: headingLevel)
        var out = ["\(h) Intent", orNone(spec.intent)]
        for part in RefinementReportContent.Spec.List.allCases {
            out += ["\(h) \(part.title)", list(spec.items(part))]
        }
        return out.joined(separator: "\n\n")
    }

    static func criterionLine(_ criterion: RefinementReportContent.Criterion) -> String {
        var line = "**\(criterion.basis.rawValue.uppercased())"
        if criterion.basis == .inferred, let confidence = criterion.confidence {
            line += " · \(confidence.rawValue.capitalized) confidence"
        }
        line += "** — \(criterion.text)"
        if let evidence = criterion.evidence?.nonEmpty { line += " _Evidence: \(evidence)_" }
        return line
    }

    static func questionLine(_ question: RefinementReportContent.OpenQuestion) -> String {
        question.owner?.nonEmpty.map { "\(question.question) _(owner: \($0))_" } ?? question.question
    }

    private static let none = "None identified."

    private static func orNone(_ text: String) -> String {
        text.nonEmpty ?? none
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? none : items.map { "- \($0)" }.joined(separator: "\n")
    }
}

extension String {
    /// Trimmed, or nil when nothing is left — for optional model fields that
    /// arrive as "" as often as null.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
