import SwiftUI
import SwiftData

// MARK: - Bell-Curve Gradient Scoring

func bellCurveColor(for normalizedValue: Double) -> Color {
    let v = min(max(normalizedValue, 0), 1)
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

// MARK: - Main Panel (no header — header is in InterviewHubView)

struct LiveInterviewIntelligenceView: View {
    var interviewViewModel: InterviewRecordingViewModel
    @Query(sort: \InterviewImpressionTrait.sortOrder) private var traits: [InterviewImpressionTrait]

    private var recordingVM: RecordingViewModel {
        interviewViewModel.recordingViewModel
    }

    private var activeScore: InterviewSectionScore? {
        guard let id = interviewViewModel.activeSectionID else { return nil }
        return interviewViewModel.sectionScores.first { $0.rubricSectionID == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Phase icons (left) + Impressions (right)
            HStack(spacing: 0) {
                phaseIcons
                Spacer(minLength: 8)
                impressionsStrip
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar.opacity(0.3))

            Divider()

            // Content for active phase
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if interviewViewModel.isRubricPhase, let score = activeScore {
                        ActiveSectionDetail(score: score, interviewViewModel: interviewViewModel)
                            .padding(.horizontal)
                    } else {
                        phaseOverview
                    }

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
    }

    // MARK: - Phase Icon Buttons

    private var phaseIcons: some View {
        HStack(spacing: 2) {
            phaseIconButton(icon: "person.wave.2", label: "Intro", id: InterviewRecordingViewModel.introID, grade: nil)
            phaseConnector

            let sections = interviewViewModel.sectionScores.sorted { $0.sortOrder < $1.sortOrder }
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, score in
                phaseIconButton(icon: "list.clipboard", label: score.rubricSectionTitle, id: score.rubricSectionID, grade: score.effectiveLetterGrade)
                if index < sections.count - 1 {
                    phaseConnector
                }
            }

            phaseConnector
            phaseIconButton(icon: "questionmark.bubble", label: "Conclusion", id: InterviewRecordingViewModel.conclusionID, grade: nil)
        }
    }

    private func phaseIconButton(icon: String, label: String, id: UUID, grade: LetterGrade?) -> some View {
        let isActive = interviewViewModel.activePhaseID == id
        return Button {
            interviewViewModel.setActivePhase(id)
        } label: {
            VStack(spacing: 1) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? .cyan : .secondary)
                        .frame(width: 28, height: 28)
                        .background(isActive ? Color.cyan.opacity(0.15) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isActive ? .cyan : .clear, lineWidth: 1.5))

                    if let grade {
                        Text(grade.label)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 2)
                            .background(bellCurveColor(for: grade.gradePoints / 4.0), in: RoundedRectangle(cornerRadius: 2))
                            .offset(x: 3, y: -3)
                    }
                }

                Text(label)
                    .font(.system(size: 8, weight: isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? .cyan : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 52)
            }
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var phaseConnector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 8, height: 1.5)
            .padding(.bottom, 14)
    }

    // MARK: - Impressions Strip

    /// Fixed colors per position: 1=red, 2=yellow, 3=blue, 4=green, 5=brown
    private static let dotColors: [Color] = [
        .red,
        .yellow,
        Color(red: 0.2, green: 0.4, blue: 0.8),  // blue
        .green,
        Color(red: 0.45, green: 0.28, blue: 0.08), // deep brown
    ]

    private var impressionsStrip: some View {
        HStack(spacing: 6) {
            ForEach(traits) { trait in
                if let impression = interviewViewModel.impressions.first(where: { $0.traitName == trait.name }) {
                    let activeColor = Self.dotColors[min(impression.value - 1, 4)]
                    VStack(spacing: 1) {
                        Text(trait.name)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)

                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { val in
                                Circle()
                                    .fill(val <= impression.value ? activeColor : Color.secondary.opacity(0.15))
                                    .frame(width: 7, height: 7)
                                    .contentShape(Rectangle().size(width: 14, height: 14))
                                    .onTapGesture {
                                        interviewViewModel.updateImpression(traitName: trait.name, value: val)
                                    }
                                    .help(trait.label(for: val))
                            }
                        }

                        Text(trait.label(for: impression.value))
                            .font(.system(size: 7))
                            .foregroundStyle(activeColor)
                            .lineLimit(1)
                    }
                    .frame(width: 80)
                    .help("\(trait.name): \(trait.label(for: impression.value))")
                }
            }
        }
    }

    // MARK: - Phase Overview (Intro / Conclusion)

    private var phaseOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if interviewViewModel.isConclusionPhase {
                Label("Candidate Questions", systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal)
            } else {
                Label("Introduction & General", systemImage: "person.wave.2")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal)
            }

            if !recordingVM.streamingSummary.isEmpty {
                AISummarySection(summary: recordingVM.streamingSummary)
            }

            if !recordingVM.followUpQuestions.isEmpty {
                FollowUpQuestionsSection(questions: recordingVM.followUpQuestions)
            }

            if !recordingVM.topics.isEmpty {
                KnowledgeLinksSection(topics: recordingVM.topics)
            }

            if recordingVM.streamingSummary.isEmpty {
                HStack {
                    Spacer()
                    if case .waiting(let secs) = recordingVM.aiActivityState {
                        Text("Summary in \(secs)s...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if case .analyzing = recordingVM.aiActivityState {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Analyzing...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Summary will appear once analysis begins")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.top, 20)
            }
        }
    }

    // MARK: - Helpers

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

