import Foundation

/// Which rationale item a citation supports.
enum RefinementItemRef: Hashable, Sendable {
    case criterion(Int)
    case decision(Int)
    case rejected(Int)
    case constraint(Int)
    case note(Int)
    case question(Int)

    /// Stable across launches, for keying your review of the item.
    var key: String {
        switch self {
        case .criterion(let i): "criterion:\(i)"
        case .decision(let i): "decision:\(i)"
        case .rejected(let i): "rejected:\(i)"
        case .constraint(let i): "constraint:\(i)"
        case .note(let i): "note:\(i)"
        case .question(let i): "question:\(i)"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let i = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "criterion": self = .criterion(i)
        case "decision": self = .decision(i)
        case "rejected": self = .rejected(i)
        case "constraint": self = .constraint(i)
        case "note": self = .note(i)
        case "question": self = .question(i)
        default: return nil
        }
    }

    var kindLabel: String {
        switch self {
        case .criterion: "Criterion"
        case .decision: "Decision"
        case .rejected: "Rejected"
        case .constraint: "Constraint"
        case .note: "Reviewer note"
        case .question: "Open question"
        }
    }
}

/// A moment in the meeting the report points at: one timestamp, or a span.
struct RefinementCitation: Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval?

    var label: String {
        let format = ReportModelBuilder.timestampLabel
        guard let end, end > start else { return format(start) }
        return "\(format(start))–\(format(end))"
    }

    /// "7:52", "[7:52]", "1:02:07", and spans written "7:01-7:10",
    /// "[20:36]-[21:26]" or with an en dash. The transcript the model reads
    /// stamps lines as minutes:seconds, so minutes can exceed 59.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\[?(\d{1,3}:\d{2}(?::\d{2})?)\]?(?:\s*[-–—]\s*\[?(\d{1,3}:\d{2}(?::\d{2})?)\]?)?"#
    )

    static func parse(in text: String) -> [RefinementCitation] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let startRange = Range(match.range(at: 1), in: text),
                  let start = seconds(String(text[startRange])) else { return nil }
            var end: TimeInterval?
            if let endRange = Range(match.range(at: 2), in: text) {
                end = seconds(String(text[endRange]))
            }
            return RefinementCitation(start: start, end: end.flatMap { $0 > start ? $0 : nil })
        }
    }

    static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2 where parts[1] < 60: return TimeInterval(parts[0] * 60 + parts[1])
        case 3 where parts[1] < 60 && parts[2] < 60: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return nil
        }
    }
}

/// Every cited moment in a report, numbered in reading order the way Ask
/// numbers its sources, and which items point at each.
struct RefinementEvidenceIndex: Sendable {
    struct Entry: Identifiable, Sendable {
        /// The number shown on the citation chip and the evidence card.
        let id: Int
        let citation: RefinementCitation
        /// Items that cite this moment, with their short text.
        var supports: [(ref: RefinementItemRef, text: String)]
        /// The model's own evidence line for the first supporting item —
        /// the quote or paraphrase that used to sit under it in the report.
        var note: String?
    }

    private(set) var entries: [Entry] = []
    private(set) var numbersByItem: [RefinementItemRef: [Int]] = [:]
    private var numbersByCitation: [RefinementCitation: Int] = [:]
    /// Evidence text for items that have some but name no moment (a screen
    /// share, a general observation) — still shown, just without a passage.
    private(set) var uncitedNotes: [(ref: RefinementItemRef, text: String, note: String)] = []

    init(_ content: RefinementReportContent) {
        for (i, item) in content.acceptanceCriteria.enumerated() {
            add(.criterion(i), text: item.text, explicit: item.citations, evidence: item.evidence, note: item.evidence)
        }
        for (i, item) in content.decisions.enumerated() {
            add(.decision(i), text: item.decision, explicit: item.citations, evidence: item.reason, note: item.reason)
        }
        for (i, item) in content.rejectedApproaches.enumerated() {
            add(.rejected(i), text: item.approach, explicit: item.citations, evidence: item.reason, note: item.reason)
        }
        for (i, item) in content.constraints.enumerated() {
            add(.constraint(i), text: item.text, explicit: item.citations, evidence: item.source, note: item.source)
        }
        for (i, note) in content.reviewerNotes.enumerated() {
            // The note is its own text; repeating it as the evidence line adds nothing.
            add(.note(i), text: note, explicit: nil, evidence: note, note: nil)
        }
        for (i, item) in content.openQuestions.enumerated() {
            add(.question(i), text: item.question, explicit: item.citations, evidence: nil, note: nil)
        }
    }

