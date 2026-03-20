import SwiftUI

struct VocabularySettingsView: View {
    @State private var vocabularyManager = VocabularyManager()
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add word or phrase...", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTerm() }

                    Button("Add") { addTerm() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Custom vocabulary helps the transcription engine recognize specialized terms, names, and jargon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Custom Vocabulary", systemImage: "textformat.abc")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            if !vocabularyManager.terms.isEmpty {
                Section {
                    ForEach(vocabularyManager.terms) { term in
                        HStack {
                            Text(term.text)
                                .font(.body)

                            Spacer()

                            HStack(spacing: 4) {
                                Text("Boost:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(
                                    value: Binding(
                                        get: { term.boost },
                                        set: { vocabularyManager.updateTerm(id: term.id, boost: $0) }
                                    ),
                                    in: 1...20,
                                    step: 1
                                )
                                .frame(width: 100)
                                Text("\(Int(term.boost))")
                                    .font(.caption)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                            }

                            Button {
                                vocabularyManager.removeTerm(id: term.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Label("Terms (\(vocabularyManager.terms.count))", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addTerm() {
        vocabularyManager.addTerm(newTerm)
        newTerm = ""
    }
}
