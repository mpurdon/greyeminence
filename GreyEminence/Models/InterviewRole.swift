import Foundation
import SwiftData

@Model
final class InterviewRole {
    var id: UUID
    var customTitle: String?
    var createdAt: Date

    var department: Department?
    var team: Team?
    var level: RoleLevel?

    @Relationship(deleteRule: .cascade, inverse: \Rubric.role)
    var rubrics: [Rubric]

    init(level: RoleLevel? = nil, department: Department? = nil, team: Team? = nil, customTitle: String? = nil) {
        self.id = UUID()
        self.level = level
        self.department = department
        self.team = team
        self.customTitle = customTitle
        self.createdAt = .now
        self.rubrics = []
    }

    var displayTitle: String {
        customTitle ?? level?.name ?? "Unknown"
    }

    var fullDescription: String {
        var parts: [String] = []
        if let dept = department { parts.append(dept.name) }
        if let t = team { parts.append(t.name) }
        parts.append(displayTitle)
        return parts.joined(separator: " — ")
    }
}
