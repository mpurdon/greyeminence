import Foundation
import Observation

/// The two things a meeting can be drawn as.
enum DiagramKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A sequence of events or steps — who or what does what, in order.
    case flow
    /// Deliverables and milestones placed in time.
    case timeline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flow: "Flow"
        case .timeline: "Timeline"
        }
    }

    var systemImage: String {
        switch self {
        case .flow: "flowchart"
        case .timeline: "chart.bar.xaxis"
        }
    }

    /// "timeline", "Gantt", "flowchart"… — anything not a timeline is a flow.
    init(lenient raw: String) {
        let raw = raw.lowercased()
        self = raw.hasPrefix("time") || raw.hasPrefix("gantt") ? .timeline : .flow
    }

    init(from decoder: Decoder) throws {
        self.init(lenient: try decoder.singleValueContainer().decode(String.self))
    }
}

/// The analysis's judgement that a meeting contains something to draw.
struct DiagramSignal: Codable, Sendable, Equatable, Identifiable {
    static let maxPerMeeting = 3
    /// Listed at or above this. Applied when read, not when stored, so the
    /// bar can move without re-assessing every meeting.
    static let threshold = 0.5

    let kind: DiagramKind
    let title: String
    let likelihood: Double

    /// Stable within a meeting: a re-analysis that names the same diagram
    /// the same way finds the diagram already built.
    var id: String { "\(kind.rawValue)|\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }

    init(kind: DiagramKind, title: String, likelihood: Double) {
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.likelihood = min(max(likelihood, 0), 1)
    }

    /// The `diagrams` array from an analysis response, most likely first.
    /// Nil when it's absent (a live pass, an overridden prompt) so an
    /// earlier judgement is kept; [] when the model looked and found nothing.
    static func parseList(_ value: Any?) -> [DiagramSignal]? {
        guard let items = value as? [Any] else { return nil }
        var seen = Set<String>()
        let signals = items.compactMap { item -> DiagramSignal? in
            guard let object = item as? [String: Any],
                  let rawKind = object["kind"] as? String,
                  let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            let likelihood: Double
            switch object["likelihood"] {
            case let number as NSNumber: likelihood = number.doubleValue
            case let string as String: likelihood = Double(string) ?? 0
            default: likelihood = threshold
            }
            let signal = DiagramSignal(kind: DiagramKind(lenient: rawKind), title: title, likelihood: likelihood)
            return seen.insert(signal.id).inserted ? signal : nil
        }
        return Array(signals.sorted { $0.likelihood > $1.likelihood }.prefix(maxPerMeeting))
    }

    var isListed: Bool { likelihood >= Self.threshold }
}

// MARK: - Index

/// Which meetings have something to draw, library-wide. A sidecar, like
/// the topic catalog: detection needs no schema change, and an older build
/// on the same data loses nothing.
struct DiagramIndex: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var signals: [DiagramSignal]
    }

    /// Keyed by meeting UUID string. An entry with no signals is a meeting
    /// assessed and found to have nothing — so the backfill skips it.
    var meetings: [String: Entry] = [:]
}

@Observable
@MainActor
final class DiagramIndexStore {
    static let shared = DiagramIndexStore()

    private(set) var index: DiagramIndex
    private(set) var revision = 0

    private init() {
        index = StorageManager.shared.loadDiagramIndex()
    }

    /// What's listed for a meeting: signals at or above the threshold.
    func signals(for meetingID: UUID) -> [DiagramSignal] {
        index.meetings[meetingID.uuidString]?.signals.filter(\.isListed) ?? []
    }

    func isAssessed(_ meetingID: UUID) -> Bool {
        index.meetings[meetingID.uuidString] != nil
    }

    /// Record an assessment. Nil — the analysis didn't say — leaves the
    /// previous one alone.
    func record(_ signals: [DiagramSignal]?, for meetingID: UUID) {
        guard let signals else { return }
        record([(meetingID, signals)])
    }

    func record(_ assessments: [(UUID, [DiagramSignal])]) {
        mutate { index in
            for (meetingID, signals) in assessments {
                index.meetings[meetingID.uuidString] = .init(signals: signals)
            }
        }
    }

    /// Stop listing a detected diagram.
    func dismiss(_ signal: DiagramSignal, for meetingID: UUID) {
        mutate { $0.meetings[meetingID.uuidString]?.signals.removeAll { $0.id == signal.id } }
    }

    /// Add a diagram by hand — a meeting the detection missed.
    func add(_ kind: DiagramKind, title: String, for meetingID: UUID) {
        let signal = DiagramSignal(kind: kind, title: title, likelihood: 1)
        mutate { index in
            var entry = index.meetings[meetingID.uuidString] ?? .init(signals: [])
            guard !entry.signals.contains(where: { $0.id == signal.id }) else { return }
            entry.signals.append(signal)
            index.meetings[meetingID.uuidString] = entry
        }
    }

    private func mutate(_ change: (inout DiagramIndex) -> Void) {
        var next = index
        change(&next)
        guard next != index else { return }
        index = next
        StorageManager.shared.saveDiagramIndex(next)
        revision += 1
    }
}

