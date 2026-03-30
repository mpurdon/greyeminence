import Foundation
import SwiftData

@Model
final class RubricBonusSignal {
    var id: UUID
    var label: String
    var expectedAnswer: String
    var bonusValue: Int
    var sortOrder: Int

    var section: RubricSection?

    init(label: String, expectedAnswer: String = "yes", bonusValue: Int = 1, sortOrder: Int = 0) {
        self.id = UUID()
        self.label = label
        self.expectedAnswer = expectedAnswer
        self.bonusValue = bonusValue
        self.sortOrder = sortOrder
    }
}
