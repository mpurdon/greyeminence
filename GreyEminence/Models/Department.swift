import Foundation
import SwiftData

@Model
final class Department {
    var id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Team.department)
    var teams: [Team]

    init(name: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.teams = []
    }
}