// MARK: - Diagrams

/// A sequence of events: steps and decisions joined by arrows.
struct FlowDiagram: Codable, Sendable, Equatable {
    enum NodeKind: String, Codable, Sendable, CaseIterable {
        case start, step, decision, end

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
            self = NodeKind(rawValue: raw) ?? (raw.contains("decision") || raw.contains("branch") ? .decision : .step)
        }
    }

    struct Node: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var label: String
        var kind: NodeKind
        /// Who or what does it: a person, a team, a system.
        var actor: String?
        var note: String?
        var citations: [String]?
    }

    struct Edge: Codable, Sendable, Equatable, Identifiable {
        var from: String
        var to: String
        /// A decision's branch ("yes", "on failure").
        var label: String?
        var citations: [String]?

        var id: String { "\(from)→\(to)|\(label ?? "")" }
    }

    var title: String
    var summary: String?
    var nodes: [Node]
    var edges: [Edge]
    /// What the meeting left unclear about the flow.
    var openQuestions: [String]?

    /// Edges whose ends both exist — a model sometimes names a node it
    /// never defined.
    var validEdges: [Edge] {
        let ids = Set(nodes.map(\.id))
        return edges.filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }
    }

    /// The flow with what a model gets wrong despite the prompt put right:
    /// nothing leaves an end node, a "decision" with one way out is a step,
    /// and steps no longer reachable from the start — usually the meeting's
    /// discussion tacked on after an end — are dropped.
    func tidied() -> FlowDiagram {
        var flow = self
        let kinds = Dictionary(nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        flow.edges = validEdges.filter { kinds[$0.from] != .end }

        let starts = flow.nodes.filter { $0.kind == .start }.map(\.id)
        if !starts.isEmpty {
            var reached = Set(starts)
            var frontier = starts
            while let id = frontier.popLast() {
                for edge in flow.edges where edge.from == id && reached.insert(edge.to).inserted {
                    frontier.append(edge.to)
                }
            }
            flow.nodes.removeAll { !reached.contains($0.id) }
            flow.edges.removeAll { !reached.contains($0.from) }
        }

        let exits = Dictionary(grouping: flow.edges, by: \.from).mapValues(\.count)
        for index in flow.nodes.indices where flow.nodes[index].kind == .decision && exits[flow.nodes[index].id, default: 0] < 2 {
            flow.nodes[index].kind = .step
        }
        return flow
    }
}

/// Deliverables and milestones placed in time.
struct TimelineDiagram: Codable, Sendable, Equatable {
    struct Item: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var owner: String?
        /// "YYYY-MM-DD". Nil when only a due date was given.
        var start: String?
        /// "YYYY-MM-DD". Nil when the meeting gave no usable date.
        var due: String?
        /// The date as it was said: "end of next sprint", "before the pilot".
        var dateText: String?
        var isMilestone: Bool?
        var dependsOn: [String]?
        /// "exact" when a date was stated, "estimated" when resolved from a
        /// relative phrase.
        var confidence: String?
        var citations: [String]?
        /// Set aside by you: kept, so it can come back, but not shown.
        var isIgnored: Bool?

        var startDate: Date? { start.flatMap(TimelineDiagram.date(from:)) }
        var dueDate: Date? { due.flatMap(TimelineDiagram.date(from:)) }
        var isEstimated: Bool { confidence?.lowercased().hasPrefix("est") ?? false }
    }

    var title: String
    var summary: String?
    var items: [Item]
    var notes: [String]?

    var shown: [Item] { items.filter { $0.isIgnored != true } }
    var dated: [Item] { shown.filter { $0.dueDate != nil || $0.startDate != nil } }
    var undated: [Item] { shown.filter { $0.dueDate == nil && $0.startDate == nil } }
    var ignored: [Item] { items.filter { $0.isIgnored == true } }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from text: String) -> Date? {
        dayFormatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func string(from date: Date) -> String {
        dayFormatter.string(from: date)
    }
}

/// One drawn diagram, with where it came from.
struct StoredDiagram: Codable, Sendable, Equatable {
    let kind: DiagramKind
    var flow: FlowDiagram?
    var timeline: TimelineDiagram?
    let generatedAt: Date
    let modelIdentifier: String
    let promptVersion: String
    let transcriptFingerprint: String
    /// Set when you've changed it by hand; regenerating asks first.
    var editedAt: Date?
    /// `DiagramTopic.diagramID`, written into the file so the ID alone
    /// finds the diagram — and its meeting, from the file name.
    var diagramID: String?

    var title: String? { flow?.title ?? timeline?.title }
    var summary: String? { (flow?.summary ?? timeline?.summary)?.nonEmpty }
    /// A flow's open questions, a timeline's risks and assumptions.
    var notes: [String] { flow?.openQuestions ?? timeline?.notes ?? [] }
}

/// A meeting's diagrams, keyed by `DiagramSignal.id`.
struct DiagramShelf: Codable, Sendable, Equatable {
    var diagrams: [String: StoredDiagram] = [:]
}
