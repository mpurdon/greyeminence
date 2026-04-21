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
    @AppStorage("calendarIntegration") private var calendarIntegration = false
    @AppStorage("stalledThresholdDays") private var stalledThresholdDays = 7
    @AppStorage("appFontSize") private var appFontSize = "medium"
    @AppStorage("myContactID") private var myContactIDString = ""
    @AppStorage("embeddingProvider") private var embeddingProviderRaw = EmbeddingProvider.nlEmbedding.rawValue
    @Query(sort: \Contact.name) private var contacts: [Contact]

    @State private var reindexTotal = 0
    @State private var reindexDone = 0
    @State private var isReindexing = false
    @State private var embeddingCount = 0

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
                Picker("Provider", selection: $embeddingProviderRaw) {
                    ForEach(EmbeddingProvider.allCases) { provider in
                        Text(provider.label)
                            .tag(provider.rawValue)
                    }
                }
                if let provider = EmbeddingProvider(rawValue: embeddingProviderRaw), !provider.isAvailable {
                    Text("This provider isn't implemented yet — falling back to on-device for searches.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Indexed items") {
                    Text("\(embeddingCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(isReindexing ? "Reindexing…" : "Reindex all meetings") {
                        Task { await reindexAll() }
                    }
                    .disabled(isReindexing)
                    if isReindexing && reindexTotal > 0 {
                        ProgressView(value: Double(reindexDone), total: Double(reindexTotal))
                            .frame(width: 120)
                        Text("\(reindexDone)/\(reindexTotal)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Semantic search lets the Ask page answer questions like \"what did I want to bring up with Erin in my next 1:1?\" based on your past meetings. Embeddings are stored in a separate database from your meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Semantic Search", systemImage: "sparkles.square.filled.on.square")
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
        .onAppear { embeddingCount = EmbeddingStore.shared?.count() ?? 0 }
    }

    @MainActor
    private func reindexAll() async {
        guard let store = EmbeddingStore.shared else { return }
        let provider = EmbeddingProvider(rawValue: embeddingProviderRaw) ?? .nlEmbedding
        let service = provider.makeService()
        guard service.isAvailable else { return }

        isReindexing = true
        defer {
            isReindexing = false
            embeddingCount = store.count()
        }
        let indexer = EmbeddingIndexer(store: store, service: service)
        await indexer.reindexAll(mainContext: modelContext) { done, total in
            reindexDone = done
            reindexTotal = total
        }
    }
}
