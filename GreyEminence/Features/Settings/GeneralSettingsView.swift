import SwiftUI
import SwiftData
import Sparkle

struct GeneralSettingsView: View {
    var updater: SPUUpdater?
    @ObservedObject private var updateViewModel: CheckForUpdatesViewModel
    @Environment(\.modelContext) private var modelContext
    @AppStorage("autoStartRecording") private var autoStart = false
    @AppStorage("showMenuBarIcon") private var showMenuBar = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("stalledThresholdDays") private var stalledThresholdDays = 7
    @AppStorage("appFontSize") private var appFontSize = "medium"
    @AppStorage("myContactID") private var myContactIDString = ""
    /// 0 = unlimited (default). >0 means delete audio for any completed
    /// meeting older than that many days. Transcripts always stay.
    @AppStorage("recordingRetentionDays") private var recordingRetentionDays = 0
    @Query(sort: \Contact.name) private var contacts: [Contact]
    @Query private var allMeetings: [Meeting]
    @State private var lastRetentionResult: String?

    init(updater: SPUUpdater?) {
        self.updater = updater
        if let updater {
            self._updateViewModel = ObservedObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
        } else {
            self._updateViewModel = ObservedObject(wrappedValue: CheckForUpdatesViewModel())
        }
    }

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
                Text("Also stops a recording — started by you or automatically — 20 seconds after the call app it was recording releases the microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle(
                    "Auto-delete audio after a retention period",
                    isOn: Binding(
                        get: { recordingRetentionDays > 0 },
                        set: { recordingRetentionDays = $0 ? max(recordingRetentionDays, 30) : 0 }
                    )
                )
                if recordingRetentionDays > 0 {
                    Stepper(
                        "Keep audio for \(recordingRetentionDays) day\(recordingRetentionDays == 1 ? "" : "s")",
                        value: $recordingRetentionDays,
                        in: 1...365
                    )
                }
                Text("Transcripts and meeting rows always stay. Only the (large) audio files are removed for completed meetings older than the threshold. Sweep runs at app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Run cleanup now") { runRetentionNow() }
                        .controlSize(.small)
                        .disabled(recordingRetentionDays == 0)
                    if let last = lastRetentionResult {
                        Text(last)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                    HStack(spacing: 8) {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        if let lastCheck = updateViewModel.lastUpdateCheckDate {
                            Text("Last checked \(lastCheck, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Check for Updates") {
                    updater?.checkForUpdates()
                }
                .disabled(!updateViewModel.canCheckForUpdates)
            } header: {
                Label("About", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }

    private func runRetentionNow() {
        guard recordingRetentionDays > 0 else { return }
        var ages: [UUID: Date] = [:]
        for m in allMeetings where m.status == .completed {
            ages[m.id] = m.date.addingTimeInterval(m.duration)
        }
        let result = StorageManager.shared.purgeRecordingsOlderThan(
            days: recordingRetentionDays,
            meetingFinishedAt: ages
        )
        if result.count > 0 {
            let mb = Double(result.bytes) / 1_048_576
            lastRetentionResult = "Removed \(result.count) recording(s), freed \(String(format: "%.1f", mb)) MB"
        } else {
            lastRetentionResult = "Nothing to remove."
        }
    }
}
