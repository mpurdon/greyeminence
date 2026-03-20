import Foundation
import SwiftData
import SwiftUI

@Model
final class Contact {
    var id: UUID
    var name: String
    var email: String?
    var createdAt: Date

    // Future: Microsoft Teams / external sync
    var externalID: String?
    var externalSource: String?

    // Speaker label aliases for auto-linking
    var speakerAliases: [String] = []

    @Relationship(inverse: \Meeting.attendees)
    var meetings: [Meeting] = []

    @Relationship(inverse: \ActionItem.assignedContact)
    var assignedActionItems: [ActionItem] = []

    init(name: String, email: String? = nil) {
        self.id = UUID()
        self.name = name
        self.email = email
        self.createdAt = .now
    }

    var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    var avatarColor: Color {
        Self.contactColors[Self.colorIndex(for: name)]
    }

    private static let contactColors: [Color] = [
        .blue, .green, .orange, .purple,
        .pink, .teal, .indigo, .mint,
    ]

    private static func colorIndex(for name: String) -> Int {
        var hasher = Hasher()
        hasher.combine(name)
        let hash = abs(hasher.finalize())
        return hash % contactColors.count
    }
}
