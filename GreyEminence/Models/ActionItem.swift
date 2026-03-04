import Foundation
import SwiftData

@Model
final class ActionItem {
    var id: UUID
    var text: String
    var assignee: String?
    var isCompleted: Bool
    var createdAt: Date

    var meeting: Meeting?
    var assignedContact: Contact?

    init(text: String, assignee: String? = nil, isCompleted: Bool = false) {
        self.id = UUID()
        self.text = text
        self.assignee = assignee
        self.isCompleted = isCompleted
        self.createdAt = .now
    }

    var displayAssignee: String? {
        assignedContact?.name ?? assignee
    }
}
