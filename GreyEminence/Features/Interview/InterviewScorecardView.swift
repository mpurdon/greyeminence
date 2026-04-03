import SwiftUI
import SwiftData

struct InterviewScorecardView: View {
    @Bindable var interview: Interview
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InterviewImpressionTrait.sortOrder) private var traits: [InterviewImpressionTrait]
    @State private var isReanalyzing = false
    @State private var reanalysisError: String?
    @State private var sectionScoringStatus: [UUID: SectionScoringState] = [:]
    @State private var scorecardTab: ScorecardTab = .scorecard

    enum ScorecardTab: String, CaseIterable {
        case scorecard = "Scorecard"
        case transcript = "Transcript"
    }

    enum SectionScoringState {
        case pending
        case scoring
        case done
        case failed(String)
    }

    private var sortedScores: [InterviewSectionScore] {
        // Filter out any potentially deallocated scores (can happen during parallel scoring)
        interview.sectionScores
            .filter { !$0.isDeleted }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Picker("", selection: $scorecardTab) {
                    ForEach(ScorecardTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()

                if isReanalyzing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await reanalyze() }
                    } label: {
                        Label("Score All Sections", systemImage: "brain")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            switch scorecardTab {
            case .scorecard:
                scorecardContent
            case .transcript:
                transcriptContent
            }
        }
    }

    private var scorecardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                if let error = reanalysisError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { reanalysisError = nil }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                    .padding(.horizontal)
                }

                // Overall score
                overallScoreSection
                    .padding(.horizontal)

                // Recommendation picker
                recommendationSection
                    .padding(.horizontal)

                // Impression sliders (read-only display with values)
                impressionSection
                    .padding(.horizontal)

                // Section scorecards
                ForEach(sortedScores) { score in
                    HStack(spacing: 6) {
                        InterviewSectionScoreCard(score: score)
                        // Scoring status indicator
                        if let status = sectionScoringStatus[score.rubricSectionID] {
                            switch status {
                            case .pending:
                                Image(systemName: "circle.dotted")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                            case .scoring:
                                ProgressView()
                                    .controlSize(.mini)
                            case .done:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption2)
                            case .failed:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption2)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                // TODO: Strengths/weaknesses/red flags should be persisted on Interview from AI analysis results

                // Interviewer notes
                Section {
                    TextEditor(text: Binding(
                        get: { interview.interviewerNotes ?? "" },
                        set: { interview.interviewerNotes = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(minHeight: 60)
                    .font(.caption)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    )
                } header: {
                    Text("Interviewer Notes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private var transcriptSegments: [TranscriptSegment] {
        (interview.meeting?.segments ?? []).sorted { $0.startTime < $1.startTime }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if transcriptSegments.isEmpty {
            ContentUnavailableView(
                "No Transcript",
                systemImage: "text.bubble",
                description: Text("This interview has no transcript segments")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    var lastTag: String?
                    ForEach(transcriptSegments) { segment in
                        let showMarker = segment.sectionTag != nil && segment.sectionTag != lastTag
                        if showMarker {
                            SectionMarkerView(
                                title: segment.sectionTag!,
                                timestamp: segment.formattedTimestamp
                            )
                        }
                        TranscriptSegmentRow(segment: segment)
                            .contextMenu {
                                Menu("Tag Section") {
                                    Button("Intro") { tagSegment(segment, tag: "Intro", id: InterviewRecordingViewModel.introID) }
                                    ForEach(sortedScores) { score in
                                        Button(score.rubricSectionTitle) {
                                            tagSegment(segment, tag: score.rubricSectionTitle, id: score.rubricSectionID)
                                        }
                                    }
                                    Button("Conclusion") { tagSegment(segment, tag: "Conclusion", id: InterviewRecordingViewModel.conclusionID) }
                                    Divider()
                                    Button("Clear Tag") { tagSegment(segment, tag: nil, id: nil) }
                                }
                            }
                        let _ = { lastTag = segment.sectionTag }()
                    }
                }
                .padding()
            }
        }
    }

    private func tagSegment(_ segment: TranscriptSegment, tag: String?, id: UUID?) {
        segment.sectionTag = tag
        segment.sectionTagID = id
        try? modelContext.save()
    }

    // MARK: - Overall Score

    private var overallScoreSection: some View {
        HStack(spacing: 16) {
            if let gp = interview.compositeGradePoints {
                let grade = LetterGrade.from(gradePoints: gp)
                VStack(spacing: 2) {
                    Text(grade.label)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(grade.color)
                    Text(grade.percentRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 2) {
                    Text("—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("No scores yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Score breakdown
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(sortedScores) { score in
                    HStack(spacing: 4) {
                        Text(score.rubricSectionTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let grade = score.effectiveLetterGrade {
                            Text(grade.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(grade.color)
                        } else {
                            Text("—")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Recommendation

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recommendation")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ForEach(OverallRecommendation.allCases, id: \.self) { rec in
                    Button {
                        interview.overallRecommendation = rec
                    } label: {
                        Text(rec.shortLabel)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                interview.overallRecommendation == rec
                                    ? AnyShapeStyle(rec.color.opacity(0.3))
                                    : AnyShapeStyle(Color.secondary.opacity(0.15)),
                                in: Capsule()
                            )
                            .foregroundStyle(interview.overallRecommendation == rec ? rec.color : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(rec.label)
                }
            }
        }
    }

    // MARK: - Impressions

    private var impressionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Impressions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(interview.impressions.sorted(by: { $0.traitName < $1.traitName })) { impression in
                if let trait = traits.first(where: { $0.name == impression.traitName }) {
                    HStack {
                        Text(trait.name)
                            .font(.caption)
                            .frame(width: 100, alignment: .leading)
                        ForEach(1...5, id: \.self) { value in
                            Circle()
                                .fill(impression.value == value ? dotColor(value) : .secondary.opacity(0.2))
                                .frame(width: 10, height: 10)
                        }
                        Text(trait.label(for: impression.value))
                            .font(.caption2)
                            .foregroundStyle(dotColor(impression.value))
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func dotColor(_ value: Int) -> Color {
        switch value {
        case 1, 5: .orange
        case 3, 4: .green
        default: .secondary
        }
    }

    // MARK: - Reanalyze (Parallel Per-Section)

    @MainActor
    private func reanalyze() async {
        guard !isReanalyzing else { return }
        isReanalyzing = true
        reanalysisError = nil

        defer {
            isReanalyzing = false
            // Clear scoring status after a delay
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                sectionScoringStatus = [:]
            }
        }

        guard let meeting = interview.meeting else {
            reanalysisError = "No recording linked to this interview."
            return
        }
        guard let rubric = interview.rubric else {
            reanalysisError = "No rubric linked to this interview."
            return
        }
        guard let client = try? await AIClientFactory.makeClient() else {
            reanalysisError = "AI not configured. Check Settings."
            return
        }

        let snapshots: [SegmentSnapshot] = meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: $0.formattedTimestamp, isFinal: $0.isFinal) }

        guard !snapshots.isEmpty else {
            reanalysisError = "No transcript segments to analyze."
            return
        }

        let rubricSnapshot = rubric.toSnapshot()

        // Initialize all sections as pending
        for section in rubricSnapshot.sections {
            sectionScoringStatus[section.id] = .pending
        }

        // Score all sections in parallel using concurrent tasks
        let meetingID = meeting.id
        let sections = rubricSnapshot.sections

        var tasks: [UUID: Task<SectionScoreSnapshot?, Error>] = [:]
        for section in sections {
            sectionScoringStatus[section.id] = .scoring
            let sectionCopy = section
            let snapshotsCopy = snapshots
            let rubricCopy = rubricSnapshot
            tasks[section.id] = Task.detached {
                let service = InterviewIntelligenceService(
                    client: client,
                    rubricContext: rubricCopy,
                    meetingID: meetingID
                )
                return try await service.scoreSingleSection(
                    section: sectionCopy,
                    segments: snapshotsCopy
                )
            }
        }

        // Collect results as they complete
        for (sectionID, task) in tasks {
            do {
                if let score = try await task.value {
                    applySectionScore(score, sectionID: sectionID)
                }
                sectionScoringStatus[sectionID] = .done
            } catch {
                sectionScoringStatus[sectionID] = .failed(error.localizedDescription)
                LogManager.send("Section scoring failed: \(error.localizedDescription)", category: .ai, level: .warning)
            }
        }

        try? modelContext.save()
    }

    private func applySectionScore(_ aiScore: SectionScoreSnapshot, sectionID: UUID) {
        guard let idx = interview.sectionScores.firstIndex(where: { $0.rubricSectionID == sectionID }) else { return }
        if let gradeStr = aiScore.grade {
            interview.sectionScores[idx].aiGrade = LetterGrade(rawValue: gradeStr)
        }
        interview.sectionScores[idx].aiConfidence = aiScore.confidence
        if let evidenceData = try? JSONSerialization.data(withJSONObject: aiScore.evidence),
           let evidenceStr = String(data: evidenceData, encoding: .utf8) {
            interview.sectionScores[idx].aiEvidence = evidenceStr
        }
        interview.sectionScores[idx].aiRationale = aiScore.rationale
    }
}
