import SwiftUI
import SwiftData
import Sparkle

@main
struct GreyEminenceApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleCoordinator.self) private var lifecycle
    @State private var appEnvironment = AppEnvironment()
    @State private var recordingViewModel = RecordingViewModel()
    @State private var interviewRecordingViewModel: InterviewRecordingViewModel?
    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private let updaterDelegate: SparkleUpdaterDelegate
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Register defaults so non-@AppStorage readers (UserDefaults.standard.bool)
        // see the intended default before the user has touched the toggle.
        UserDefaults.standard.register(defaults: [
            "calendarIntegration": true
        ])
        AIModelCatalog.migrateStoredDefaults()

        let delegate = SparkleUpdaterDelegate()
        self.updaterDelegate = delegate
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        // Force an immediate appcast fetch on every launch. Sparkle's default
        // schedule waits "a few minutes" after launch for its first check and
        // then defers further checks by `updateCheckInterval` (24 h) — so a
        // user who relaunches inside that 24 h window may never see an
        // auto-prompt. If a launch-time bug ships, that's the difference
        // between the user getting rescued and the app being a doorstop.
        // checkForUpdatesInBackground is silent on "up to date" and only
        // surfaces UI when an update is genuinely available.
        Self.kickOffStartupUpdateCheck(controller: updaterController)
    }

    private static func kickOffStartupUpdateCheck(controller: SPUStandardUpdaterController) {
        #if DEBUG
        // Never in a Debug build: it lives in DerivedData and is whatever was
        // last compiled, so "updating" it installs the published release over
        // the working copy. See SparkleUpdaterDelegate.updaterMayCheck — this
        // is the belt to its braces, since that gate is only consulted when a
        // check actually fires, hours later.
        controller.updater.automaticallyChecksForUpdates = false
        LogManager.send("Automatic update checks disabled (Debug build)", category: .update)
        #else
        DispatchQueue.main.async {
            controller.updater.checkForUpdatesInBackground()
        }
        #endif
    }

    var sharedModelContainer: ModelContainer? = {
        // Versioned schema — see SchemaVersions.swift. We deliberately omit
        // an explicit migration plan because SwiftData on macOS 26 throws
        // an Objective-C exception from `NSLightweightMigrationStage.init`
        // when the V1→V2 stage is provided directly (rdar-style toolchain
        // bug — the exception bypasses Swift's `try?` and crashes the app
        // before the DatabaseErrorView recovery UI can render).
        //
        // Without an explicit plan, SwiftData auto-migrates additive
        // changes (new entities, new optional relationships) — which is
        // exactly what V1→V2 is. Migration stages still exist in the plan
        // type for documentation and for future non-additive changes that
        // genuinely need custom handlers.
        let schema = Schema(versionedSchema: SchemaV19.self)
        let config = ModelConfiguration(
            "GreyEminence",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        return try? ModelContainer(
            for: schema,
            configurations: [config]
        )
    }()

    private var menuBarIcon: String {
        switch recordingViewModel.state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .idle: "record.circle"
        }
    }

    @AppStorage("appFontSize") private var appFontSize = "medium"

    private var dynamicTypeSize: DynamicTypeSize {
        switch appFontSize {
        case "xSmall": .xSmall
        case "small": .small
        case "large": .large
        case "xLarge": .xLarge
        default: .medium
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container = sharedModelContainer {
                ContentView(
                    recordingViewModel: recordingViewModel,
                    interviewRecordingViewModel: resolveInterviewVM()
                )
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(appEnvironment)
                    .onAppear {
                        appEnvironment.configure(modelContext: container.mainContext)
                        UsageRecorder.shared.configure(container: container)
                        seedInterviewDefaults(in: container.mainContext)
                        // Off the main thread and visible. It copies the
                        // whole store plus its write-ahead log — a hundred
                        // megabytes and more as the library grows — and it was
                        // doing that inline in `onAppear`, so the first launch
                        // of each day froze on a file copy with nothing on
                        // screen to say why.
                        if let storeURL = container.configurations.first?.url {
                            Task { @MainActor in
                                await TransientActivityCoordinator.shared.runAsync("Backing up your meetings…") {
                                    await Task.detached(priority: .utility) {
                                        StoreBackupService.runIfNeeded(storeURL: storeURL)
                                    }.value
                                }
                            }
                        }
                        ReProcessingQueue.shared.configure(
                            modelContainer: container,
                            recordingViewModel: recordingViewModel
                        )
                        EmbeddingBackfillService.scheduleAtLaunch(
                            mainContext: container.mainContext
                        )
                        lifecycle.bind(
                            recordingViewModel: recordingViewModel,
                            modelContextProvider: { container.mainContext }
                        )
                        updaterDelegate.isRecordingActive = { [recordingViewModel] in
                            recordingViewModel.state != .idle
                        }
                    }
                    .modelContainer(container)
            } else {
                DatabaseErrorView()
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.checkForUpdates(nil)
                }
            }
            CommandGroup(replacing: .help) {
                HelpMenuCommands()
            }
        }

        // Help docs viewer — value-driven so the same window scene serves
        // README / CONTRIBUTING / CHANGELOG. Help-menu commands open it
        // via openWindow(id:value:).
        WindowGroup("Help", id: "help-doc", for: HelpDoc.self) { $doc in
            if let doc {
                HelpDocsView(doc: doc)
            }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Grey Eminence", systemImage: menuBarIcon) {
            if let container = sharedModelContainer {
                MenuBarView(viewModel: recordingViewModel)
                    .modelContainer(container)
            }
        }

        Settings {
            if let container = sharedModelContainer {
                SettingsView(updater: updaterController.updater)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
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

@MainActor
private func seedInterviewDefaults(in context: ModelContext) {
    seedAIAssistedEngineeringRubricIfMissing(in: context)
    seedSystemDesignRubricIfMissing(in: context)
    // Templates seed runs after rubric seeders so the fuzzy name match
    // can hook the freshly-seeded rubrics. Idempotent — only fires when
    // the template table is empty.
    InterviewTemplateSeeder.seedIfEmpty(in: context)

    let seedVersion = UserDefaults.standard.integer(forKey: "interviewSeedVersion")
    guard seedVersion < 4 else { return }

    // Seed role levels if empty
    let roleLevelDescriptor = FetchDescriptor<RoleLevel>()
    if (try? context.fetchCount(roleLevelDescriptor)) == 0 {
        for (name, category, order) in RoleLevel.defaultLevels {
            context.insert(RoleLevel(name: name, category: category, sortOrder: order))
        }
        PersistenceGate.save(context, site: "seedInterviewDefaults/roleLevels")
    }

    // Seed impression traits if empty
    let traitDescriptor = FetchDescriptor<InterviewImpressionTrait>()
    if (try? context.fetchCount(traitDescriptor)) == 0 {
        for (name, l1, l2, l3, l4, l5, order) in InterviewImpressionTrait.defaultTraits {
            context.insert(InterviewImpressionTrait(
                name: name, label1: l1, label2: l2, label3: l3, label4: l4, label5: l5, sortOrder: order
            ))
        }
        PersistenceGate.save(context, site: "seedInterviewDefaults/impressionTraits")
    }

    // One-time repair: wipe broken org seed data and re-seed properly
    // Unlink candidates from roles (keep the candidates)
    for candidate in (try? context.fetch(FetchDescriptor<Candidate>())) ?? [] {
        candidate.role = nil
    }
    // Delete interview-related objects that reference roles/rubrics
    for item in (try? context.fetch(FetchDescriptor<InterviewSectionScore>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<InterviewImpression>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<InterviewBookmark>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<Interview>())) ?? [] { context.delete(item) }
    // Delete org seed data in reverse-dependency order
    for item in (try? context.fetch(FetchDescriptor<RubricBonusSignal>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<RubricCriterion>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<RubricSection>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<Rubric>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<InterviewRole>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<Team>())) ?? [] { context.delete(item) }
    for item in (try? context.fetch(FetchDescriptor<Department>())) ?? [] { context.delete(item) }
    PersistenceGate.save(context, site: "seedInterviewDefaults/wipeOrg")

    seedOrganizationAndRubrics(in: context)
    UserDefaults.standard.set(4, forKey: "interviewSeedVersion")
}

// MARK: - Organization & Rubric Seed Data

private func seedOrganizationAndRubrics(in context: ModelContext) {
    // Fetch role levels for linking
    let levelDescriptor = FetchDescriptor<RoleLevel>(sortBy: [SortDescriptor(\RoleLevel.sortOrder)])
    let levels = (try? context.fetch(levelDescriptor)) ?? []
    func level(_ name: String) -> RoleLevel? { levels.first { $0.name == name } }

    // --- Departments & Teams ---

    func insertTeam(_ name: String, sortOrder: Int, department: Department) -> Team {
        let t = Team(name: name, sortOrder: sortOrder)
        context.insert(t)
        t.department = department
        return t
    }

    let appEng = Department(name: "Application Engineering", sortOrder: 0)
    context.insert(appEng)
    let ipp = insertTeam("IPP", sortOrder: 0, department: appEng)
    _ = insertTeam("Nexus", sortOrder: 1, department: appEng)
    _ = insertTeam("Atomic Forms", sortOrder: 2, department: appEng)
    _ = insertTeam("OLP", sortOrder: 3, department: appEng)
    _ = insertTeam("Milo - Medical", sortOrder: 4, department: appEng)
    _ = insertTeam("Milo - Disability", sortOrder: 5, department: appEng)
    _ = insertTeam("Milo - Outreach Legal", sortOrder: 6, department: appEng)
    _ = insertTeam("Benefit Karma", sortOrder: 7, department: appEng)

    let dataSvc = Department(name: "Data Services", sortOrder: 1)
    context.insert(dataSvc)
    let dataScience = insertTeam("Data Science", sortOrder: 0, department: dataSvc)
    let dataEng = insertTeam("Data Engineering", sortOrder: 1, department: dataSvc)

    let platEng = Department(name: "Platform Engineering", sortOrder: 2)
    context.insert(platEng)
    let platform = insertTeam("Platform", sortOrder: 0, department: platEng)
    _ = insertTeam("Support", sortOrder: 1, department: platEng)

    PersistenceGate.save(context, site: "seedOrganizationAndRubrics/departments")

    // --- Roles ---

    let roleEngII_IPP = InterviewRole(level: level("Engineer II"), department: appEng, team: ipp)
    context.insert(roleEngII_IPP)
    let roleEngIII_IPP = InterviewRole(level: level("Engineer III"), department: appEng, team: ipp)
    context.insert(roleEngIII_IPP)
    let roleSrFE = InterviewRole(level: level("Engineer III"), department: platEng, team: platform, customTitle: "Senior Frontend Engineer")
    context.insert(roleSrFE)
    let roleEM_AppEng = InterviewRole(level: level("Engineering Manager I"), department: appEng)
    context.insert(roleEM_AppEng)
    let roleDataSci = InterviewRole(level: level("Engineer II"), department: dataSvc, team: dataScience, customTitle: "Data Scientist")
    context.insert(roleDataSci)
    let roleDataEng = InterviewRole(level: level("Engineer II"), department: dataSvc, team: dataEng, customTitle: "Data Engineer")
    context.insert(roleDataEng)

    // --- Rubrics ---

    // 1. General Engineering Interview (System Design + Coding)
    let generalRubric = Rubric(name: "General Engineering Interview")
    generalRubric.role = roleEngII_IPP
    context.insert(generalRubric)
    seedGeneralEngineeringRubric(generalRubric, in: context)

    // 2. Senior Engineering Interview (same structure, for Eng III)
    let seniorRubric = Rubric(name: "Senior Engineering Interview")
    seniorRubric.role = roleEngIII_IPP
    context.insert(seniorRubric)
    seedGeneralEngineeringRubric(seniorRubric, in: context)

    // 3. Senior Frontend Engineer Interview
    let feRubric = Rubric(name: "Senior Frontend Engineer Interview")
    feRubric.role = roleSrFE
    context.insert(feRubric)
    seedFrontendRubric(feRubric, in: context)

    // 4. Engineering Manager Interview
    let emRubric = Rubric(name: "Engineering Manager Interview")
    emRubric.role = roleEM_AppEng
    context.insert(emRubric)
    seedEngineeringManagerRubric(emRubric, in: context)

    // 5. Data Team Interview (SQL + Python)
    let dataRubric = Rubric(name: "Data Team Interview")
    dataRubric.role = roleDataSci
    context.insert(dataRubric)
    seedDataTeamRubric(dataRubric, in: context)

    PersistenceGate.save(context, site: "seedOrganizationAndRubrics/final")
}

// MARK: - Idempotent rubric seeders

/// Insert a named rubric if no rubric with that name exists yet. Wraps
/// the activity-coordinator + persistence-save + log-send dance so each
/// individual seed function only has to declare its name and how to
/// populate the sections.
@MainActor
private func seedRubricIfMissing(
    named rubricName: String,
    in context: ModelContext,
    build: (Rubric, ModelContext) -> Void
) {
    let existing = (try? context.fetch(FetchDescriptor<Rubric>())) ?? []
    if existing.contains(where: { $0.name == rubricName }) { return }

    TransientActivityCoordinator.shared.run("Seeding \"\(rubricName)\" rubric…") {
        let rubric = Rubric(name: rubricName)
        context.insert(rubric)
        build(rubric, context)
        PersistenceGate.save(context, site: "seedRubricIfMissing/\(rubricName)")
        LogManager.send("Seeded \"\(rubricName)\" rubric", category: .general)
    }
}

@MainActor
private func seedSystemDesignRubricIfMissing(in context: ModelContext) {
    seedRubricIfMissing(named: "System Design", in: context, build: seedSystemDesignRubric)
}

private func seedSystemDesignRubric(_ rubric: Rubric, in context: ModelContext) {
    // 1. Requirements & Scoping
    let requirements = RubricSection(
        title: "Requirements & Scoping",
        description: "Whether the candidate clarifies what they're building before they start drawing.",
        sortOrder: 0,
        weight: 15
    )
    requirements.rubric = rubric
    context.insert(requirements)
    for (i, signal) in [
        "Clarifies functional requirements before designing (who uses this, what do they need)",
        "Surfaces non-functional requirements (scale, latency, availability, consistency)",
        "Identifies success metrics — how do we know this design works",
        "Probes constraints (team size, timeline, existing infrastructure, budget)",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = requirements
    }
    for (i, (label, expected, value)) in [
        ("Asked clarifying questions before drawing anything", "yes", 2),
        ("Did back-of-envelope capacity math (QPS, storage, bandwidth)", "yes", 1),
        ("Jumped straight to ERD without discussion", "yes", -2),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = requirements
    }

    // 2. Architecture
    let architecture = RubricSection(
        title: "Architecture",
        description: "Whether the design is incremental, well-decomposed, and justified at each level.",
        sortOrder: 1,
        weight: 25
    )
    architecture.rubric = rubric
    context.insert(architecture)
    for (i, signal) in [
        "Started simple, added complexity (incremental design rather than big-bang)",
        "Component decomposition with clear responsibilities and boundaries",
        "API contracts between components are sketched — not just boxes-and-arrows",
        "Async vs synchronous flows justified with reasoning",
        "User experience considered from the front-end backwards, not just data models",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = architecture
    }
    for (i, (label, expected, value)) in [
        ("Started high-level, then drilled into details", "yes", 1),
        ("Cargo-culted a buzzword without justifying it (e.g., \"we'll use Kafka\")", "yes", -1),
        ("Cron job mentioned as the answer to a real-time problem", "yes", -1),
        ("Surveys and Calls are the Same — collapsed two distinct flows into one when they shouldn't", "yes", 1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = architecture
    }

    // 3. Data
    let data = RubricSection(
        title: "Data",
        description: "Whether storage and data flow choices fit the access patterns rather than reaching for the candidate's favorite tool.",
        sortOrder: 2,
        weight: 20
    )
    data.rubric = rubric
    context.insert(data)
    for (i, signal) in [
        "Data model fits the access patterns described in requirements",
        "Storage choice (SQL / NoSQL / cache / blob / search) justified, not defaulted",
        "Indexing or query strategy explained for the hot paths",
        "Data lifecycle considered (retention, archival, deletion, GDPR/PII handling)",
        "Generating recommendations / derived data — pipeline and freshness named",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = data
    }
    for (i, (label, expected, value)) in [
        ("Named specific access patterns before picking a database", "yes", 2),
        ("Defaulted to Postgres / Mongo / Redis without justifying", "yes", -1),
        ("Glossed over data deletion / privacy", "yes", -1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = data
    }

    // 4. Scalability & Reliability
    let scaling = RubricSection(
        title: "Scalability & Reliability",
        description: "Whether the design has a credible scaling story and the candidate can name where it will break first.",
        sortOrder: 3,
        weight: 20
    )
    scaling.rubric = rubric
    context.insert(scaling)
    for (i, signal) in [
        "Horizontal scaling path identified — not just \"add more servers\"",
        "Bottleneck analysis — where will this break first as load grows",
        "Failure modes named with concrete mitigations (retries, circuit breakers, fallbacks)",
        "Consistency model articulated (strong / eventual / read-your-writes) and justified",
        "Caching strategy with explicit invalidation story, not just \"add a cache\"",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = scaling
    }
    for (i, (label, expected, value)) in [
        ("Named a specific failure mode and its mitigation", "yes", 2),
        ("Acknowledged a CAP-style trade-off explicitly", "yes", 1),
        ("Said \"just add a cache\" without invalidation story", "yes", -1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = scaling
    }

    // 5. Operations & Trade-offs
    let ops = RubricSection(
        title: "Operations & Trade-offs",
        description: "Whether the candidate thinks about running the system, not just shipping it, and articulates trade-offs honestly.",
        sortOrder: 4,
        weight: 20
    )
    ops.rubric = rubric
    context.insert(ops)
    for (i, signal) in [
        "Observability story — logs, metrics, traces, alerts — at least sketched",
        "Security & privacy considered (authn, authz, data-in-transit, data-at-rest)",
        "Compliance addressed where relevant (PII, GDPR, HIPAA depending on domain)",
        "Cost awareness — has a sense of what this design costs to run at the scale they targeted",
        "Trade-offs articulated with reasoning, not waved away (\"we'd pick X over Y because…\")",
        "Iterates well on follow-up pressure (\"what if scale doubles\", \"what if a region fails\")",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = ops
    }
    for (i, (label, expected, value)) in [
        ("Mentioned monitoring / alerting unprompted", "yes", 1),
        ("Named a real cost trade-off (\"this is cheaper but less consistent\")", "yes", 2),
        ("Treated security as an afterthought", "yes", -2),
        ("Doubled-down on a wrong choice when challenged instead of revisiting", "yes", -1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = ops
    }
}

// MARK: - AI-Assisted Engineering Rubric (idempotent)

/// Adds the "AI-Assisted Engineering" rubric if it doesn't already exist.
/// Runs every launch as a no-op when the rubric is present, so users on
/// older builds get it on next start without losing any other interview
/// data. Unattached to a specific role — the phase planner shows it
/// alongside role-scoped rubrics so users can compose it with System
/// Design, Coding, etc. for any role.
@MainActor
private func seedAIAssistedEngineeringRubricIfMissing(in context: ModelContext) {
    seedRubricIfMissing(named: "AI-Assisted Engineering", in: context, build: seedAIAssistedEngineeringRubric)
}

private func seedAIAssistedEngineeringRubric(_ rubric: Rubric, in context: ModelContext) {
    // Section 1: Tool Fluency — does the candidate use AI tools as a
    // multiplier or as a crutch?
    let fluency = RubricSection(
        title: "Tool Fluency",
        description: "How effectively the candidate wields AI assistance: knowing when to invoke it, when not to, and how to prompt iteratively.",
        sortOrder: 0,
        weight: 25
    )
    fluency.rubric = rubric
    context.insert(fluency)
    for (i, signal) in [
        "Reaches for AI on the right kinds of tasks (scaffolding, search, refactor) and avoids it on tasks where deep understanding matters",
        "Iterates on prompts rather than one-shotting; refines context instead of accepting a confident-but-wrong first reply",
        "Uses AI to expand their reach (unfamiliar APIs, boilerplate) without using it to skip thinking",
        "Articulates clearly *why* they reached for AI for this particular task",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = fluency
    }
    for (i, (label, expected, value)) in [
        ("Asked AI for the part they understood least", "yes", 1),
        ("Pasted code without reading it", "yes", -2),
        ("Started by writing the prompt before opening the editor", "yes", -1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = fluency
    }

    // Section 2: Critical Review of AI Output
    let review = RubricSection(
        title: "Code Review of AI Output",
        description: "Whether the candidate treats AI output as a draft to review or as a final answer to accept.",
        sortOrder: 1,
        weight: 30
    )
    review.rubric = rubric
    context.insert(review)
    for (i, signal) in [
        "Catches hallucinated APIs, wrong type signatures, or fabricated docs in AI output",
        "Pushes back on confident-but-wrong code rather than deferring to it",
        "Spots subtle bugs (off-by-one, edge cases, error handling) the AI missed",
        "Recognizes when the AI took a fundamentally wrong approach and abandons that path",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = review
    }
    for (i, (label, expected, value)) in [
        ("Caught a hallucinated API in the AI's output", "yes", 2),
        ("Accepted obviously wrong code without comment", "yes", -2),
        ("Re-prompted instead of accepting a flawed answer", "yes", 1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = review
    }

    // Section 3: Decomposition for AI
    let decomp = RubricSection(
        title: "Decomposition for AI",
        description: "Whether the candidate breaks problems into AI-tractable pieces and provides the context the AI needs.",
        sortOrder: 2,
        weight: 20
    )
    decomp.rubric = rubric
    context.insert(decomp)
    for (i, signal) in [
        "Breaks large tasks into chunks the AI can solve well, rather than asking it to do too much at once",
        "Provides the right context (relevant files, constraints, examples) instead of expecting the AI to guess",
        "Knows the limits of context windows and works around them",
        "Recognizes when a task is too vague for AI and refines the spec first",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = decomp
    }

    // Section 4: Verification Discipline
    let verify = RubricSection(
        title: "Verification Discipline",
        description: "Whether the candidate verifies AI output before claiming the task is done.",
        sortOrder: 3,
        weight: 25
    )
    verify.rubric = rubric
    context.insert(verify)
    for (i, signal) in [
        "Runs and tests AI output before declaring the task complete",
        "Doesn't let \"looks right\" stand in for \"is right\" — actively probes for failure modes",
        "Writes a test or asserts behavior on the boundary, especially for AI-generated logic",
        "Owns AI mistakes when they ship — doesn't blame the tool",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = verify
    }
    for (i, (label, expected, value)) in [
        ("Wrote a test before accepting the AI's fix", "yes", 2),
        ("Ran the code immediately after AI generated it", "yes", 1),
        ("Said \"looks good\" without running it", "yes", -2),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = verify
    }
}

// MARK: - General Engineering Rubric (System Design + Coding Exercise)

private func seedGeneralEngineeringRubric(_ rubric: Rubric, in context: ModelContext) {
    // System Design section
    let sd = RubricSection(title: "System Design", description: "Evaluate the candidate's ability to design a system from scratch, starting simple and adding complexity.", sortOrder: 0, weight: 50)
    sd.rubric = rubric
    context.insert(sd)

    for (i, signal) in [
        "Started simple added complexity",
        "Data Handling",
        "Generating Recommendations",
        "Scalability & Performance",
        "Compliance & Privacy",
        "User Experience",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = sd
    }

    // System Design Bonus Signals
    for (i, (label, expected, value)) in [
        ("Users First", "yes", 1),
        ("Too detailed non-functional", "yes", -1),
        ("High-level not ERD", "yes", 1),
        ("Cron Job Mentioned", "yes", -1),
        ("Surveys and Calls are the Same", "yes", 1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = sd
    }

    // Coding Exercise section
    let ce = RubricSection(title: "Coding Exercise", description: "Evaluate the candidate's coding ability, organization, problem solving, and testing.", sortOrder: 1, weight: 50)
    ce.rubric = rubric
    context.insert(ce)

    for (i, signal) in [
        "Determining shape of API Data",
        "Organization",
        "Code Quality",
        "Problem Solving",
        "Testing",
        "Completed",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = ce
    }

    // Coding Exercise Bonus Signals
    for (i, (label, expected, value)) in [
        ("File saving reminders", "no", -1),
        ("Copied a sample as a scratch", "yes", 1),
        ("Ran the code immediately", "yes", 2),
        ("Used the example files", "yes", -1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = ce
    }
}

// MARK: - Frontend Engineer Rubric

private func seedFrontendRubric(_ rubric: Rubric, in context: ModelContext) {
    let ce = RubricSection(title: "Coding Exercise", description: "Evaluate React/CSS coding ability, component structure, and problem solving.", sortOrder: 0, weight: 100)
    ce.rubric = rubric
    context.insert(ce)

    let criteria: [(String, String?)] = [
        ("Organization", "Is the component structure logical and modular? Are files and folders named appropriately? Does the code follow a predictable and scalable pattern?"),
        ("Code Quality - React", "Is the code clean, readable, and idiomatic? Are naming conventions clear and consistent? Are React hooks used correctly and idiomatically?"),
        ("Code Quality - CSS", "Are styles clean, organized, and modular? Does the CSS separate concerns between layout and visual styling? Are flex/grid layouts used appropriately?"),
        ("Problem Solving", "Did the candidate ask questions if they didn't understand? Did they use external resources effectively? How frequently did they need to be bailed out?"),
        ("Testing", "Are there unit or integration tests? Do tests verify correct timing, transitions, and orientation rendering?"),
        ("Completed", "Does the component meet all core requirements? Are all major parts of the challenge addressed?"),
    ]

    for (i, (signal, notes)) in criteria.enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i, evaluationNotes: notes)
        c.section = ce
    }

    for (i, (label, expected, value)) in [
        ("File saving reminders", "no", -1),
        ("Created a Light component", "yes", 2),
        ("Ran the code immediately", "yes", 2),
        ("Lights off is a dim effect", "yes", 1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = ce
    }
}

// MARK: - Engineering Manager Rubric

private func seedEngineeringManagerRubric(_ rubric: Rubric, in context: ModelContext) {
    let sd = RubricSection(title: "System Design", description: "Evaluate high-level system design thinking, trade-off awareness, and ability to communicate technical decisions.", sortOrder: 0, weight: 50)
    sd.rubric = rubric
    context.insert(sd)

    for (i, signal) in [
        "Started simple added complexity",
        "Data Handling",
        "Generating Recommendations",
        "Scalability & Performance",
        "Compliance & Privacy",
        "User Experience",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = sd
    }

    for (i, (label, expected, value)) in [
        ("Users First", "yes", 1),
        ("Too detailed non-functional", "yes", -1),
        ("High-level not ERD", "yes", 1),
        ("Cron Job Mentioned", "yes", -1),
        ("Surveys and Calls are the Same", "yes", 1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = sd
    }

    let cr = RubricSection(title: "Code Review Exercise", description: "Evaluate the candidate's ability to review code, identify issues, and suggest improvements.", sortOrder: 1, weight: 50)
    cr.rubric = rubric
    context.insert(cr)

    for (i, signal) in [
        "Determining shape of API Data",
        "Organization",
        "Code Quality",
        "Problem Solving",
        "Testing",
        "Completed",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = cr
    }

    for (i, (label, expected, value)) in [
        ("File saving reminders", "no", -1),
        ("Copied a sample as a scratch", "yes", 1),
        ("Ran the code immediately", "yes", 2),
        ("Used the example files", "yes", -1),
    ].enumerated() {
        let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
        b.section = cr
    }
}

// MARK: - Data Team Rubric (SQL + Python)

private func seedDataTeamRubric(_ rubric: Rubric, in context: ModelContext) {
    let sql = RubricSection(title: "SQL Coding Exercises", description: "Evaluate SQL querying ability, data modeling understanding, and problem solving.", sortOrder: 0, weight: 50)
    sql.rubric = rubric
    context.insert(sql)

    for (i, signal) in [
        "Determining shape of API Data",
        "Organization",
        "Code Quality",
        "Problem Solving",
        "Testing",
        "Completed",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = sql
    }

    let py = RubricSection(title: "Python Coding Exercise", description: "Evaluate Python coding ability, data manipulation, and testing practices.", sortOrder: 1, weight: 50)
    py.rubric = rubric
    context.insert(py)

    for (i, signal) in [
        "Determining shape of API Data",
        "Organization",
        "Code Quality",
        "Problem Solving",
        "Testing",
        "Completed",
    ].enumerated() {
        let c = RubricCriterion(signal: signal, sortOrder: i)
        c.section = py
    }

    // Shared bonus signals for both coding sections
    for section in [sql, py] {
        for (i, (label, expected, value)) in [
            ("File saving reminders", "no", -1),
            ("Copied a sample as a scratch", "yes", 1),
            ("Ran the code immediately", "yes", 2),
            ("Used the example files", "yes", -1),
        ].enumerated() {
            let b = RubricBonusSignal(label: label, expectedAnswer: expected, bonusValue: value, sortOrder: i)
            b.section = section
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
