import Foundation
import SwiftData

enum NoteCategory: String, Codable, CaseIterable, Sendable {
    case general = "General"
    case technical = "Technical"
    case fit = "Fit"
}

enum NoteSentiment: String, Codable, CaseIterable, Sendable {
    case neutral = "Neutral"
    case wow = "Wow"
    case redFlag = "Red Flag"
}

@Model
final class InterviewNote {
    var id: UUID
    var text: String
    var categoryRawValue: String
    var sentimentRawValue: String
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

    var sentiment: NoteSentiment {
        get { NoteSentiment(rawValue: sentimentRawValue) ?? .neutral }
        set { sentimentRawValue = newValue.rawValue }
    }

    init(text: String, category: NoteCategory = .general, sentiment: NoteSentiment = .neutral, sortOrder: Int = 0) {
        self.id = UUID()
        self.text = text
        self.categoryRawValue = category.rawValue
        self.sentimentRawValue = sentiment.rawValue
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.subNotes = []
    }
}
