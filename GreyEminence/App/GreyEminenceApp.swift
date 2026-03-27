import SwiftUI
import SwiftData
import Sparkle

@main
struct GreyEminenceApp: App {
    @State private var appEnvironment = AppEnvironment()
    @State private var recordingViewModel = RecordingViewModel()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var sharedModelContainer: ModelContainer? = {
        let schema = Schema([
            Meeting.self,
            TranscriptSegment.self,
            ActionItem.self,
            MeetingInsight.self,
            Contact.self,
        ])
        let config = ModelConfiguration(
            "GreyEminence",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        return try? ModelContainer(for: schema, configurations: [config])
    }()

    private var menuBarIcon: String {
        switch recordingViewModel.state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .idle: "record.circle"
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container = sharedModelContainer {
                ContentView(recordingViewModel: recordingViewModel)
                    .environment(appEnvironment)
                    .onAppear {
                        appEnvironment.configure(modelContext: container.mainContext)
                    }
                    .modelContainer(container)
            } else {
                DatabaseErrorView()
            }
        }
        .defaultSize(width: 1200, height: 800)

        MenuBarExtra("Grey Eminence", systemImage: menuBarIcon) {
            if let container = sharedModelContainer {
                MenuBarView(viewModel: recordingViewModel)
                    .modelContainer(container)
            }
        }

        Settings {
            if let container = sharedModelContainer {
                SettingsView(updater: updaterController.updater)
                    .environment(appEnvironment)
                    .modelContainer(container)
            }
        }
    }
}

struct DatabaseErrorView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Could Not Open Database")
                .font(.title2.weight(.semibold))
            Text("Grey Eminence was unable to open its data store. This can happen after a corrupted update.\n\nYou can try deleting the database and restarting, or contact support.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            HStack(spacing: 12) {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                Button("Reset Database…") {
                    resetDatabase()
                }
                .foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 300)
    }

    private func resetDatabase() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dbDir = appSupport.appendingPathComponent("GreyEminence")
        try? fm.removeItem(at: dbDir)
        NSApp.terminate(nil)
    }
}
