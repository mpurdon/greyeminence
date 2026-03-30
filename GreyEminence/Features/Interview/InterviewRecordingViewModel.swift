import Foundation
import SwiftUI
import SwiftData

@Observable
@MainActor
final class InterviewRecordingViewModel {
    let recordingViewModel: RecordingViewModel

    // Interview state
    var interview: Interview?
    var sectionScores: [InterviewSectionScore] = []
    var impressions: [InterviewImpression] = []
    var bookmarks: [InterviewBookmark] = []
    var rubricAnalysisState: RecordingViewModel.AIActivityState = .idle

    // AI results
    var strengths: [String] = []
    var weaknesses: [String] = []
    var redFlags: [String] = []
    var overallAssessment: String = ""

    // Interview intelligence service
    private var rubricAnalysisTask: Task<Void, Never>?

    var isInterviewActive: Bool {
        interview != nil && recordingViewModel.state != .idle
    }

    init(recordingViewModel: RecordingViewModel) {
        self.recordingViewModel = recordingViewModel
    }

    // MARK: - Interview Lifecycle

    func startInterview(
        candidate: Candidate,
        rubric: Rubric,
        interviewers: [Contact],
        notes: String?,
        in modelContext: ModelContext
    ) {
        // Create interview model
        let interview = Interview(candidate: candidate, rubric: rubric)
        interview.status = .recording
        interview.interviewerNotes = notes
        interview.interviewers = interviewers
        modelContext.insert(interview)

        // Create section score stubs
        var scores: [InterviewSectionScore] = []
        for section in rubric.sections.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let score = InterviewSectionScore(
                rubricSectionID: section.id,
                rubricSectionTitle: section.title,
                sortOrder: section.sortOrder,
                weight: section.weight
            )
            score.interview = interview
            scores.append(score)
        }

        // Create impression stubs from trait defaults
        let traitDescriptor = FetchDescriptor<InterviewImpressionTrait>(
            sortBy: [SortDescriptor(\InterviewImpressionTrait.sortOrder)]
        )
        let traits = (try? modelContext.fetch(traitDescriptor)) ?? []
        var imps: [InterviewImpression] = []
        for trait in traits {
            let impression = InterviewImpression(traitName: trait.name, value: 3) // Start at middle
            impression.interview = interview
            imps.append(impression)
        }

        self.interview = interview
        self.sectionScores = scores
        self.impressions = imps
        self.bookmarks = []
        self.strengths = []
        self.weaknesses = []
        self.redFlags = []
        self.overallAssessment = ""

        try? modelContext.save()

        // Mark the meeting as an interview meeting
        recordingViewModel.startRecording(in: modelContext)
        if let meeting = recordingViewModel.currentMeeting {
            meeting.isInterviewMeeting = true
            interview.meeting = meeting

            // Add interviewers as meeting attendees
            for contact in interviewers {
                if !meeting.attendees.contains(where: { $0.id == contact.id }) {
                    meeting.attendees.append(contact)
                }
            }
            try? modelContext.save()
        }

