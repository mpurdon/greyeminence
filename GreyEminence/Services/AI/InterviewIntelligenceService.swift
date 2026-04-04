import Foundation

// MARK: - Sendable Snapshot Types

struct RubricSnapshot: Sendable {
    let name: String
    let sections: [RubricSectionSnapshot]
}

struct RubricSectionSnapshot: Sendable {
    let id: UUID
    let title: String
    let description: String
    let criteria: [String]
    let bonusSignals: [BonusSignalSnapshot]
    let weight: Double
}

struct BonusSignalSnapshot: Sendable {
    let label: String
    let expected: String
    let value: Int
}

struct EvidenceSnapshot: Sendable {
    let quote: String
    let timestamp: String
    let criterion: String?
    let strength: String // "weak", "moderate", "strong"
}

enum CriterionStatus: String, Sendable, Codable {
    case notYetDiscussed = "not_yet_discussed"
    case partialEvidence = "partial_evidence"
    case scored = "scored"
}

struct CriterionEvaluationSnapshot: Sendable {
    let signal: String
    let status: CriterionStatus
    let confidence: Double
    let evidence: [EvidenceSnapshot]
    let summary: String?
}

struct SectionScoreSnapshot: Sendable {
    let sectionID: UUID
    let sectionTitle: String
    let grade: String?
    let confidence: Double
    let evidence: [EvidenceSnapshot]
    let rationale: String
    let bonusSignals: [String: String]
    let criterionEvaluations: [CriterionEvaluationSnapshot]
}

struct ImpressionTraitSnapshot: Sendable {
    let name: String
    let labels: [String] // 5 labels, index 0-4 for values 1-5
}

struct ImpressionSnapshot: Sendable {
    let trait: String
    let value: Int       // 1-5
    let rationale: String?
}

struct InterviewAnalysisResult: Sendable {
    let sectionScores: [SectionScoreSnapshot]
    let impressions: [ImpressionSnapshot]
    let strengths: [String]
    let weaknesses: [String]
    let redFlags: [String]
    let overallAssessment: String
}

// MARK: - EvidenceSnapshot Helpers

extension EvidenceSnapshot {
    func toDict() -> [String: Any] {
        var d: [String: Any] = ["quote": quote, "timestamp": timestamp, "strength": strength]
        if let criterion { d["criterion"] = criterion }
        return d
    }

    static func from(dict: [String: Any], defaultCriterion: String? = nil) -> EvidenceSnapshot {
        EvidenceSnapshot(
            quote: dict["quote"] as? String ?? "",
            timestamp: dict["timestamp"] as? String ?? "",
            criterion: dict["criterion"] as? String ?? defaultCriterion,
            strength: dict["strength"] as? String ?? "moderate"
        )
    }
}

// MARK: - Intelligence Service

