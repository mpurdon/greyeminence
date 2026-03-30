import Foundation
import SwiftData
import SwiftUI

@Model
final class Candidate {
    var id: UUID
    var name: String
    var email: String?
    var notes: String?
    var isArchived: Bool
    var createdAt: Date

    var role: InterviewRole?

    @Relationship(deleteRule: .nullify, inverse: \Interview.candidate)
    var interviews: [Interview]

    init(name: String, email: String? = nil) {
        self.id = UUID()
        self.name = name
        self.email = email
        self.isArchived = false
        self.createdAt = .now
        self.interviews = []
    }

    var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var avatarColor: Color {
        Self.candidateColors[Self.colorIndex(for: name)]
    }

    private static let candidateColors: [Color] = [
        .cyan, .teal, .mint, .green,
        .blue, .indigo, .purple, .pink,
    ]

    private static func colorIndex(for name: String) -> Int {
        var hasher = Hasher()
        hasher.combine(name)
        return abs(hasher.finalize()) % candidateColors.count
    }
}
