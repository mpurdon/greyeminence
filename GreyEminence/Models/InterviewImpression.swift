import Foundation
import SwiftData

@Model
final class InterviewImpression {
    var id: UUID
    var traitName: String
    var value: Int
    var createdAt: Date

    var interview: Interview?

    init(traitName: String, value: Int = 3) {
        self.id = UUID()
        self.traitName = traitName
        self.value = min(max(value, 1), 5)
        self.createdAt = .now
    }
}
