import SwiftUI
import SwiftData

struct LiveInterviewIntelligenceView: View {
    var interviewViewModel: InterviewRecordingViewModel
    @Query(sort: \InterviewImpressionTrait.sortOrder) private var traits: [InterviewImpressionTrait]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Label {
                        Text("Interview Intelligence")
                    } icon: {
                        Image(systemName: "brain")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.cyan.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .font(.headline)

                    Spacer()

                    AIActivityIndicator(state: interviewViewModel.rubricAnalysisState)
                }
                .padding(.horizontal)

                // Rubric score overview
                rubricOverview
                    .padding(.horizontal)

                // Feeling sliders
                impressionSliders
                    .padding(.horizontal)

                // Section details
                ForEach(interviewViewModel.sectionScores.sorted(by: { $0.sortOrder < $1.sortOrder })) { score in
                    LiveSectionCard(score: score, interviewViewModel: interviewViewModel)
                        .padding(.horizontal)
                }

                // Strengths / Weaknesses / Red Flags
                if !interviewViewModel.strengths.isEmpty {
                    signalSection(title: "Strengths", items: interviewViewModel.strengths, icon: "arrow.up.circle.fill", color: .green)
                }
                if !interviewViewModel.weaknesses.isEmpty {
                    signalSection(title: "Weaknesses", items: interviewViewModel.weaknesses, icon: "arrow.down.circle.fill", color: .orange)
                }
                if !interviewViewModel.redFlags.isEmpty {
                    signalSection(title: "Red Flags", items: interviewViewModel.redFlags, icon: "flag.fill", color: .red)
                }

                if !interviewViewModel.overallAssessment.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overall Assessment")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(interviewViewModel.overallAssessment)
                            .font(.caption)
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    // MARK: - Rubric Overview

    private var rubricOverview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rubric Progress")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 6) {
                ForEach(interviewViewModel.sectionScores.sorted(by: { $0.sortOrder < $1.sortOrder })) { score in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(scoreColor(score))
                            .frame(width: 8, height: 8)
                        Text(score.rubricSectionTitle)
                            .font(.caption2)
                            .lineLimit(1)
                        if let grade = score.effectiveLetterGrade {
                            Text(grade.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func scoreColor(_ score: InterviewSectionScore) -> Color {
        guard let confidence = score.aiConfidence, confidence > 0 else { return .gray }
        guard let grade = score.effectiveLetterGrade else { return .gray }
        switch grade {
        case .aPlus, .a, .aMinus: return .green
        case .bPlus, .b, .bMinus: return .blue
        case .cPlus, .c, .cMinus: return .orange
        default: return .red
        }
    }

    // MARK: - Impression Sliders

    private var impressionSliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Impressions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(traits) { trait in
                if let impression = interviewViewModel.impressions.first(where: { $0.traitName == trait.name }) {
                    ImpressionSliderRow(trait: trait, impression: impression) { newValue in
                        interviewViewModel.updateImpression(traitName: trait.name, value: newValue)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Signal Section

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
}

// MARK: - Impression Slider Row

struct ImpressionSliderRow: View {
    let trait: InterviewImpressionTrait
    let impression: InterviewImpression
    var onChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(trait.name)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(trait.label(for: impression.value))
                    .font(.caption)
                    .foregroundStyle(labelColor(for: impression.value))
            }
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        onChange(value)
                    } label: {
                        VStack(spacing: 1) {
                            Circle()
                                .fill(impression.value == value ? dotColor(for: value) : Color.secondary.opacity(0.3))
                                .frame(width: 12, height: 12)
                            Text(trait.label(for: value))
                                .font(.system(size: 8))
                                .foregroundStyle(impression.value == value ? dotColor(for: value) : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dotColor(for value: Int) -> Color {
        switch value {
        case 1: .orange      // Too low — notable
        case 2: .secondary   // Below sweet spot
        case 3: .green       // Sweet spot start
        case 4: .green       // Sweet spot
        case 5: .orange      // Too much — notable
        default: .gray
        }
    }

    private func labelColor(for value: Int) -> Color {
        switch value {
        case 1, 5: .orange
        case 3, 4: .green
        default: .secondary
        }
    }
}

// MARK: - Live Section Card

private struct LiveSectionCard: View {
    @Bindable var score: InterviewSectionScore
    var interviewViewModel: InterviewRecordingViewModel

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                // AI grade + confidence
                if let aiGrade = score.aiGrade {
                    HStack {
                        Text("AI Grade: \(aiGrade.label)")
                            .font(.caption.weight(.semibold))
                        if let confidence = score.aiConfidence {
                            ProgressView(value: confidence)
                                .frame(width: 50)
                            Text("\(Int(confidence * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Evidence
                if let evidenceJSON = score.aiEvidence,
                   let data = evidenceJSON.data(using: .utf8),
                   let evidence = try? JSONDecoder().decode([String].self, from: data),
                   !evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Evidence")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(evidence, id: \.self) { quote in
                            Text("\"\(quote)\"")
                                .font(.caption)
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Rationale
                if let rationale = score.aiRationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Interviewer grade
                HStack {
                    Text("Your Grade:")
                        .font(.caption)
                    Picker("", selection: Binding(
                        get: { score.interviewerGrade },
                        set: { interviewViewModel.updateInterviewerGrade(sectionID: score.rubricSectionID, grade: $0) }
                    )) {
                        Text("—").tag(nil as LetterGrade?)
                        ForEach(LetterGrade.allCases, id: \.self) { grade in
                            Text(grade.label).tag(grade as LetterGrade?)
                        }
                    }
                    .frame(width: 80)
                }

                // Interviewer notes
                TextField("Your notes...", text: Binding(
                    get: { score.interviewerNotes ?? "" },
                    set: { interviewViewModel.updateInterviewerNotes(sectionID: score.rubricSectionID, notes: $0) }
                ), axis: .vertical)
                .lineLimit(2...4)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
            }
        } label: {
            HStack(spacing: 6) {
                Text(score.rubricSectionTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let grade = score.effectiveLetterGrade {
                    Text(grade.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(gradeColor(grade).opacity(0.2), in: Capsule())
                        .foregroundStyle(gradeColor(grade))
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func gradeColor(_ grade: LetterGrade) -> Color {
        switch grade {
        case .aPlus, .a, .aMinus: .green
        case .bPlus, .b, .bMinus: .blue
        case .cPlus, .c, .cMinus: .orange
        default: .red
        }
    }
}
