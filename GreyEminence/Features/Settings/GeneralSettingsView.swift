import SwiftUI
import SwiftData
import Sparkle

struct GeneralSettingsView: View {
    var updater: SPUUpdater?
    @Environment(\.modelContext) private var modelContext
    @AppStorage("autoStartRecording") private var autoStart = false
    @AppStorage("showMenuBarIcon") private var showMenuBar = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("calendarIntegration") private var calendarIntegration = false
    @AppStorage("stalledThresholdDays") private var stalledThresholdDays = 7
    @AppStorage("appFontSize") private var appFontSize = "medium"
    @AppStorage("myContactID") private var myContactIDString = ""
    @Query(sort: \Contact.name) private var contacts: [Contact]

    private var myContact: Contact? {
        guard let id = UUID(uuidString: myContactIDString) else { return nil }
        return contacts.first { $0.id == id }
    }

    var body: some View {
        Form {
            Section {
                Picker("My Profile", selection: $myContactIDString) {
                    Text("Not set").tag("")
                    ForEach(contacts.filter { !$0.isArchived }) { contact in
                        Text(contact.name).tag(contact.id.uuidString)
                    }
                }
                if let contact = myContact {
                    HStack(spacing: 6) {
                        Text(contact.initials)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(contact.avatarColor.gradient, in: Circle())
                        Text(contact.name)
                            .font(.caption)
                        if let email = contact.email {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("This identifies you in meetings and interviews. The \"Me\" speaker label will be attributed to this contact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("My Profile", systemImage: "person.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

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
                Picker("Text Size", selection: $appFontSize) {
                    Text("Extra Small").tag("xSmall")
                    Text("Small").tag("small")
                    Text("Medium (Default)").tag("medium")
                    Text("Large").tag("large")
                    Text("Extra Large").tag("xLarge")
                }
            } header: {
                Label("Appearance", systemImage: "textformat.size")
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
