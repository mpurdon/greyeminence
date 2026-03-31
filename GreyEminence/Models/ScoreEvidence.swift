import Foundation
import SwiftData

enum EvidenceStrength: String, Codable, Sendable {
    case weak
    case moderate
    case strong
}

@Model
final class ScoreEvidence {
    var id: UUID
    var quote: String
    var timestamp: String
    var criterionSignal: String?
    var strengthRawValue: String
    var createdAt: Date

    var sectionScore: InterviewSectionScore?

    var strength: EvidenceStrength {
        get { EvidenceStrength(rawValue: strengthRawValue) ?? .moderate }
        set { strengthRawValue = newValue.rawValue }
    }

    init(quote: String, timestamp: String, criterionSignal: String? = nil, strength: EvidenceStrength = .moderate) {
        self.id = UUID()
        self.quote = quote
        self.timestamp = timestamp
        self.criterionSignal = criterionSignal
        self.strengthRawValue = strength.rawValue
        self.createdAt = .now
    }
}