        // Start rubric analysis loop (offset from standard AI by ~20s)
        startRubricAnalysis(rubric: rubric)
    }

    func stopInterview(in modelContext: ModelContext) {
        // Cancel rubric analysis
        rubricAnalysisTask?.cancel()
        rubricAnalysisTask = nil
        rubricAnalysisState = .idle

        // Persist scores and impressions
        if let interview {
            interview.status = .completed
            interview.sectionScores = sectionScores
            interview.impressions = impressions
            interview.bookmarks = bookmarks
        }
        try? modelContext.save()

        // Stop the underlying recording
        recordingViewModel.stopRecording(in: modelContext)
    }

    // MARK: - Bookmarks

    func addBookmark(type: BookmarkType, note: String? = nil) {
        let bookmark = InterviewBookmark(
            type: type,
            timestamp: recordingViewModel.elapsedTime,
            note: note
        )
        bookmark.interview = interview
        bookmarks.append(bookmark)
    }

    // MARK: - Impression Updates

    func updateImpression(traitName: String, value: Int) {
        if let idx = impressions.firstIndex(where: { $0.traitName == traitName }) {
            impressions[idx].value = min(max(value, 1), 5)
        }
    }

    // MARK: - Section Score Updates

    func updateInterviewerGrade(sectionID: UUID, grade: LetterGrade?) {
        if let idx = sectionScores.firstIndex(where: { $0.rubricSectionID == sectionID }) {
            sectionScores[idx].interviewerGrade = grade
        }
    }

    func updateInterviewerNotes(sectionID: UUID, notes: String) {
        if let idx = sectionScores.firstIndex(where: { $0.rubricSectionID == sectionID }) {
            sectionScores[idx].interviewerNotes = notes.isEmpty ? nil : notes
        }
    }

    // MARK: - Rubric Analysis Loop

    private func startRubricAnalysis(rubric: Rubric) {
        let rubricSnapshot = makeRubricSnapshot(rubric)

        rubricAnalysisTask = Task { [weak self] in
            guard let self else { return }

            guard let client = try? await AIClientFactory.makeClient() else {
                await MainActor.run {
                    LogManager.shared.log("AI not configured — skipping rubric analysis", category: .ai, level: .warning)
                }
                return
            }

            let meetingID = await MainActor.run { self.recordingViewModel.currentMeeting?.id }
            let service = InterviewIntelligenceService(
                client: client,
                rubricContext: rubricSnapshot,
                meetingID: meetingID
            )

            // Wait 50s before first rubric analysis (offset from standard 30s)
            await self.waitSeconds(50)

            while !Task.isCancelled {
                await MainActor.run {
                    self.rubricAnalysisState = .analyzing
                }

                let snapshots = await MainActor.run { self.recordingViewModel.snapshotSegments() }

                do {
                    if let result = try await service.analyzeAgainstRubric(segments: snapshots) {
                        await MainActor.run {
                            self.applyAnalysisResult(result)
                        }
                    }
                } catch {
                    await MainActor.run {
                        LogManager.shared.log("Rubric analysis error: \(error.localizedDescription)", category: .ai, level: .error)
                    }
                }

                // Wait 45s before next analysis
                await self.waitSeconds(45)
            }
        }
    }

    private func waitSeconds(_ seconds: Int) async {
        for i in (0..<seconds).reversed() {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.rubricAnalysisState = .waiting(secondsRemaining: i)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func applyAnalysisResult(_ result: InterviewAnalysisResult) {
        // Update section scores from AI
        for aiScore in result.sectionScores {
            if let idx = sectionScores.firstIndex(where: { $0.rubricSectionID == aiScore.sectionID }) {
                if let gradeStr = aiScore.grade {
                    sectionScores[idx].aiGrade = LetterGrade(rawValue: gradeStr)
                }
                sectionScores[idx].aiConfidence = aiScore.confidence
                if let evidenceData = try? JSONSerialization.data(withJSONObject: aiScore.evidence),
                   let evidenceStr = String(data: evidenceData, encoding: .utf8) {
                    sectionScores[idx].aiEvidence = evidenceStr
                }
                sectionScores[idx].aiRationale = aiScore.rationale
            }
        }

        strengths = result.strengths
        weaknesses = result.weaknesses
        redFlags = result.redFlags
        overallAssessment = result.overallAssessment
    }

    private func makeRubricSnapshot(_ rubric: Rubric) -> RubricSnapshot {
        let sections = rubric.sections.sorted { $0.sortOrder < $1.sortOrder }.map { section in
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
        return RubricSnapshot(name: rubric.name, sections: sections)
    }

    // MARK: - Cleanup

    func reset() {
        interview = nil
        sectionScores = []
        impressions = []
        bookmarks = []
        strengths = []
        weaknesses = []
        redFlags = []
        overallAssessment = ""
        rubricAnalysisState = .idle
        rubricAnalysisTask?.cancel()
        rubricAnalysisTask = nil
    }
}