// MARK: - Active Section Detail

private struct ActiveSectionDetail: View {
    @Bindable var score: InterviewSectionScore
    var interviewViewModel: InterviewRecordingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(score.rubricSectionTitle)
                    .font(.title3.weight(.semibold))
                Spacer()
                if let effective = score.effectiveLetterGrade {
                    Text(effective.label)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(bellCurveColor(for: effective.gradePoints / 4.0))
                }
            }

            HStack(spacing: 16) {
                if let aiGrade = score.aiGrade {
                    HStack(spacing: 4) {
                        Text("AI:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(aiGrade.label)
                            .font(.caption.weight(.bold))
                        if let c = score.aiConfidence {
                            Text("\(Int(c * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text("Your Grade:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { score.interviewerGrade },
                        set: { interviewViewModel.updateInterviewerGrade(sectionID: score.rubricSectionID, grade: $0) }
                    )) {
                        Text("--").tag(nil as LetterGrade?)
                        ForEach(LetterGrade.allCases, id: \.self) { grade in
                            Text(grade.label).tag(grade as LetterGrade?)
                        }
                    }
                    .frame(width: 70)
                    .controlSize(.small)
                }
            }

            // Evidence
            if !score.evidenceItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Evidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(score.evidenceItems.sorted(by: { $0.createdAt < $1.createdAt })) { evidence in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(strengthColor(evidence.strength))
                                .frame(width: 6, height: 6)
                                .padding(.top, 4)

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    if !evidence.timestamp.isEmpty {
                                        Text(evidence.timestamp)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let criterion = evidence.criterionSignal {
                                        Text(criterion)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(evidence.strength.rawValue)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                }
                                Text("\"\(evidence.quote)\"")
                                    .font(.caption)
                                    .italic()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if let evidenceJSON = score.aiEvidence,
                      let data = evidenceJSON.data(using: .utf8),
                      let evidence = try? JSONDecoder().decode([String].self, from: data),
                      !evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Evidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(evidence, id: \.self) { quote in
                        Text("\"\(quote)\"")
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let rationale = score.aiRationale, !rationale.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rationale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Your Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Add your observations...", text: Binding(
                    get: { score.interviewerNotes ?? "" },
                    set: { interviewViewModel.updateInterviewerNotes(sectionID: score.rubricSectionID, notes: $0) }
                ), axis: .vertical)
                .lineLimit(3...8)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func strengthColor(_ strength: EvidenceStrength) -> Color {
        switch strength {
        case .strong: .green
        case .moderate: .blue
        case .weak: .orange
        }
    }
}

// MARK: - Compact Slider Row (kept for scorecard use)

struct CompactSliderRow: View {
    let trait: InterviewImpressionTrait
    let impression: InterviewImpression
    var onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(trait.name)
                .font(.system(size: 10))
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                let totalWidth = geo.size.width
                let segmentWidth = totalWidth / 5.0
                let filledWidth = segmentWidth * Double(impression.value)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bellCurveColor(for: Double(impression.value) / 5.0))
                        .frame(width: filledWidth, height: 6)
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

            Text(trait.label(for: impression.value))
                .font(.system(size: 9))
                .foregroundStyle(bellCurveColor(for: Double(impression.value) / 5.0))
                .frame(width: 70, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

struct ImpressionSliderRow: View {
    let trait: InterviewImpressionTrait
    let impression: InterviewImpression
    var onChange: (Int) -> Void

    var body: some View {
        CompactSliderRow(trait: trait, impression: impression, onChange: onChange)
    }
}

// MARK: - Notes Table (used by right panel)

struct InterviewNotesTable: View {
    var interviewViewModel: InterviewRecordingViewModel
    @State private var newNoteText = ""
    @State private var indentNewNote = false
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

            ForEach(topLevelNotes) { note in
                NoteRow(note: note, interviewViewModel: interviewViewModel, depth: 0)
            }

            HStack(spacing: 4) {
                if indentNewNote {
                    Spacer().frame(width: 16)
                }
                Image(systemName: "plus")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                TextField(indentNewNote ? "Sub-note..." : "Add a note...", text: $newNoteText)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .focused($isNewNoteFocused)
                    .onSubmit {
                        let text = newNoteText.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        if indentNewNote, let lastTop = topLevelNotes.last {
                            interviewViewModel.addNote(text: text, parent: lastTop)
                        } else {
                            interviewViewModel.addNote(text: text)
                        }
                        newNoteText = ""
                        isNewNoteFocused = true
                    }
                    .onKeyPress(keys: [.tab]) { press in
                        if press.modifiers.contains(.shift) {
                            indentNewNote = false
                        } else {
                            indentNewNote = true
                        }
                        return .handled
                    }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct NoteRow: View {
    @Bindable var note: InterviewNote
    var interviewViewModel: InterviewRecordingViewModel
    let depth: Int

    @State private var isAddingSub = false
    @State private var subNoteText = ""
    @FocusState private var isSubFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                if depth > 0 { Spacer().frame(width: CGFloat(depth) * 16) }

                // Sentiment mini-menu
                Menu {
                    Button { note.sentiment = .neutral } label: {
                        Label("Neutral", systemImage: "minus.circle")
                    }
                    Button { note.sentiment = .wow } label: {
                        Label("Wow", systemImage: "star.fill")
                    }
                    Button { note.sentiment = .redFlag } label: {
                        Label("Red Flag", systemImage: "flag.fill")
                    }
                } label: {
                    sentimentIcon(note.sentiment)
                        .font(.system(size: 10))
                        .frame(width: 14, height: 14)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
                .help("Flag: \(note.sentiment.rawValue)")

                // Note text — highlighted bg for wow/red flag
                TextField("", text: $note.text)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 2)
                    .background(sentimentBackground(note.sentiment))
                    .onKeyPress(keys: [.tab]) { press in
                        if press.modifiers.contains(.shift) {
                            interviewViewModel.dedentNote(note)
                        } else {
                            interviewViewModel.indentNote(note)
                        }
                        return .handled
                    }

                Spacer()

                Button { isAddingSub.toggle(); isSubFocused = true } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                Button { interviewViewModel.deleteNote(note) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)

            ForEach(note.subNotes.sorted { $0.sortOrder < $1.sortOrder }) { sub in
                NoteRow(note: sub, interviewViewModel: interviewViewModel, depth: depth + 1)
            }

            if isAddingSub {
                HStack(spacing: 4) {
                    Spacer().frame(width: CGFloat(depth + 1) * 16)
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
                            } else { isAddingSub = false }
                        }
                        .onExitCommand { isAddingSub = false }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
            }
        }
    }


    @ViewBuilder
    private func sentimentIcon(_ sentiment: NoteSentiment) -> some View {
        switch sentiment {
        case .neutral:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary.opacity(0.4))
        case .wow:
            Image(systemName: "star.fill")
                .foregroundStyle(.green)
        case .redFlag:
            Image(systemName: "flag.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func sentimentBackground(_ sentiment: NoteSentiment) -> some View {
        switch sentiment {
        case .neutral:
            Color.clear
        case .wow:
            RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.08))
        case .redFlag:
            RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.08))
        }
    }
}
