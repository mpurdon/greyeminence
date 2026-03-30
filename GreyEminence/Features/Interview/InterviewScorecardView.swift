import SwiftUI
import SwiftData

struct InterviewScorecardView: View {
    @Bindable var interview: Interview
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \InterviewImpressionTrait.sortOrder) private var traits: [InterviewImpressionTrait]
    @State private var isReanalyzing = false
    @State private var reanalysisError: String?

    private var sortedScores: [InterviewSectionScore] {
        interview.sectionScores.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Label {
                        Text("Interview Scorecard")
                    } icon: {
                        Image(systemName: "list.clipboard")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.cyan.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .font(.headline)

                    Spacer()

                    if isReanalyzing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await reanalyze() }
                        } label: {
                            Label("Reanalyze", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal)

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
                    InterviewSectionScoreCard(score: score)
                        .padding(.horizontal)
                }

                // Strengths / Weaknesses / Red Flags
                if !strengthsList.isEmpty {
                    signalSection(title: "Strengths", items: strengthsList, icon: "arrow.up.circle.fill", color: .green)
                }
                if !weaknessesList.isEmpty {
                    signalSection(title: "Weaknesses", items: weaknessesList, icon: "arrow.down.circle.fill", color: .orange)
                }
                if !redFlagsList.isEmpty {
                    signalSection(title: "Red Flags", items: redFlagsList, icon: "flag.fill", color: .red)
                }

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

    // MARK: - Overall Score

    private var overallScoreSection: some View {
        HStack(spacing: 16) {
            if let gp = interview.compositeGradePoints {
                let grade = LetterGrade.from(gradePoints: gp)
                VStack(spacing: 2) {
                    Text(grade.label)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(gradeColor(grade))
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
                                .foregroundStyle(gradeColor(grade))
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

    // Placeholder: extract from interview or AI results
    private var strengthsList: [String] { [] }
    private var weaknessesList: [String] { [] }
    private var redFlagsList: [String] { [] }

    private func signalSection(title: String, items: [String], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.caption)
            }
        }
        .padding(.horizontal)
    }

    private func gradeColor(_ grade: LetterGrade) -> Color {
        switch grade {
        case .aPlus, .a, .aMinus: .green
        case .bPlus, .b, .bMinus: .blue
        case .cPlus, .c, .cMinus: .orange
        default: .red
        }
    }

    private func dotColor(_ value: Int) -> Color {
        switch value {
        case 1, 5: .orange
        case 3, 4: .green
        default: .secondary
        }
    }

    // MARK: - Reanalyze

    @MainActor
    private func reanalyze() async {
        guard !isReanalyzing else { return }
        isReanalyzing = true
        reanalysisError = nil
        defer { isReanalyzing = false }

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

        // Build rubric snapshot
        let rubricSnapshot = RubricSnapshot(
            name: rubric.name,
            sections: rubric.sections.sorted { $0.sortOrder < $1.sortOrder }.map { section in
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
        )

        let service = InterviewIntelligenceService(client: client, rubricContext: rubricSnapshot, meetingID: meeting.id)
        do {
            if let result = try await service.performFinalInterviewAnalysis(segments: snapshots) {
                // Apply scores
                for aiScore in result.sectionScores {
                    if let idx = interview.sectionScores.firstIndex(where: { $0.rubricSectionID == aiScore.sectionID }) {
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
                try? modelContext.save()
            }
        } catch {
            reanalysisError = error.localizedDescription
            LogManager.send("Interview reanalysis failed: \(error.localizedDescription)", category: .ai, level: .error)
        }
    }
}
