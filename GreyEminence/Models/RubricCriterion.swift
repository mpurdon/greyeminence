import Foundation
import SwiftData

@Model
final class RubricCriterion {
    var id: UUID
    var signal: String
    var evaluationNotes: String?
    var sortOrder: Int

    var section: RubricSection?

    init(signal: String, sortOrder: Int = 0, evaluationNotes: String? = nil) {
        self.id = UUID()
        self.signal = signal
        self.sortOrder = sortOrder
        self.evaluationNotes = evaluationNotes
    }
}
