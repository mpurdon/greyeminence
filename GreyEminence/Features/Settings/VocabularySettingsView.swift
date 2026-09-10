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

                Text("Custom vocabulary helps the transcription engine recognise specialised terms, names, and jargon, and tells the mis-hearing repair pass what to expect. A term's kind says where it can appear — a person, a document type, a system — and its boost says how likely it is: leave a name you rarely mention at 1 or 2 so it is never guessed at.")
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

                            Picker("", selection: Binding(
                                get: { term.kind },
                                set: { vocabularyManager.updateTerm(id: term.id, kind: $0) }
                            )) {
                                ForEach(TermKind.allCases) { kind in
                                    Text(kind.label).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .help("What this term is. The repair pass uses it to decide where the term can appear.")

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
