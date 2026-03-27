import SwiftUI
import Sparkle

struct GeneralSettingsView: View {
    var updater: SPUUpdater?
    @AppStorage("autoStartRecording") private var autoStart = false
    @AppStorage("showMenuBarIcon") private var showMenuBar = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("calendarIntegration") private var calendarIntegration = false
    @AppStorage("stalledThresholdDays") private var stalledThresholdDays = 7

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Show menu bar icon", isOn: $showMenuBar)
            } header: {
                Label("Startup", systemImage: "power")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                Toggle("Auto-start recording when meeting app detected", isOn: $autoStart)
                Toggle("Auto-detect calendar events", isOn: $calendarIntegration)
            } header: {
                Label("Recording", systemImage: "record.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                Stepper(
                    "Stalled threshold: \(stalledThresholdDays) day\(stalledThresholdDays == 1 ? "" : "s")",
                    value: $stalledThresholdDays,
                    in: 1...90
                )
                Text("Action items older than this are flagged as stalled in the Tasks view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Tasks", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                }
                Button("Check for Updates") {
                    updater?.checkForUpdates()
                }
                .disabled(updater == nil)
            } header: {
                Label("About", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }
}
