import SwiftUI
import SwiftData

// MARK: - Bell-Curve Gradient Scoring

/// Maps a 0-1 normalized value to a color using bell-curve logic:
/// 0% = red, ramps to green peaking at ~80%, then back to red at 100%.
/// The "sweet spot" is 75-85%.
func bellCurveColor(for normalizedValue: Double) -> Color {
    let v = min(max(normalizedValue, 0), 1)
    // Peak at 0.80
    let distance = abs(v - 0.80) / 0.80
    let greenAmount = max(1.0 - distance * 2.5, 0)
    if greenAmount > 0.5 {
        return Color(red: (1.0 - greenAmount) * 0.8, green: 0.7, blue: 0.1)
    } else if v < 0.5 {
        return Color(red: 0.8, green: max(v * 1.4, 0.2), blue: 0.1)
    } else {
        return Color(red: 0.8, green: max(greenAmount * 1.2, 0.2), blue: 0.1)
    }
}

// MARK: - Main View

struct LiveInterviewIntelligenceView: View {
    var interviewViewModel: InterviewRecordingViewModel
    @Query(sort: \InterviewImpressionTrait.sortOrder) private var traits: [InterviewImpressionTrait]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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

                // Compact impression sliders
                impressionSliders
                    .padding(.horizontal)

                // Section cards (compact — no notes here, notes are below)
                ForEach(interviewViewModel.sectionScores.sorted(by: { $0.sortOrder < $1.sortOrder })) { score in
                    CompactSectionCard(score: score, interviewViewModel: interviewViewModel)
                        .padding(.horizontal)
                }

                Divider()
                    .padding(.horizontal)

                // Notes table (Notion-style)
                InterviewNotesTable(interviewViewModel: interviewViewModel)
                    .padding(.horizontal)

