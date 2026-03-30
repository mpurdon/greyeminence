import Foundation
import SwiftData
import SwiftUI

enum InterviewStatus: String, Codable, Sendable {
    case scheduled
    case recording
    case completed
    case archived
}

enum OverallRecommendation: Int, Codable, CaseIterable, Sendable {
    case strongNoHire = 1
    case noHire = 2
    case leanNoHire = 3
    case neutral = 4
    case leanHire = 5
    case hire = 6
    case strongHire = 7

    var label: String {
        switch self {
        case .strongNoHire: "Strong No Hire"
        case .noHire: "No Hire"
        case .leanNoHire: "Lean No Hire"
        case .neutral: "Neutral"
        case .leanHire: "Lean Hire"
        case .hire: "Hire"
        case .strongHire: "Strong Hire"
        }
    }

    var color: Color {
        switch self {
        case .strongNoHire: .red
        case .noHire: .red.opacity(0.7)
        case .leanNoHire: .orange
        case .neutral: .gray
        case .leanHire: .yellow
        case .hire: .green.opacity(0.8)
        case .strongHire: .green
        }
    }

    var shortLabel: String {
        switch self {
        case .strongNoHire: "SN"
        case .noHire: "N"
        case .leanNoHire: "LN"
        case .neutral: "—"
        case .leanHire: "LH"
        case .hire: "H"
        case .strongHire: "SH"
        }
    }
}

@Model
final class Interview {
    var id: UUID
    var statusRawValue: String
    var interviewerNotes: String?
    var recommendationRawValue: Int?
    var createdAt: Date

    var candidate: Candidate?
    var rubric: Rubric?

    @Relationship(deleteRule: .cascade)
    var meeting: Meeting?

    @Relationship(deleteRule: .cascade, inverse: \InterviewSectionScore.interview)
    var sectionScores: [InterviewSectionScore]

    @Relationship(deleteRule: .cascade, inverse: \InterviewImpression.interview)
    var impressions: [InterviewImpression]

    @Relationship(deleteRule: .cascade, inverse: \InterviewBookmark.interview)
    var bookmarks: [InterviewBookmark]

    @Relationship(deleteRule: .nullify)
    var interviewers: [Contact]

    var status: InterviewStatus {
        get { InterviewStatus(rawValue: statusRawValue) ?? .scheduled }
        set { statusRawValue = newValue.rawValue }
    }

    var overallRecommendation: OverallRecommendation? {
        get { recommendationRawValue.flatMap { OverallRecommendation(rawValue: $0) } }
        set { recommendationRawValue = newValue?.rawValue }
    }

    init(candidate: Candidate? = nil, rubric: Rubric? = nil) {
        self.id = UUID()
        self.statusRawValue = InterviewStatus.scheduled.rawValue
        self.candidate = candidate
        self.rubric = rubric
        self.createdAt = .now
        self.sectionScores = []
        self.impressions = []
        self.bookmarks = []
        self.interviewers = []
    }

    var compositeGradePoints: Double? {
        let scored = sectionScores.compactMap { score -> (Double, Double)? in
            guard let gp = score.effectiveGradePoints else { return nil }
            return (gp, score.weight)
        }
        guard !scored.isEmpty else { return nil }
        let totalWeight = scored.reduce(0.0) { $0 + $1.1 }
        guard totalWeight > 0 else { return nil }
        return scored.reduce(0.0) { $0 + $1.0 * $1.1 } / totalWeight
    }
}
