import SwiftUI
import SwiftData
import Sparkle

@main
struct GreyEminenceApp: App {
    @State private var appEnvironment = AppEnvironment()
    @State private var recordingViewModel = RecordingViewModel()
    @State private var interviewRecordingViewModel: InterviewRecordingViewModel?
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
            // Interview feature
            Department.self,
            Team.self,
            RoleLevel.self,
            InterviewRole.self,
            Rubric.self,
            RubricSection.self,
            RubricCriterion.self,
            RubricBonusSignal.self,
            Candidate.self,
            Interview.self,
            InterviewSectionScore.self,
            InterviewImpression.self,
            InterviewImpressionTrait.self,
            InterviewBookmark.self,
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
                ContentView(
                    recordingViewModel: recordingViewModel,
                    interviewRecordingViewModel: resolveInterviewVM()
                )
                    .environment(appEnvironment)
                    .onAppear {
                        appEnvironment.configure(modelContext: container.mainContext)
                        seedInterviewDefaults(in: container.mainContext)
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

    @MainActor
    private func resolveInterviewVM() -> InterviewRecordingViewModel {
        if let vm = interviewRecordingViewModel { return vm }
        let vm = InterviewRecordingViewModel(recordingViewModel: recordingViewModel)
        interviewRecordingViewModel = vm
        return vm
    }
}

private func seedInterviewDefaults(in context: ModelContext) {
    // Seed role levels if empty
    let roleLevelDescriptor = FetchDescriptor<RoleLevel>()
    if (try? context.fetchCount(roleLevelDescriptor)) == 0 {
        for (name, category, order) in RoleLevel.defaultLevels {
            context.insert(RoleLevel(name: name, category: category, sortOrder: order))
        }
        try? context.save()
    }

    // Seed impression traits if empty
    let traitDescriptor = FetchDescriptor<InterviewImpressionTrait>()
    if (try? context.fetchCount(traitDescriptor)) == 0 {
        for (name, l1, l2, l3, l4, l5, order) in InterviewImpressionTrait.defaultTraits {
            context.insert(InterviewImpressionTrait(
                name: name, label1: l1, label2: l2, label3: l3, label4: l4, label5: l5, sortOrder: order
            ))
        }
        try? context.save()
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
