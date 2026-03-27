import SwiftUI

struct DeveloperSettingsView: View {
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false

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
        }
        .formStyle(.grouped)
        .navigationTitle("Developer")
    }
}
