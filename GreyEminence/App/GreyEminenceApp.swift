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
            InterviewNote.self,
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

    // One-time repair: wipe broken org seed data and re-seed properly
    let seedVersion = UserDefaults.standard.integer(forKey: "interviewSeedVersion")
    if seedVersion < 4 {
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
        try? context.save()

        seedOrganizationAndRubrics(in: context)
        UserDefaults.standard.set(4, forKey: "interviewSeedVersion")
    }
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

    try? context.save()

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

    try? context.save()
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
