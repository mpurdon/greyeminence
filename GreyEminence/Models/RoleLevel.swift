import Foundation
import SwiftData

enum RoleLevelCategory: String, Codable, CaseIterable, Sendable {
    case ic = "Individual Contributor"
    case management = "Management"
    case executive = "Executive"
}

@Model
final class RoleLevel {
    var id: UUID
    var name: String
    var categoryRawValue: String
    var sortOrder: Int
    var createdAt: Date

    var category: RoleLevelCategory {
        get { RoleLevelCategory(rawValue: categoryRawValue) ?? .ic }
        set { categoryRawValue = newValue.rawValue }
    }

    init(name: String, category: RoleLevelCategory, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.categoryRawValue = category.rawValue
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    static let defaultLevels: [(String, RoleLevelCategory, Int)] = [
        ("Engineer I", .ic, 0),
        ("Engineer II", .ic, 1),
        ("Engineer III", .ic, 2),
        ("Lead", .ic, 3),
        ("Staff Software Engineer", .ic, 4),
        ("Principal Engineer", .ic, 5),
        ("Engineering Manager I", .management, 10),
        ("Engineering Manager II", .management, 11),
        ("Engineering Manager III", .management, 12),
        ("Director", .management, 13),
        ("VP", .executive, 20),
        ("CTO", .executive, 21),
        ("CEO", .executive, 22),
        ("CFO", .executive, 23),
        ("COO", .executive, 24),
    ]
}
