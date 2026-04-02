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

struct SectionScoreSnapshot: Sendable {
    let sectionID: UUID
    let sectionTitle: String
    let grade: String?
    let confidence: Double
    let evidence: [EvidenceSnapshot]
    let rationale: String
    let bonusSignals: [String: String]
}

struct InterviewAnalysisResult: Sendable {
    let sectionScores: [SectionScoreSnapshot]
    let strengths: [String]
    let weaknesses: [String]
    let redFlags: [String]
    let overallAssessment: String
}

// MARK: - Intelligence Service

actor InterviewIntelligenceService {
    private let client: any AIClient
    private let rubricContext: RubricSnapshot
    private let meetingID: UUID?
    private var previousScoresJSON: String = ""
    private var lastAnalyzedSegmentCount: Int = 0

    init(client: any AIClient, rubricContext: RubricSnapshot, meetingID: UUID? = nil) {
        self.client = client
        self.rubricContext = rubricContext
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
            userPrompt = InterviewPromptTemplates.initialAnalysisPrompt(
                rubric: rubricContext,
                activeSectionID: activeSectionID,
                transcript: transcript
            )
        } else {
            let transcript = AIPromptTemplates.formatSegments(newSegments)
            userPrompt = InterviewPromptTemplates.rollingAnalysisPrompt(
                rubric: rubricContext,
                activeSectionID: activeSectionID,
                previousScores: previousScoresJSON,
                newTranscript: transcript
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
            fullTranscript: fullTranscript
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
                    for ev in evidenceArray {
                        evidenceItems.append(EvidenceSnapshot(
                            quote: ev["quote"] as? String ?? "",
                            timestamp: ev["timestamp"] as? String ?? "",
                            criterion: ev["criterion"] as? String,
                            strength: ev["strength"] as? String ?? "moderate"
                        ))
                    }
                } else if let plainEvidence = score["evidence"] as? [String] {
                    // Fallback: plain string array → moderate strength, no timestamp
                    evidenceItems = plainEvidence.map {
                        EvidenceSnapshot(quote: $0, timestamp: "", criterion: nil, strength: "moderate")
                    }
                }

                sectionScores.append(SectionScoreSnapshot(
                    sectionID: sectionID,
                    sectionTitle: title,
                    grade: grade,
                    confidence: confidence,
                    evidence: evidenceItems,
                    rationale: rationale,
                    bonusSignals: bonusSignals
                ))
            }
        }

        let strengths = json["strengths"] as? [String] ?? []
        let weaknesses = json["weaknesses"] as? [String] ?? []
        let redFlags = json["red_flags"] as? [String] ?? []
        let overallAssessment = json["overall_assessment"] as? String ?? ""

        return InterviewAnalysisResult(
            sectionScores: sectionScores,
            strengths: strengths,
            weaknesses: weaknesses,
            redFlags: redFlags,
            overallAssessment: overallAssessment
        )
    }

    private func encodeScoresForRolling(_ scores: [SectionScoreSnapshot]) -> String {
        let dicts: [[String: Any]] = scores.map { score in
            let evidenceDicts: [[String: Any]] = score.evidence.map { ev in
                var d: [String: Any] = ["quote": ev.quote, "timestamp": ev.timestamp, "strength": ev.strength]
                if let criterion = ev.criterion { d["criterion"] = criterion }
                return d
            }
            var dict: [String: Any] = [
                "section_id": score.sectionID.uuidString,
                "section_title": score.sectionTitle,
                "confidence": score.confidence,
                "evidence": evidenceDicts,
                "rationale": score.rationale,
            ]
            if let grade = score.grade { dict["grade"] = grade }
            if !score.bonusSignals.isEmpty { dict["bonus_signals"] = score.bonusSignals }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
