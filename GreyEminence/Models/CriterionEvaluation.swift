import Foundation
import SwiftData

@Model
final class CriterionEvaluation {
    var id: UUID
    var signal: String
    var statusRawValue: String
    var confidence: Double
    var summary: String?
    var sortOrder: Int
    var createdAt: Date

    var sectionScore: InterviewSectionScore?

    @Relationship(deleteRule: .cascade, inverse: \CriterionEvidence.criterionEvaluation)
    var evidenceItems: [CriterionEvidence]

    var status: CriterionStatus {
        get { CriterionStatus(rawValue: statusRawValue) ?? .notYetDiscussed }
        set { statusRawValue = newValue.rawValue }
    }

    init(signal: String, status: CriterionStatus, confidence: Double, summary: String?, sortOrder: Int) {
        self.id = UUID()
        self.signal = signal
        self.statusRawValue = status.rawValue
        self.confidence = confidence
        self.summary = summary
        self.sortOrder = sortOrder
        self.createdAt = .now
        self.evidenceItems = []
    }
}

@Model
final class CriterionEvidence {
    var id: UUID
    var quote: String
    var timestamp: String
    var strengthRawValue: String
    var createdAt: Date

    var criterionEvaluation: CriterionEvaluation?

    var strength: EvidenceStrength {
        get { EvidenceStrength(rawValue: strengthRawValue) ?? .moderate }
        set { strengthRawValue = newValue.rawValue }
    }

    init(quote: String, timestamp: String, strength: EvidenceStrength = .moderate) {
        self.id = UUID()
        self.quote = quote
        self.timestamp = timestamp
        self.strengthRawValue = strength.rawValue
        self.createdAt = .now
    }
}
