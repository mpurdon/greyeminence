import Foundation
import SwiftData

@Model
final class Rubric {
    var id: UUID
    var name: String
    var isArchived: Bool
    var createdAt: Date

    var role: InterviewRole?

    @Relationship(deleteRule: .cascade, inverse: \RubricSection.rubric)
    var sections: [RubricSection]

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.isArchived = false
        self.createdAt = .now
        self.sections = []
    }

    func toSnapshot() -> RubricSnapshot {
        let sectionSnapshots = sections.sorted { $0.sortOrder < $1.sortOrder }.map { section in
            RubricSectionSnapshot(
                id: section.id,
                title: section.title,
                description: section.sectionDescription,
                criteria: section.criteria.sorted { $0.sortOrder < $1.sortOrder }.map(\.signal),
                bonusSignals: section.bonusSignals.sorted { $0.sortOrder < $1.sortOrder }.map { signal in
                    BonusSignalSnapshot(label: signal.label, expected: signal.expectedAnswer, value: signal.bonusValue)
                },
                weight: section.weight
            )
        }
        return RubricSnapshot(name: name, sections: sectionSnapshots)
    }
}