    func numbers(for ref: RefinementItemRef) -> [Int] {
        numbersByItem[ref] ?? []
    }

    /// Numbers run 1… in `entries` order.
    func entry(_ number: Int) -> Entry? {
        entries.indices.contains(number - 1) ? entries[number - 1] : nil
    }

    /// `evidence` is scanned for timestamps; `note` is what the card shows.
    private mutating func add(
        _ ref: RefinementItemRef,
        text: String,
        explicit: [String]?,
        evidence: String?,
        note: String?
    ) {
        var citations = (explicit ?? []).flatMap(RefinementCitation.parse(in:))
        if let evidence { citations += RefinementCitation.parse(in: evidence) }
        let note = note?.nonEmpty

        var seen = Set<RefinementCitation>()
        let unique = citations.filter { seen.insert($0).inserted }
        if unique.isEmpty {
            if let note { uncitedNotes.append((ref, text, note)) }
            return
        }

        for citation in unique {
            if let number = numbersByCitation[citation] {
                entries[number - 1].supports.append((ref, text))
                if entries[number - 1].note == nil { entries[number - 1].note = note }
                numbersByItem[ref, default: []].append(number)
            } else {
                let number = entries.count + 1
                entries.append(Entry(id: number, citation: citation, supports: [(ref, text)], note: note))
                numbersByCitation[citation] = number
                numbersByItem[ref, default: []].append(number)
            }
        }
    }
}

/// Picks the transcript lines behind a citation.
enum RefinementPassage {
    struct Line: Identifiable, Sendable, Equatable {
        let id: UUID
        let startTime: TimeInterval
        let speaker: String
        let text: String
    }

    /// Lines shown for a single timestamp: the one it lands in, plus what
    /// follows within this many seconds — a quote usually runs past the
    /// line it starts on.
    static let followOnSeconds: TimeInterval = 20
    static let maxLines = 8

    /// `lines` must be sorted by start time.
    static func lines(for citation: RefinementCitation, in lines: [Line]) -> [Line] {
        guard !lines.isEmpty else { return [] }
        // The line that contains the moment: the last one starting at or
        // just after it (models round timestamps to the second). Binary
        // search, since `lines` is sorted.
        let target = citation.start + 1
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].startTime <= target { low = mid + 1 } else { high = mid }
        }
        let first = max(low - 1, 0)
        let limit = citation.end ?? (citation.start + followOnSeconds)
        var result = [lines[first]]
        var index = first + 1
        while index < lines.count, lines[index].startTime <= limit, result.count < maxLines {
            result.append(lines[index])
            index += 1
        }
        return result
    }
}

/// The index with the transcript lines behind each number, worked out once
/// per report and transcript rather than on every redraw of the panel.
struct RefinementEvidenceSources {
    let index: RefinementEvidenceIndex
    /// Sorted by start time.
    let lines: [RefinementPassage.Line]
    let passages: [Int: [RefinementPassage.Line]]
    /// The citation numbers marking each line, ascending.
    let numbersByLine: [UUID: [Int]]

    init(index: RefinementEvidenceIndex, lines: [RefinementPassage.Line]) {
        self.index = index
        self.lines = lines
        var passages: [Int: [RefinementPassage.Line]] = [:]
        var numbersByLine: [UUID: [Int]] = [:]
        for entry in index.entries {
            let passage = RefinementPassage.lines(for: entry.citation, in: lines)
            passages[entry.id] = passage
            // Entries run in number order, so each line's list stays sorted.
            for line in passage { numbersByLine[line.id, default: []].append(entry.id) }
        }
        self.passages = passages
        self.numbersByLine = numbersByLine
    }
}