                // Strengths / Weaknesses / Red Flags
                if !interviewViewModel.strengths.isEmpty {
                    signalList(title: "Strengths", items: interviewViewModel.strengths, icon: "arrow.up.circle.fill", color: .green)
                }
                if !interviewViewModel.weaknesses.isEmpty {
                    signalList(title: "Weaknesses", items: interviewViewModel.weaknesses, icon: "arrow.down.circle.fill", color: .orange)
                }
                if !interviewViewModel.redFlags.isEmpty {
                    signalList(title: "Red Flags", items: interviewViewModel.redFlags, icon: "flag.fill", color: .red)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Rubric")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(interviewViewModel.sectionScores.sorted(by: { $0.sortOrder < $1.sortOrder })) { score in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(gradeColor(score.effectiveLetterGrade))
                            .frame(width: 6, height: 6)
                        Text(score.rubricSectionTitle)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        if let grade = score.effectiveLetterGrade {
                            Text(grade.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Compact Impression Sliders

    private var impressionSliders: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Impressions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(traits) { trait in
                if let impression = interviewViewModel.impressions.first(where: { $0.traitName == trait.name }) {
                    CompactSliderRow(trait: trait, impression: impression) { newValue in
                        interviewViewModel.updateImpression(traitName: trait.name, value: newValue)
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func gradeColor(_ grade: LetterGrade?) -> Color {
        guard let grade else { return .gray }
        let gp = grade.gradePoints / 4.0
        return bellCurveColor(for: gp)
    }

    private func signalList(title: String, items: [String], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Text("  \(item)")
                    .font(.caption)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Compact Slider Row

struct CompactSliderRow: View {
    let trait: InterviewImpressionTrait
    let impression: InterviewImpression
    var onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(trait.name)
                .font(.system(size: 10))
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            // Compact slider track
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let segmentWidth = totalWidth / 5.0
                let filledWidth = segmentWidth * Double(impression.value)

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)

                    // Filled portion with bell-curve gradient
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bellCurveColor(for: Double(impression.value) / 5.0))
                        .frame(width: filledWidth, height: 6)

                    // Tick marks
                    HStack(spacing: 0) {
                        ForEach(1...5, id: \.self) { value in
                            Rectangle()
                                .fill(Color.clear)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture { onChange(value) }
                        }
                    }
                }
            }
            .frame(height: 14)

            // Current label
            Text(trait.label(for: impression.value))
                .font(.system(size: 9))
                .foregroundStyle(bellCurveColor(for: Double(impression.value) / 5.0))
                .frame(width: 60, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

// MARK: - Compact Section Card

private struct CompactSectionCard: View {
    @Bindable var score: InterviewSectionScore
    var interviewViewModel: InterviewRecordingViewModel

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                // AI + interviewer grade row
                HStack(spacing: 12) {
                    if let aiGrade = score.aiGrade {
                        HStack(spacing: 3) {
                            Text("AI:")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(aiGrade.label)
                                .font(.system(size: 10, weight: .bold))
                            if let c = score.aiConfidence {
                                Text("\(Int(c * 100))%")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    HStack(spacing: 3) {
                        Text("You:")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Picker("", selection: Binding(
                            get: { score.interviewerGrade },
                            set: { interviewViewModel.updateInterviewerGrade(sectionID: score.rubricSectionID, grade: $0) }
                        )) {
                            Text("--").tag(nil as LetterGrade?)
                            ForEach(LetterGrade.allCases, id: \.self) { grade in
                                Text(grade.label).tag(grade as LetterGrade?)
                            }
                        }
                        .frame(width: 60)
                        .controlSize(.mini)
                    }
                }

                // Evidence (compact)
                if let evidenceJSON = score.aiEvidence,
                   let data = evidenceJSON.data(using: .utf8),
                   let evidence = try? JSONDecoder().decode([String].self, from: data),
                   !evidence.isEmpty {
                    ForEach(evidence, id: \.self) { quote in
                        Text("\"\(quote)\"")
                            .font(.system(size: 10))
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if let rationale = score.aiRationale, !rationale.isEmpty {
                    Text(rationale)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(score.rubricSectionTitle)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let grade = score.effectiveLetterGrade {
                    Text(grade.label)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(bellCurveColor(for: grade.gradePoints / 4.0).opacity(0.25), in: Capsule())
                        .foregroundStyle(bellCurveColor(for: grade.gradePoints / 4.0))
                }
            }
        }
        .font(.system(size: 11))
        .padding(6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Interview Notes Table (Notion-style)

struct InterviewNotesTable: View {
    var interviewViewModel: InterviewRecordingViewModel
    @State private var newNoteText = ""
    @FocusState private var isNewNoteFocused: Bool

    private var topLevelNotes: [InterviewNote] {
        interviewViewModel.notes
            .filter { $0.parentNote == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Note rows
            ForEach(topLevelNotes) { note in
                NoteRow(note: note, interviewViewModel: interviewViewModel, depth: 0)
            }

            // Add note row
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                TextField("Add a note...", text: $newNoteText)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .focused($isNewNoteFocused)
                    .onSubmit {
                        addNote()
                    }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func addNote() {
        let text = newNoteText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        interviewViewModel.addNote(text: text)
        newNoteText = ""
        isNewNoteFocused = true
    }
}

// MARK: - Note Row

private struct NoteRow: View {
    @Bindable var note: InterviewNote
    var interviewViewModel: InterviewRecordingViewModel
    let depth: Int

    @State private var isAddingSub = false
    @State private var subNoteText = ""
    @FocusState private var isSubFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                // Indent
                if depth > 0 {
                    Spacer()
                        .frame(width: CGFloat(depth) * 16)
                }

                // Category badge
                Button {
                    cycleCategory()
                } label: {
                    Text(note.category.rawValue.prefix(1))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(categoryColor(note.category), in: RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .help("Category: \(note.category.rawValue) (click to change)")

                // Note text
                TextField("", text: $note.text)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)

                Spacer()

                // Sub-note button
                Button {
                    isAddingSub.toggle()
                    isSubFocused = true
                } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Add sub-note")

                // Delete
                Button {
                    interviewViewModel.deleteNote(note)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)

            // Sub-notes
            ForEach(note.subNotes.sorted { $0.sortOrder < $1.sortOrder }) { sub in
                NoteRow(note: sub, interviewViewModel: interviewViewModel, depth: depth + 1)
            }

            // Add sub-note field
            if isAddingSub {
                HStack(spacing: 4) {
                    Spacer()
                        .frame(width: CGFloat(depth + 1) * 16)
                    Image(systemName: "plus")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14)
                    TextField("Sub-note...", text: $subNoteText)
                        .font(.system(size: 11))
                        .textFieldStyle(.plain)
                        .focused($isSubFocused)
                        .onSubmit {
                            let text = subNoteText.trimmingCharacters(in: .whitespaces)
                            if !text.isEmpty {
                                interviewViewModel.addNote(text: text, category: note.category, parent: note)
                                subNoteText = ""
                            } else {
                                isAddingSub = false
                            }
                        }
                        .onExitCommand { isAddingSub = false }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
            }
        }
    }

    private func cycleCategory() {
        let all = NoteCategory.allCases
        let idx = all.firstIndex(of: note.category) ?? 0
        note.category = all[(idx + 1) % all.count]
    }

    private func categoryColor(_ cat: NoteCategory) -> Color {
        switch cat {
        case .general: .gray
        case .technical: .blue
        case .fit: .purple
        }
    }
}

// MARK: - Backward-compatible ImpressionSliderRow (used by scorecard too)

struct ImpressionSliderRow: View {
    let trait: InterviewImpressionTrait
    let impression: InterviewImpression
    var onChange: (Int) -> Void

    var body: some View {
        CompactSliderRow(trait: trait, impression: impression, onChange: onChange)
    }
}
