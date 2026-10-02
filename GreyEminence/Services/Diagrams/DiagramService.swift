import Foundation

/// Draws one detected diagram from a meeting's transcript.
struct DiagramService: Sendable {
    /// Bump on any change to the default prompts.
    static let promptVersion = "diagrams.v3"
    static let maxTokens = 8192
    static let timeoutSeconds = 180

    enum ServiceError: LocalizedError {
        case emptyTranscript
        case unreadableResponse

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: "This meeting has no transcript to draw from."
            case .unreadableResponse: "The model's diagram couldn't be read. Try building it again."
            }
        }
    }

    /// What the prompt needs, snapshotted from the meeting on the main actor.
    struct Input: Sendable {
        let meetingTitle: String
        let date: Date
        let participants: [String]
        let screenContext: String?
        let transcript: String
        let kind: DiagramKind
        let title: String

        var fingerprint: String { MeetingPromptContext.fingerprint(of: transcript) }
    }

    let client: any AIClient

    @MainActor
    static func input(for meeting: Meeting, signal: DiagramSignal) -> Input {
        Input(
            meetingTitle: meeting.title,
            date: meeting.date,
            participants: MeetingPromptContext.participants(roster: MeetingRoster.snapshot(for: meeting)),
            screenContext: ScreenObservationFormatter.finalBlock(for: meeting),
            transcript: MeetingPromptContext.transcript(for: meeting),
            kind: signal.kind,
            title: signal.title
        )
    }

    /// What the meeting has to draw, looked for again from its transcript.
    /// `input`'s kind and title are unused.
    func detect(_ input: Input, meetingID: UUID) async throws -> [DiagramSignal] {
        guard !input.transcript.isEmpty else { throw ServiceError.emptyTranscript }
        let prompt = AIPromptTemplates.diagramDetectPrompt(values: [
            "meetingTitle": input.meetingTitle,
            "meetingDate": TimelineDiagram.string(from: input.date),
            "participants": input.participants.isEmpty ? "Not recorded" : input.participants.joined(separator: ", "),
            "transcript": input.transcript,
        ])
        let response = try await AILongRequest.send(
            client, system: AIPromptTemplates.diagramClassifySystemPrompt, prompt: prompt,
            maxTokens: 1024, timeoutSeconds: Self.timeoutSeconds, purpose: .diagramDetection, label: "diagramDetect", meetingID: meetingID
        )
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let signals = DiagramSignal.parseList(object["diagrams"]) else { throw ServiceError.unreadableResponse }
        LogManager.send("Diagrams detected again: \(signals.map { "\($0.kind.rawValue) \"\($0.title)\" \($0.likelihood)" }.joined(separator: ", "))",
                        category: .ai, meetingID: meetingID)
        return signals
    }

    func generate(_ input: Input, meetingID: UUID) async throws -> StoredDiagram {
        guard !input.transcript.isEmpty else { throw ServiceError.emptyTranscript }
        let response = try await AILongRequest.send(
            client, system: AIPromptTemplates.diagramSystemPrompt, prompt: Self.userPrompt(for: input),
            maxTokens: Self.maxTokens, timeoutSeconds: Self.timeoutSeconds, purpose: .diagrams, label: "diagram", meetingID: meetingID
        )

        var stored = StoredDiagram(
            kind: input.kind,
            generatedAt: .now,
            modelIdentifier: client.modelIdentifier,
            promptVersion: Self.promptVersion,
            transcriptFingerprint: input.fingerprint
        )
        switch input.kind {
        case .flow: stored.flow = Self.parseFlow(response: response).map { $0.tidied() }.flatMap { $0.nodes.isEmpty ? nil : $0 }
        case .timeline: stored.timeline = Self.parseTimeline(response: response).flatMap { $0.items.isEmpty ? nil : $0 }
        }
        guard stored.flow != nil || stored.timeline != nil else {
            LogManager.send(
                "Diagram unreadable — raw response: " + AIResponseDecoder.failureExcerpt(response),
                category: .ai, level: .error, meetingID: meetingID
            )
            throw ServiceError.unreadableResponse
        }
        LogManager.send("Diagram drawn: \(input.kind.rawValue) \"\(input.title)\"", category: .ai, meetingID: meetingID)
        return stored
    }

    // MARK: - Pure helpers (unit-tested)

    static func userPrompt(for input: Input) -> String {
        let day = TimelineDiagram.string(from: input.date)
        let weekday = input.date.formatted(.dateTime.weekday(.wide))
        let common: [String: String] = [
            "meetingTitle": input.meetingTitle,
            "meetingDate": day,
            "meetingWeekday": weekday,
            "participants": input.participants.isEmpty ? "Not recorded" : input.participants.joined(separator: ", "),
            "diagramTitle": input.title,
            "screenContext": MeetingPromptContext.screenContextBlock(input.screenContext),
            "transcript": input.transcript,
        ]
        switch input.kind {
        case .flow: return AIPromptTemplates.diagramFlowPrompt(values: common)
        case .timeline: return AIPromptTemplates.diagramTimelinePrompt(values: common)
        }
    }

    static func parseFlow(response: String) -> FlowDiagram? {
        decode(FlowDiagram.self, from: response)
    }

    static func parseTimeline(response: String) -> TimelineDiagram? {
        decode(TimelineDiagram.self, from: response)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: String) -> T? {
        guard let object = try? AIResponseDecoder.objectFrom(response),
              let data = try? JSONSerialization.data(withJSONObject: stringifyingIDs(object)) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }

    /// Models write IDs as numbers as often as strings ("id": 3). Where an
    /// ID can appear — a node's or item's id, an edge's ends, an item's
    /// dependencies — a number reads as its string.
    static func stringifyingIDs(_ object: [String: Any]) -> [String: Any] {
        func string(_ value: Any?) -> Any? {
            (value as? NSNumber)?.stringValue ?? value
        }
        func fix(_ list: Any?, keys: [String], listKeys: [String] = []) -> Any? {
            guard let entries = list as? [[String: Any]] else { return list }
            return entries.map { entry in
                var entry = entry
                for key in keys { entry[key] = string(entry[key]) }
                for key in listKeys {
                    if let values = entry[key] as? [Any] { entry[key] = values.map { string($0) ?? $0 } }
                }
                return entry
            }
        }
        var out = object
        out["nodes"] = fix(object["nodes"], keys: ["id"])
        out["edges"] = fix(object["edges"], keys: ["from", "to"])
        out["items"] = fix(object["items"], keys: ["id"], listKeys: ["depends_on"])
        return out
    }
}

