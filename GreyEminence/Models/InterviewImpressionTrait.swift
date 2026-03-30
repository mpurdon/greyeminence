import Foundation
import SwiftData

@Model
final class InterviewImpressionTrait {
    var id: UUID
    var name: String
    var label1: String
    var label2: String
    var label3: String
    var label4: String
    var label5: String
    var sortOrder: Int
    var createdAt: Date

    init(name: String, label1: String, label2: String, label3: String, label4: String, label5: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.label1 = label1
        self.label2 = label2
        self.label3 = label3
        self.label4 = label4
        self.label5 = label5
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    var labels: [String] { [label1, label2, label3, label4, label5] }

    func label(for value: Int) -> String {
        switch value {
        case 1: label1
        case 2: label2
        case 3: label3
        case 4: label4
        case 5: label5
        default: "?"
        }
    }

    static let defaultTraits: [(String, String, String, String, String, String, Int)] = [
        ("Nervousness", "Robotic", "Calm", "Slight Nerves", "Notably Nervous", "Overwhelmed", 0),
        ("Clarity", "Vague", "Adequate", "Clear", "Very Articulate", "Over-Polished", 1),
        ("Fun to Work With", "Boring", "Neutral", "Fun", "Exceptional", "Over the Top", 2),
        ("Charisma", "Flat", "Pleasant", "Engaging", "Magnetic", "Performative", 3),
        ("Curiosity", "Incurious", "Passive", "Curious", "Deeply Curious", "Unfocused", 4),
    ]
}
