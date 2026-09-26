import Foundation

/// How much an acceptance criterion or constraint matters — MoSCoW, the
/// scale refinement meetings already talk in.
enum RefinementPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case must, should, could, wont

    var id: String { rawValue }

    var label: String {
        switch self {
        case .must: "Must"
        case .should: "Should"
        case .could: "Could"
        case .wont: "Won't"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RefinementPriority(rawValue: raw) ?? .should
    }
}

/// A rationale section you can add your own items to.
enum RefinementReviewSection: String, Codable, Sendable, CaseIterable {
    case criteria, decisions, rejected, constraints, notes, questions

    /// "Add criterion", "Add question"…
    var singular: String {
        switch self {
        case .criteria: "criterion"
        case .decisions: "decision"
        case .rejected: "rejected approach"
        case .constraints: "constraint"
        case .notes: "note for the implementer"
        case .questions: "open question"
        }
    }

    /// Priority applies to what the feature must satisfy.
    var hasPriority: Bool { self == .criteria || self == .constraints }
}

/// Your review of one rationale item.
struct RefinementItemReview: Codable, Sendable, Equatable {
    var priority: RefinementPriority?
    /// Left out of the spec. The item stays visible, dimmed, so the choice
    /// can be undone.
    var isLeftOut = false
    /// Your wording, replacing the model's.
    var editedText: String?
    var note: String?
    /// Open questions: the answer. Set means resolved.
    var resolution: String?

    var isEmpty: Bool { self == RefinementItemReview() }
}

/// An item you added to a section yourself.
struct RefinementAddedItem: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    let section: RefinementReviewSection
    var text: String
    var review = RefinementItemReview()
}

/// Everything you've done to a report's rationale, and the spec generated
/// once you accepted it. Stored with the report; the model's content is
/// never rewritten, so a review can always be told from what the meeting
/// produced.
struct RefinementReview: Codable, Sendable, Equatable {
    /// Keyed by `RefinementItemRef.key`.
    var items: [String: RefinementItemReview] = [:]
    var added: [RefinementAddedItem] = []
    var intent: String?

    var acceptedAt: Date?
    /// Generated from the rationale as it was when accepted.
    var spec: RefinementReportContent.Spec?
    var specGeneratedAt: Date?
    var specModelIdentifier: String?
    var specVerifiedAt: Date?
    /// The rationale changed after the spec was generated.
    var specIsStale = false

    func item(_ ref: RefinementItemRef) -> RefinementItemReview {
        items[ref.key] ?? RefinementItemReview()
    }

    /// Whether anything of yours would be lost by regenerating the report.
    var hasWork: Bool {
        items.values.contains { !$0.isEmpty } || !added.isEmpty || intent != nil || spec != nil
    }

    // MARK: - Progress

    struct Progress: Equatable {
        var prioritized = 0
        var needingPriority = 0
        var openQuestions = 0
        var notes = 0
        var leftOut = 0
    }

    func progress(of content: RefinementReportContent) -> Progress {
        var progress = Progress()
        func count(_ review: RefinementItemReview, prioritizable: Bool, question: Bool) {
            if review.note?.nonEmpty != nil { progress.notes += 1 }
            if review.isLeftOut { progress.leftOut += 1; return }
            if prioritizable {
                if review.priority == nil { progress.needingPriority += 1 } else { progress.prioritized += 1 }
            }
            if question, review.resolution?.nonEmpty == nil { progress.openQuestions += 1 }
        }
        for i in content.acceptanceCriteria.indices { count(item(.criterion(i)), prioritizable: true, question: false) }
        for i in content.constraints.indices { count(item(.constraint(i)), prioritizable: true, question: false) }
        for i in content.decisions.indices { count(item(.decision(i)), prioritizable: false, question: false) }
        for i in content.rejectedApproaches.indices { count(item(.rejected(i)), prioritizable: false, question: false) }
        for i in content.reviewerNotes.indices { count(item(.note(i)), prioritizable: false, question: false) }
        for i in content.openQuestions.indices { count(item(.question(i)), prioritizable: false, question: true) }
        for added in added {
            count(added.review, prioritizable: added.section.hasPriority, question: added.section == .questions)
        }
        return progress
    }
}

extension RefinementReport {
    /// The spec to show, export and file: the one generated from your
    /// accepted rationale, else the first pass's draft (reports built
    /// before specs waited for review).
    var effectiveSpec: RefinementReportContent.Spec {
        review?.spec ?? content.spec
    }

    /// True when the spec on show is the first pass's, not one generated
    /// from a review.
    var specIsDraft: Bool {
        review?.spec == nil
    }
}

// MARK: - Workflow

extension RefinementReport {
    /// Change the review. Working on a New report puts it In Progress;
    /// changing an accepted rationale takes the acceptance back and marks
    /// the spec out of date — it no longer says what the rationale says.
    mutating func editReview(_ change: (inout RefinementReview) -> Void) {
        var next = review ?? RefinementReview()
        let before = next
        change(&next)
        guard next != before else { return }
        if next.acceptedAt != nil {
            next.acceptedAt = nil
            next.specVerifiedAt = nil
            if next.spec != nil { next.specIsStale = true }
        }
        review = next
        switch status {
        case .new, .accepted, .verified: reviewStatus = .inProgress
        default: break
        }
    }

    /// Accept the rationale as it stands. The spec is generated next.
    mutating func acceptRationale(at date: Date = .now) {
        var next = review ?? RefinementReview()
        next.acceptedAt = date
        next.specVerifiedAt = nil
        review = next
        if status != .filed { reviewStatus = .accepted }
    }

    mutating func storeSpec(_ spec: RefinementReportContent.Spec, modelIdentifier: String, at date: Date = .now) {
        var next = review ?? RefinementReview()
        next.spec = spec
        next.specGeneratedAt = date
        next.specModelIdentifier = modelIdentifier
        next.specIsStale = false
        next.specVerifiedAt = nil
        review = next
    }

    /// Back to working on the rationale; the spec stays, marked out of date.
    mutating func reopenRationale() {
        guard var next = review, next.acceptedAt != nil else { return }
        next.acceptedAt = nil
        next.specVerifiedAt = nil
        if next.spec != nil { next.specIsStale = true }
        review = next
        if status != .filed { reviewStatus = .inProgress }
    }

    /// You checked the generated spec and it says what was decided.
    mutating func verifySpec(at date: Date = .now) {
        guard var next = review, next.spec != nil, next.acceptedAt != nil, !next.specIsStale else { return }
        next.specVerifiedAt = date
        review = next
        if status != .filed { reviewStatus = .verified }
    }

    var isRationaleAccepted: Bool { review?.acceptedAt != nil }
}