actor InterviewIntelligenceService {
    private let client: any AIClient
    private let rubricContext: RubricSnapshot
    private let impressionTraits: [ImpressionTraitSnapshot]
    private let meetingID: UUID?
    private var previousScoresJSON: String = ""
    private var lastAnalyzedSegmentCount: Int = 0

    init(client: any AIClient, rubricContext: RubricSnapshot, impressionTraits: [ImpressionTraitSnapshot] = [], meetingID: UUID? = nil) {
        self.client = client
        self.rubricContext = rubricContext
        self.impressionTraits = impressionTraits
        self.meetingID = meetingID
    }

    func analyzeAgainstRubric(segments: [SegmentSnapshot], activeSectionID: UUID? = nil) async throws -> InterviewAnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty.count > lastAnalyzedSegmentCount else { return nil }

        let newSegments = Array(nonEmpty.dropFirst(lastAnalyzedSegmentCount))
        guard !newSegments.isEmpty else { return nil }

        let userPrompt: String
        if previousScoresJSON.isEmpty {
            let transcript = AIPromptTemplates.formatSegments(nonEmpty)
            userPrompt = InterviewPromptTemplates.sectionFocusedPrompt(
                rubric: rubricContext,
                activeSectionID: activeSectionID,
                previousScores: "",
                newTranscript: transcript,
                impressionTraits: impressionTraits
            )
        } else {
            let transcript = AIPromptTemplates.formatSegments(newSegments)
            userPrompt = InterviewPromptTemplates.sectionFocusedPrompt(
                rubric: rubricContext,
                activeSectionID: activeSectionID,
                previousScores: previousScoresJSON,
                newTranscript: transcript,
                impressionTraits: impressionTraits
            )
        }

        LogManager.send("Interview rubric analysis starting (\(nonEmpty.count) segments)", category: .ai, meetingID: meetingID)
        let response = try await withTimeout(seconds: 90) {
            try await self.client.sendMessage(
                system: InterviewPromptTemplates.systemPrompt,
                userContent: userPrompt
            )
        }
        LogManager.send("Interview rubric response (\(response.count) chars)", category: .ai, meetingID: meetingID)

        let result = try parseResponse(response)
        // Store as JSON for next rolling pass
        previousScoresJSON = encodeScoresForRolling(result.sectionScores)
        lastAnalyzedSegmentCount = nonEmpty.count
        return result
    }

    func performFinalInterviewAnalysis(segments: [SegmentSnapshot]) async throws -> InterviewAnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return nil }

        guard !previousScoresJSON.isEmpty else {
            return try await analyzeAgainstRubric(segments: segments)
        }

        let fullTranscript = AIPromptTemplates.formatSegments(nonEmpty)
        let userPrompt = InterviewPromptTemplates.finalAnalysisPrompt(
            rubric: rubricContext,
            accumulatedScores: previousScoresJSON,
            fullTranscript: fullTranscript,
            impressionTraits: impressionTraits
        )

        LogManager.send("Interview final analysis starting (\(nonEmpty.count) segments)", category: .ai, meetingID: meetingID)
        let response = try await withTimeout(seconds: 90) {
            try await self.client.sendMessage(
                system: InterviewPromptTemplates.systemPrompt,
                userContent: userPrompt
            )
        }
        LogManager.send("Interview final response (\(response.count) chars)", category: .ai, meetingID: meetingID)

        return try parseResponse(response)
    }

    /// Score a single rubric section independently against the full transcript.
    func scoreSingleSection(
        section: RubricSectionSnapshot,
        segments: [SegmentSnapshot]
    ) async throws -> InterviewAnalysisResult? {
        let nonEmpty = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else {
            LogManager.send("Section scoring '\(section.title)': no non-empty segments", category: .ai, level: .warning, meetingID: meetingID)
            return nil
        }

        let fullTranscript = AIPromptTemplates.formatSegments(nonEmpty)
        let userPrompt = InterviewPromptTemplates.singleSectionPrompt(
            section: section,
            fullTranscript: fullTranscript
        )

        LogManager.send("Section scoring '\(section.title)': sending \(nonEmpty.count) segments (\(userPrompt.count) chars)", category: .ai, meetingID: meetingID)

        let response = try await withTimeout(seconds: 90) {
            try await self.client.sendMessage(
                system: InterviewPromptTemplates.systemPrompt,
                userContent: userPrompt
            )
        }

        LogManager.send("Section scoring '\(section.title)': response \(response.count) chars", category: .ai, meetingID: meetingID)

        let result = try parseResponse(response)
        if let matched = result.sectionScores.first(where: { $0.sectionID == section.id }) {
            LogManager.send("Section scoring '\(section.title)': grade=\(matched.grade ?? "nil"), confidence=\(matched.confidence), criteria=\(matched.criterionEvaluations.count), strengths=\(result.strengths.count), weaknesses=\(result.weaknesses.count)", category: .ai, meetingID: meetingID)
        } else {
            LogManager.send("Section scoring '\(section.title)': no matching score in response (got \(result.sectionScores.map(\.sectionTitle)))", category: .ai, level: .warning, meetingID: meetingID)
        }

        return result
    }

    // MARK: - Parsing

    private func parseResponse(_ raw: String) throws -> InterviewAnalysisResult {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LogManager.send("Interview AI parse failed: \(cleaned.prefix(500))", category: .ai, level: .error, meetingID: meetingID)
            throw AIParseError.invalidJSON
        }

        var sectionScores: [SectionScoreSnapshot] = []
        if let scores = json["section_scores"] as? [[String: Any]] {
            for score in scores {
                let sectionID = (score["section_id"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
                let title = score["section_title"] as? String ?? ""
                let grade = score["grade"] as? String
                let confidence = score["confidence"] as? Double ?? 0
                let rationale = score["rationale"] as? String ?? ""
                let bonusSignals = score["bonus_signals"] as? [String: String] ?? [:]

                // Parse structured evidence (with fallback for plain string arrays)
                var evidenceItems: [EvidenceSnapshot] = []
                if let evidenceArray = score["evidence"] as? [[String: Any]] {
                    evidenceItems = evidenceArray.map { EvidenceSnapshot.from(dict: $0) }
                } else if let plainEvidence = score["evidence"] as? [String] {
                    // Fallback: plain string array → moderate strength, no timestamp
                    evidenceItems = plainEvidence.map {
                        EvidenceSnapshot(quote: $0, timestamp: "", criterion: nil, strength: "moderate")
                    }
                }

                var criterionEvals: [CriterionEvaluationSnapshot] = []
                if let critArray = score["criterion_evaluations"] as? [[String: Any]] {
                    for crit in critArray {
                        let signal = crit["signal"] as? String ?? ""
                        let statusStr = crit["status"] as? String ?? "not_yet_discussed"
                        let status = CriterionStatus(rawValue: statusStr) ?? .notYetDiscussed
                        let conf = crit["confidence"] as? Double ?? 0
                        let summary = crit["summary"] as? String
                        var critEvidence: [EvidenceSnapshot] = []
                        if let evArray = crit["evidence"] as? [[String: Any]] {
                            critEvidence = evArray.map { EvidenceSnapshot.from(dict: $0, defaultCriterion: signal) }
                        }
                        criterionEvals.append(CriterionEvaluationSnapshot(
                            signal: signal, status: status, confidence: conf, evidence: critEvidence, summary: summary
                        ))
                    }
                } else {
                    // Fallback: synthesize from section-level evidence by grouping on criterion
                    let grouped = Dictionary(grouping: evidenceItems.filter { $0.criterion != nil }, by: { $0.criterion! })
                    for (criterion, evs) in grouped {
                        criterionEvals.append(CriterionEvaluationSnapshot(
                            signal: criterion, status: .scored, confidence: confidence, evidence: evs, summary: nil
                        ))
                    }
                }

                sectionScores.append(SectionScoreSnapshot(
                    sectionID: sectionID,
                    sectionTitle: title,
                    grade: grade,
                    confidence: confidence,
                    evidence: evidenceItems,
                    rationale: rationale,
                    bonusSignals: bonusSignals,
                    criterionEvaluations: criterionEvals
                ))
            }
        }

        var impressions: [ImpressionSnapshot] = []
        if let impArray = json["impressions"] as? [[String: Any]] {
            for imp in impArray {
                let trait = imp["trait"] as? String ?? ""
                let value = imp["value"] as? Int ?? 3
                let rationale = imp["rationale"] as? String
                impressions.append(ImpressionSnapshot(trait: trait, value: min(max(value, 1), 5), rationale: rationale))
            }
        }

        let strengths = json["strengths"] as? [String] ?? []
        let weaknesses = json["weaknesses"] as? [String] ?? []
        let redFlags = json["red_flags"] as? [String] ?? []
        let overallAssessment = json["overall_assessment"] as? String ?? ""

        return InterviewAnalysisResult(
            sectionScores: sectionScores,
            impressions: impressions,
            strengths: strengths,
            weaknesses: weaknesses,
            redFlags: redFlags,
            overallAssessment: overallAssessment
        )
    }

    private func encodeScoresForRolling(_ scores: [SectionScoreSnapshot]) -> String {
        let dicts: [[String: Any]] = scores.map { score in
            let evidenceDicts: [[String: Any]] = score.evidence.map { $0.toDict() }
            var dict: [String: Any] = [
                "section_id": score.sectionID.uuidString,
                "section_title": score.sectionTitle,
                "confidence": score.confidence,
                "evidence": score.criterionEvaluations.isEmpty ? evidenceDicts : [],
                "rationale": score.rationale,
            ]
            if let grade = score.grade { dict["grade"] = grade }
            if !score.bonusSignals.isEmpty { dict["bonus_signals"] = score.bonusSignals }
            if !score.criterionEvaluations.isEmpty {
                dict["criterion_evaluations"] = score.criterionEvaluations.map { crit in
                    var d: [String: Any] = [
                        "signal": crit.signal,
                        "status": crit.status.rawValue,
                        "confidence": crit.confidence,
                    ]
                    if let summary = crit.summary { d["summary"] = summary }
                    if !crit.evidence.isEmpty {
                        d["evidence"] = crit.evidence.map { $0.toDict() }
                    }
                    return d
                }
            }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
