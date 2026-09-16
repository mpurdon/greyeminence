import Foundation
import SwiftData

@Model
final class ActionItem {
    var id: UUID
    var text: String
    var assignee: String?
    var isCompleted: Bool
    var createdAt: Date

    // Commitment tracking
    var dueDate: Date?
    var sourceSegmentID: UUID?

    /// Set when the user explicitly marks this item as "won't do". Distinct
    /// from `isCompleted` (done) — a dismissed item drops out of pending +
    /// stalled but isn't counted as accomplished. Nil for pending and
    /// completed items.
    var dismissedAt: Date?

    /// Why the AI tidy-up pass marked this item Won't Do — "Duplicate of …"
    /// or the model's reason. Nil for user dismissals. Cleared when the
    /// item is restored.
    var dismissalNote: String?

    /// AI-assigned importance from the last task tidy-up pass. Nil until a
    /// pass has looked at the item. Stored as the raw string so SwiftData
    /// predicates can filter on it.
    var priorityRaw: String?

    /// When the AI tidy-up pass last evaluated this item. The automatic pass
    /// only spends a call when there are items it has not seen yet.
    var lastTriagedAt: Date?

    var meeting: Meeting?
    var assignedContact: Contact?

    init(text: String, assignee: String? = nil, isCompleted: Bool = false) {
        self.id = UUID()
        self.text = text
        self.assignee = assignee
        self.isCompleted = isCompleted
        self.createdAt = .now
    }

    var isDismissed: Bool { dismissedAt != nil }

    var priority: ActionItemPriority? {
        get { priorityRaw.flatMap(ActionItemPriority.init(rawValue:)) }
        set { priorityRaw = newValue?.rawValue }
    }

    /// Build an action item from an AI-parsed result and resolve its source
    /// segment from the supplied transcript. The caller still owns attaching
    /// the item to a meeting — done separately because some flows defer the
    /// attachment until after analysis completes.
    convenience init(parsed: ParsedActionItem, sourceSegments: [TranscriptSegment]) {
        self.init(text: parsed.text, assignee: parsed.assignee)
        self.sourceSegmentID = sourceSegments.segmentID(matchingQuote: parsed.sourceQuote)
    }

    var displayAssignee: String? {
        assignedContact?.name ?? assignee
    }
}

extension ActionItem: Identifiable {}

/// Importance assigned by the AI tidy-up pass. Ordered so a sort by priority
/// can compare `rank` directly.
enum ActionItemPriority: String, CaseIterable, Sendable {
    case high
    case medium
    case low

    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }

    var displayName: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}
