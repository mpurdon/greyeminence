import Foundation
import SwiftData

@Model
final class RubricSection {
    var id: UUID
    var title: String
    var sectionDescription: String
    var sortOrder: Int
    var weight: Double
    var createdAt: Date

    var rubric: Rubric?

    @Relationship(deleteRule: .cascade, inverse: \RubricCriterion.section)
    var criteria: [RubricCriterion]

    @Relationship(deleteRule: .cascade, inverse: \RubricBonusSignal.section)
    var bonusSignals: [RubricBonusSignal]

    init(title: String, description: String, sortOrder: Int = 0, weight: Double = 1.0) {
        self.id = UUID()
        self.title = title
        self.sectionDescription = description
        self.sortOrder = sortOrder
        self.weight = weight
        self.createdAt = .now
        self.criteria = []
        self.bonusSignals = []
    }
}
