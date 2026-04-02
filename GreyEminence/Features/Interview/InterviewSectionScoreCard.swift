import SwiftUI

struct InterviewSectionScoreCard: View {
    @Bindable var score: InterviewSectionScore
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                // Dual score display
                HStack(spacing: 16) {
                    // AI grade
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

                    // Interviewer grade
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

                    // Effective grade
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

                // Evidence
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

}
