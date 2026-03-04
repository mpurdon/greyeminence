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

    var sharedModelContainer: ModelContainer = {
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
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
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
            ContentView(recordingViewModel: recordingViewModel)
                .environment(appEnvironment)
                .onAppear {
                    appEnvironment.configure(
                        modelContext: sharedModelContainer.mainContext
                    )
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1200, height: 800)

        MenuBarExtra("Grey Eminence", systemImage: menuBarIcon) {
            MenuBarView(viewModel: recordingViewModel)
                .modelContainer(sharedModelContainer)
        }

        Settings {
            SettingsView(updater: updaterController.updater)
                .environment(appEnvironment)
                .modelContainer(sharedModelContainer)
        }
    }
}
