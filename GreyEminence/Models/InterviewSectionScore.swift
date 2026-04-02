import Foundation
import SwiftUI
import SwiftData

enum LetterGrade: String, Codable, CaseIterable, Sendable {
    case aPlus = "A+"
    case a = "A"
    case aMinus = "A-"
    case bPlus = "B+"
    case b = "B"
    case bMinus = "B-"
    case cPlus = "C+"
    case c = "C"
    case cMinus = "C-"
    case dPlus = "D+"
    case d = "D"
    case f = "F"

    var gradePoints: Double {
        switch self {
        case .aPlus: 4.00
        case .a: 3.94
        case .aMinus: 3.84
        case .bPlus: 3.49
        case .b: 3.14
        case .bMinus: 2.84
        case .cPlus: 2.49
        case .c: 2.14
        case .cMinus: 1.84
        case .dPlus: 1.49
        case .d: 1.14
        case .f: 0.0
        }
    }

    var label: String { rawValue }

    var color: Color {
        switch self {
        case .aPlus, .a, .aMinus: .green
        case .bPlus, .b, .bMinus: .blue
        case .cPlus, .c, .cMinus: .orange
        default: .red
        }
    }

    var percentRange: String {
        switch self {
        case .aPlus: "90-100%"
        case .a: "85-89%"
        case .aMinus: "80-84%"
        case .bPlus: "75-79%"
        case .b: "70-74%"
        case .bMinus: "65-69%"
        case .cPlus: "60-64%"
        case .c: "55-59%"
        case .cMinus: "50-54%"
        case .dPlus: "45-49%"
        case .d: "40-44%"
        case .f: "Below 40%"
        }
    }

    static func from(gradePoints: Double) -> LetterGrade {
        switch gradePoints {
        case 3.95...: .aPlus
        case 3.85...: .a
        case 3.50...: .aMinus
        case 3.15...: .bPlus
        case 2.85...: .b
        case 2.50...: .bMinus
        case 2.15...: .cPlus
        case 1.85...: .c
        case 1.50...: .cMinus
        case 1.15...: .dPlus
        case 0.85...: .d
        default: .f
        }
    }
}

@Model
final class InterviewSectionScore {
    var id: UUID
    var rubricSectionID: UUID
    var rubricSectionTitle: String
    var sortOrder: Int
    var weight: Double

    // AI scoring
    var aiGradeRawValue: String?
    var aiConfidence: Double?
    var aiEvidence: String?
    var aiRationale: String?

    // Interviewer scoring
    var interviewerGradeRawValue: String?
    var interviewerNotes: String?

    // Bonus adjustment from bonus/penalty signals
    var bonusAdjustment: Double

    var createdAt: Date

    var interview: Interview?

    @Relationship(deleteRule: .cascade, inverse: \ScoreEvidence.sectionScore)
    var evidenceItems: [ScoreEvidence]

    var aiGrade: LetterGrade? {
        get { aiGradeRawValue.flatMap { LetterGrade(rawValue: $0) } }
        set { aiGradeRawValue = newValue?.rawValue }
    }

    var interviewerGrade: LetterGrade? {
        get { interviewerGradeRawValue.flatMap { LetterGrade(rawValue: $0) } }
        set { interviewerGradeRawValue = newValue?.rawValue }
    }

    var effectiveGrade: LetterGrade? {
        interviewerGrade ?? aiGrade
    }

    var effectiveGradePoints: Double? {
        guard let grade = effectiveGrade else { return nil }
        return min(max(grade.gradePoints + bonusAdjustment, 0), 4.0)
    }

    var effectiveLetterGrade: LetterGrade? {
        effectiveGradePoints.map { LetterGrade.from(gradePoints: $0) }
    }

    init(rubricSectionID: UUID, rubricSectionTitle: String, sortOrder: Int, weight: Double) {
        self.id = UUID()
        self.rubricSectionID = rubricSectionID
        self.rubricSectionTitle = rubricSectionTitle
        self.sortOrder = sortOrder
        self.weight = weight
        self.bonusAdjustment = 0.0
        self.createdAt = .now
        self.evidenceItems = []
    }
}
