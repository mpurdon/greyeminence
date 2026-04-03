import SwiftUI

struct InterviewSectionScoreCard: View {
    @Bindable var score: InterviewSectionScore
    @State private var isExpanded = false

    private var sortedCriteria: [CriterionEvaluation] {
        score.criterionEvaluations
            .filter { !$0.isDeleted }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                // Dual score display
                gradeRow

                // Per-criterion evaluations
                if !sortedCriteria.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Criteria")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(sortedCriteria) { eval in
                            CriterionRow(eval: eval)
                        }
                    }
                }

                // Section-level evidence (if no criterion-level detail)
                if sortedCriteria.isEmpty {
                    legacyEvidence
                }

                // Rationale
                if let rationale = score.aiRationale, !rationale.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rationale")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Interviewer notes
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Notes")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { score.interviewerNotes ?? "" },
                        set: { score.interviewerNotes = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(minHeight: 40)
                    .font(.caption)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary)
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(score.rubricSectionTitle)
                    .font(.subheadline.weight(.semibold))

                // Criterion progress dots
                if !sortedCriteria.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(sortedCriteria) { eval in
                            Circle()
                                .fill(statusColor(eval.status))
                                .frame(width: 6, height: 6)
                        }
                    }
                }

                Spacer()

                Text("w: \(Int(score.weight))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let grade = score.effectiveLetterGrade {
                    Text(grade.label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(grade.color.opacity(0.2), in: Capsule())
                        .foregroundStyle(grade.color)
                } else {
                    Text("—")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Grade Row

    private var gradeRow: some View {
        HStack(spacing: 16) {
            VStack(spacing: 2) {
                Text("AI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let grade = score.aiGrade {
                    Text(grade.label)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(grade.color)
                } else {
                    Text("—")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                if let confidence = score.aiConfidence {
                    Text("\(Int(confidence * 100))% conf.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 50)

            VStack(spacing: 2) {
                Text("You")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("", selection: $score.interviewerGrade) {
                    Text("—").tag(nil as LetterGrade?)
                    ForEach(LetterGrade.allCases, id: \.self) { grade in
                        Text(grade.label).tag(grade as LetterGrade?)
                    }
                }
                .frame(width: 60)
            }

            if let effective = score.effectiveLetterGrade {
                VStack(spacing: 2) {
                    Text("Effective")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(effective.label)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(effective.color)
                }
            }

            Spacer()
        }
    }

    // MARK: - Legacy Evidence (fallback when no criterion evaluations)

    @ViewBuilder
    private var legacyEvidence: some View {
        if let evidenceJSON = score.aiEvidence,
           let data = evidenceJSON.data(using: .utf8),
           let evidence = try? JSONDecoder().decode([String].self, from: data),
           !evidence.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Evidence")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(evidence, id: \.self) { quote in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(quote)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func statusColor(_ status: CriterionStatus) -> Color {
        switch status {
        case .scored: .green
        case .partialEvidence: .yellow
        case .notYetDiscussed: .gray
        }
    }
}

// MARK: - Criterion Row

private struct CriterionRow: View {
    let eval: CriterionEvaluation

    private var sortedEvidence: [CriterionEvidence] {
        eval.evidenceItems.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(eval.signal)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(eval.status == .notYetDiscussed ? .tertiary : .primary)
                        Spacer()
                        if eval.confidence > 0 {
                            Text("\(Int(eval.confidence * 100))%")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let summary = eval.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    // Evidence quotes
                    ForEach(sortedEvidence) { ev in
                        HStack(spacing: 4) {
                            if !ev.timestamp.isEmpty {
                                Text(ev.timestamp)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            strengthDot(ev.strength)
                            Text("\u{201C}\(ev.quote)\u{201D}")
                                .font(.caption)
                                .italic()
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.leading, 4)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        switch eval.status {
        case .scored: "checkmark.circle.fill"
        case .partialEvidence: "circle.dotted"
        case .notYetDiscussed: "circle"
        }
    }

    private var statusColor: Color {
        switch eval.status {
        case .scored: .green
        case .partialEvidence: .yellow
        case .notYetDiscussed: .gray
        }
    }

    private func strengthDot(_ strength: EvidenceStrength) -> some View {
        Circle()
            .fill(strengthColor(strength))
            .frame(width: 5, height: 5)
    }

    private func strengthColor(_ strength: EvidenceStrength) -> Color {
        switch strength {
        case .strong: .green
        case .moderate: .blue
        case .weak: .orange
        }
    }
}
