import SwiftUI

/// Developer-only editor for the prompts used by `AIIntelligenceService`.
/// Overrides are saved to `AppSupport/GreyEminence/prompts/<key>.md` and take
/// effect on the next AI call. Clearing an override restores the built-in default.
///
/// Placeholders like `{{transcript}}` are substituted at runtime with meeting
/// data — edit the template text around them but keep the placeholders intact
/// or the AI will receive literal `{{transcript}}` in its input.
struct DeveloperPromptEditorView: View {
    @State private var selected: PromptKey = .meetingSystem
    @State private var editorText: String = ""
    @State private var hasOverride: Bool = false
    @State private var isDirty: Bool = false
    @State private var showRestoreAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Prompt Editor")
        .onAppear { load(selected) }
        .onChange(of: selected) { _, newKey in load(newKey) }
        .confirmationDialog(
            "Restore all prompts to defaults?",
            isPresented: $showRestoreAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore All", role: .destructive) {
                PromptStore.shared.clearAll()
                load(selected)
            }
        } message: {
            Text("Every saved override will be removed. The built-in defaults will be used until you edit a prompt again.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Label("Prompt Editor", systemImage: "text.quote")
                .font(.headline)
            Spacer()
            if isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if hasOverride {
                Label("Custom", systemImage: "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.purple)
            } else {
                Text("Default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Restore All Defaults…") {
                showRestoreAllConfirmation = true
            }
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(PromptKey.allCases, selection: $selected) { key in
            HStack(spacing: 6) {
                Text(key.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if PromptStore.shared.override(for: key) != nil {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.purple)
                        .font(.caption)
                }
            }
            .tag(key)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(spacing: 0) {
            // Placeholder legend
            if !selected.placeholders.isEmpty {
                HStack(spacing: 8) {
                    Text("Placeholders:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(selected.placeholders, id: \.self) { placeholder in
                        Text("{{\(placeholder)}}")
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            }

            TextEditor(text: $editorText)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .onChange(of: editorText) { _, _ in
                    isDirty = true
                }

            Divider()
            HStack {
                Button("Restore to Default") {
                    editorText = AIPromptTemplates.defaultText(for: selected)
                    isDirty = true
                }
                .disabled(editorText == AIPromptTemplates.defaultText(for: selected))

                Spacer()

                Button("Revert") {
                    load(selected)
                }
                .disabled(!isDirty)

                Button("Save") {
                    save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func load(_ key: PromptKey) {
        if let override = PromptStore.shared.override(for: key) {
            editorText = override
            hasOverride = true
        } else {
            editorText = AIPromptTemplates.defaultText(for: key)
            hasOverride = false
        }
        isDirty = false
    }

    private func save() {
        let defaultText = AIPromptTemplates.defaultText(for: selected)
        // If the user saved something identical to the default, treat it as a clear.
        if editorText == defaultText {
            PromptStore.shared.set(selected, to: "")
            hasOverride = false
        } else {
            PromptStore.shared.set(selected, to: editorText)
            hasOverride = true
        }
        isDirty = false
    }
}