// MARK: - Mermaid

/// Diagrams as Mermaid text, for pasting into Jira, Confluence or GitHub,
/// which draw it.
enum DiagramMermaid {
    static func flow(_ flow: FlowDiagram) -> String {
        var lines = ["flowchart TD"]
        for node in flow.nodes {
            let text = escape(node.actor.map { "\(node.label)<br/><i>\($0)</i>" } ?? node.label)
            let id = safeID(node.id)
            switch node.kind {
            case .start, .end: lines.append("    \(id)([\"\(text)\"])")
            case .decision: lines.append("    \(id){\"\(text)\"}")
            case .step: lines.append("    \(id)[\"\(text)\"]")
            }
        }
        for edge in flow.validEdges {
            let label = edge.label?.nonEmpty.map { "|\(escape($0))|" } ?? ""
            lines.append("    \(safeID(edge.from)) -->\(label) \(safeID(edge.to))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func timeline(_ timeline: TimelineDiagram) -> String {
        var lines = ["gantt", "    title \(escape(timeline.title))", "    dateFormat YYYY-MM-DD", "    section Deliverables"]
        for item in timeline.dated {
            let id = safeID(item.id)
            let name = escape(item.owner.map { "\(item.name) (\($0))" } ?? item.name)
                .replacingOccurrences(of: ":", with: " -")
            if item.isMilestone == true || item.startDate == nil, let due = item.due {
                let tags = item.isMilestone == true ? "milestone, " : ""
                lines.append("    \(name) :\(tags)\(id), \(due), \(item.isMilestone == true ? "0d" : "1d")")
            } else if let start = item.start, let due = item.due {
                lines.append("    \(name) :\(id), \(start), \(due)")
            } else if let start = item.start {
                lines.append("    \(name) :\(id), \(start), 1d")
            }
        }
        for item in timeline.undated {
            lines.append("    %% No date: \(item.name)\(item.dateText.map { " — \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "#quot;")
    }

    /// Mermaid IDs: letters, digits, underscores.
    private static func safeID(_ id: String) -> String {
        let cleaned = id.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let text = String(cleaned)
        return text.first?.isLetter == true ? text : "n" + text
    }
}
