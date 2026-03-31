import Foundation
import SwiftData

enum NoteCategory: String, Codable, CaseIterable, Sendable {
    case general = "General"
    case technical = "Technical"
    case fit = "Fit"
}

@Model
final class InterviewNote {
    var id: UUID
    var text: String
    var categoryRawValue: String
    var sortOrder: Int
    var createdAt: Date

    var interview: Interview?
    var parentNote: InterviewNote?

    @Relationship(deleteRule: .cascade, inverse: \InterviewNote.parentNote)
    var subNotes: [InterviewNote]

    var category: NoteCategory {
        get { NoteCategory(rawValue: categoryRawValue) ?? .general }
        set { categoryRawValue = newValue.rawValue }
    }

    init(text: String, category: NoteCategory = .general, sortOrder: Int = 0) {
        self.id = UUID()
        self.text = text
        self.categoryRawValue = category.rawValue
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.subNotes = []
    }
}
