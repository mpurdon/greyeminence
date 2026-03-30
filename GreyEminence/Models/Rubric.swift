import Foundation
import SwiftData

@Model
final class Rubric {
    var id: UUID
    var name: String
    var isArchived: Bool
    var createdAt: Date

    var role: InterviewRole?

    @Relationship(deleteRule: .cascade, inverse: \RubricSection.rubric)
    var sections: [RubricSection]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.isArchived = false
        self.createdAt = .now
        self.sections = []
    }
}
