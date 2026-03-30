import SwiftUI
import SwiftData

struct RubricSectionEditorView: View {
    @Bindable var section: RubricSection
    @Environment(\.modelContext) private var modelContext
    var onDelete: () -> Void

    @State private var isExpanded = true
    @State private var newCriterionText = ""
    @State private var newBonusLabel = ""
    @State private var newBonusExpected = "yes"
    @State private var newBonusValue = 1

    private var sortedCriteria: [RubricCriterion] {
        section.criteria.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var sortedBonuses: [RubricBonusSignal] {
        section.bonusSignals.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            // Section config
            TextField("Description", text: $section.sectionDescription, axis: .vertical)
                .lineLimit(2...4)
                .font(.caption)

            HStack {
                Text("Weight")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $section.weight, in: 1...100, step: 1)
                Text("\(Int(section.weight))")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            // Criteria
            if !sortedCriteria.isEmpty {
                ForEach(sortedCriteria) { criterion in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Signal", text: Binding(
                                get: { criterion.signal },
                                set: { criterion.signal = $0 }
                            ))
                            .font(.body)
                            TextField("Evaluation notes (optional)", text: Binding(
                                get: { criterion.evaluationNotes ?? "" },
                                set: { criterion.evaluationNotes = $0.isEmpty ? nil : $0 }
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            section.criteria.removeAll { $0.id == criterion.id }
                            modelContext.delete(criterion)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Add criterion
            HStack {
                TextField("Add criterion...", text: $newCriterionText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCriterion() }
                Button("Add") { addCriterion() }
                    .controlSize(.small)
                    .disabled(newCriterionText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Bonus signals
            if !sortedBonuses.isEmpty {
                Divider()
                Text("Bonus / Penalty Signals")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(sortedBonuses) { signal in
                    HStack(spacing: 6) {
                        Image(systemName: signal.bonusValue >= 0 ? "plus.circle" : "minus.circle")
                            .font(.caption)
                            .foregroundStyle(signal.bonusValue >= 0 ? .blue : .orange)
                        TextField("Label", text: Binding(
                            get: { signal.label },
                            set: { signal.label = $0 }
                        ))
                        .frame(maxWidth: 200)
                        Text("expect:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        TextField("", text: Binding(
                            get: { signal.expectedAnswer },
                            set: { signal.expectedAnswer = $0 }
                        ))
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                        Stepper("", value: Binding(
                            get: { signal.bonusValue },
                            set: { signal.bonusValue = $0 }
                        ), in: -5...5)
                        .labelsHidden()
                        Text("\(signal.bonusValue > 0 ? "+" : "")\(signal.bonusValue)")
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(signal.bonusValue >= 0 ? .blue : .orange)
                            .frame(width: 28, alignment: .trailing)
                        Button {
                            section.bonusSignals.removeAll { $0.id == signal.id }
                            modelContext.delete(signal)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Add bonus signal
            HStack(spacing: 6) {
                TextField("Add bonus signal...", text: $newBonusLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { addBonusSignal() }
                TextField("expect", text: $newBonusExpected)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Stepper("", value: $newBonusValue, in: -5...5)
                    .labelsHidden()
                Text("\(newBonusValue > 0 ? "+" : "")\(newBonusValue)")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .frame(width: 28, alignment: .trailing)
                Button("Add") { addBonusSignal() }
                    .controlSize(.small)
                    .disabled(newBonusLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            HStack {
                TextField("Section title", text: $section.title)
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addCriterion() {
        let text = newCriterionText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let criterion = RubricCriterion(signal: text, sortOrder: section.criteria.count)
        criterion.section = section
        section.criteria.append(criterion)
        newCriterionText = ""
    }

    private func addBonusSignal() {
        let label = newBonusLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        let signal = RubricBonusSignal(
            label: label,
            expectedAnswer: newBonusExpected,
            bonusValue: newBonusValue,
            sortOrder: section.bonusSignals.count
        )
        signal.section = section
        section.bonusSignals.append(signal)
        newBonusLabel = ""
        newBonusExpected = "yes"
        newBonusValue = 1
    }
}
