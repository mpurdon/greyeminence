import Foundation
import SwiftData

@Model
final class Team {
    var id: UUID
    var name: String
    var sortOrder: Int
    var createdAt: Date

    var department: Department?

    init(name: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = .now
    }
}
