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

    // Interview intelligence service task
    private var rubricAnalysisTask: Task<Void, Never>?
    private var interviewIntelligenceService: AnyObject? // Will be InterviewIntelligenceService once built

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
