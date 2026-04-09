import SwiftUI

struct DeveloperSettingsView: View {
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false
    @State private var showPromptEditor = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable developer tools", isOn: $developerToolsEnabled)
                Text("Shows the Activity Log in the sidebar and deduplication debug tools in the transcript view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Developer Tools", systemImage: "hammer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            if developerToolsEnabled {
                Section {
                    Button {
                        showPromptEditor = true
                    } label: {
                        HStack {
                            Label("Edit AI Prompts", systemImage: "text.quote")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Text("Override the prompts sent to Claude for meeting analysis. Changes take effect on the next AI call. Clearing an override restores the built-in default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("AI Prompts", systemImage: "text.quote")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Developer")
        .sheet(isPresented: $showPromptEditor) {
            NavigationStack {
                DeveloperPromptEditorView()
                    .frame(minWidth: 780, minHeight: 560)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showPromptEditor = false
                            }
                        }
                    }
            }
        }
    }
}
