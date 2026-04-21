import SwiftUI
import SwiftData

enum SidebarDestination: String, Hashable, CaseIterable {
    case dashboard = "Dashboard"
    case meetings = "Meetings"
    case recording = "New Recording"
    case tasks = "Tasks"
    case interviews = "Interviews"
    case people = "People"
    case topicMap = "Topic Map"
    case activityLog = "Activity Log"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .meetings: "list.bullet.rectangle"
        case .recording: "record.circle"
        case .tasks: "checkmark.circle"
        case .interviews: "person.badge.shield.checkmark"
        case .people: "person.2"
        case .topicMap: "bubble.left.and.bubble.right"
        case .activityLog: "list.bullet.clipboard"
        case .settings: "gear"
        }
    }

    var iconColor: Color {
        switch self {
        case .dashboard: .blue
        case .meetings: .indigo
        case .recording: .red
        case .tasks: .orange
        case .interviews: .cyan
        case .people: .green
        case .topicMap: .purple
        case .activityLog: .gray
        case .settings: .gray
        }
    }

    var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(iconColor.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ContentView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @State private var selectedDestination: SidebarDestination? = .dashboard
    @State private var selectedMeeting: Meeting?
    @State private var topicMapViewModel = TopicMapViewModel()
    @AppStorage("showInspector") private var showInspector = true
    @State private var sidebarExpanded = false
    @State private var inspectorWidth: CGFloat?
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false
    @AppStorage("myContactID") private var myContactIDString = ""
    @AppStorage("autoStartRecording") private var autoStartRecording = false
    @State private var showProfileSetup = false
    @State private var interruptedMeeting: Meeting?
    @State private var showResumeAlert = false
    @State private var selectedInterview: Interview?
    var recordingViewModel: RecordingViewModel
    var interviewRecordingViewModel: InterviewRecordingViewModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selection: $selectedDestination,
                isExpanded: $sidebarExpanded
            )
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 8)
                .environment(\.topicMapViewModel, topicMapViewModel)
                .onChange(of: topicMapViewModel.pendingFocusTopic) { _, topic in
                    if topic != nil {
                        selectedDestination = .topicMap
                    }
                }
        }
        .toolbar {
            if selectedDestination == .meetings || selectedDestination == .recording || selectedDestination == .interviews {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Toggle Insights", systemImage: "sidebar.right")
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
        }
        .onChange(of: recordingViewModel.completedMeeting) { _, meeting in
            guard let meeting else { return }
            if meeting.isInterviewMeeting {
                selectedInterview = interviewRecordingViewModel.completedInterview
                interviewRecordingViewModel.reset()
                selectedDestination = .interviews
            } else {
                selectedMeeting = meeting
                selectedDestination = .meetings
            }
            recordingViewModel.completedMeeting = nil
        }
        .onChange(of: developerToolsEnabled) { _, enabled in
            if !enabled && selectedDestination == .activityLog {
                selectedDestination = .dashboard
            }
        }
        .onAppear {
            checkForInterruptedRecording()
            // Prompt for profile if not configured (with slight delay so window settles)
            if myContactIDString.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    showProfileSetup = true
                }
            }
            recordingViewModel.configureAutoDetection(enabled: autoStartRecording) { [modelContext] in
                modelContext
            }
        }
        .onChange(of: autoStartRecording) { _, enabled in
            recordingViewModel.setAutoDetectionEnabled(enabled)
        }
        .sheet(isPresented: $showProfileSetup) {
            MyProfileSetupSheet()
        }
        .alert("Resume Recording?", isPresented: $showResumeAlert) {
            Button("Resume") {
                if let meeting = interruptedMeeting {
                    recordingViewModel.resumeInterruptedRecording(meeting: meeting, in: modelContext)
                    selectedDestination = .recording
                    interruptedMeeting = nil
                }
            }
            Button("Discard", role: .destructive) {
                interruptedMeeting = nil
                recoverOrphanedMeetings()
            }
        } message: {
            if let meeting = interruptedMeeting {
                Text("\"\(meeting.title)\" was interrupted. Resume recording or discard it?\n\(meeting.segments.count) segments, \(meeting.formattedDuration) elapsed")
            }
        }
    }

    /// Check if there's an interrupted recording from a previous session.
    /// If found, prompt the user to resume or discard. Otherwise, run orphan cleanup.
    private func checkForInterruptedRecording() {
        guard let meetingID = RecordingViewModel.interruptedMeetingID() else {
            recoverOrphanedMeetings()
            return
        }

        // Find the meeting in SwiftData
        let descriptor = FetchDescriptor<Meeting>()
        guard let meeting = (try? modelContext.fetch(descriptor))?.first(where: { $0.id == meetingID }),
              meeting.status == .recording || meeting.status == .paused else {
            // Meeting not found or already completed — clear the marker and clean up
            UserDefaults.standard.removeObject(forKey: "activeRecordingMeetingID")
            recoverOrphanedMeetings()
            return
        }

        // Don't resume interview meetings — too complex to restore
        if meeting.isInterviewMeeting {
            UserDefaults.standard.removeObject(forKey: "activeRecordingMeetingID")
            recoverOrphanedMeetings()
            return
        }

        interruptedMeeting = meeting
        showResumeAlert = true
    }

    /// On launch, clean up any meetings still stuck in .recording or .paused from a previous session.
    /// Empty orphans (0 segments) are deleted; non-empty ones are marked completed (interrupted).
    /// Also cross-references on-disk `recording.lock` sidecar files so we can detect
    /// audio that was captured before SwiftData even got a chance to save the meeting row.
    private func recoverOrphanedMeetings() {
        let statusRecording = MeetingStatus.recording
        let statusPaused = MeetingStatus.paused
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.status == statusRecording || $0.status == statusPaused }
        )
        let orphansFetched = (try? modelContext.fetch(descriptor)) ?? []

        // Scan disk lock files. Any lock file whose meeting ID isn't in the
        // orphan set OR in the main meetings list represents audio on disk
        // that has no SwiftData row — a persistence failure during an earlier
        // session. Log it loudly so the user can investigate.
        let lockFiles = RecordingLockFile.scanAll()
        if !lockFiles.isEmpty {
            let allMeetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
            let knownIDs = Set(allMeetings.map(\.id))
            let ghosts = lockFiles.filter { !knownIDs.contains($0.meetingID) }
            for ghost in ghosts {
                LogManager.send(
                    "Ghost recording detected on disk: \(ghost.meetingID) started \(ghost.startedAt) — audio files exist but no meeting row. Check Recordings/\(ghost.meetingID.uuidString)/",
                    category: .general,
                    level: .warning
                )
            }
            // Clean up lock files that correspond to meetings we're about to
            // mark completed/deleted — otherwise they'll stay and re-warn.
            let touched = Set(orphansFetched.map(\.id))
            for file in lockFiles where touched.contains(file.meetingID) {
                RecordingLockFile.remove(for: file.meetingID)
            }
        }

        guard !orphansFetched.isEmpty else { return }
        let orphans = orphansFetched

        var recovered = 0
        var deleted = 0
        for meeting in orphans {
            if meeting.segments.isEmpty && meeting.duration < 1 {
                // No useful data — just delete it
                modelContext.delete(meeting)
                deleted += 1
            } else {
                meeting.status = .completed
                if !meeting.title.contains("(interrupted)") {
                    meeting.title += " (interrupted)"
                }
                recovered += 1
            }
        }
        // Critical: if we can't save here, the orphan meetings stay stuck in
        // .recording forever and will re-prompt on every launch.
        PersistenceGate.save(
            modelContext,
            site: "ContentView.recoverOrphanedMeetings",
            critical: true
        )
        if recovered + deleted > 0 {
            LogManager.send("Orphan cleanup: \(recovered) recovered, \(deleted) deleted", category: .general)
        }
    }

    private func inspectorDragHandle(containerWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newWidth = (inspectorWidth ?? containerWidth * 0.5) - value.translation.width
                        inspectorWidth = min(max(newWidth, 280), containerWidth * 0.7)
                    }
            )
            .overlay {
                Divider()
            }
    }

    @ViewBuilder
    private var contentArea: some View {
        switch selectedDestination {
        case .dashboard:
            DashboardView { meeting in
                selectedMeeting = meeting
                selectedDestination = .meetings
            }
        case .meetings:
            NavigationSplitView {
                MeetingListView(selectedMeeting: $selectedMeeting)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 300)
            } detail: {
                if let meeting = selectedMeeting {
                    GeometryReader { geo in
                        let defaultWidth = geo.size.width * 0.5
                        let width = inspectorWidth ?? defaultWidth
                        let clampedWidth = min(max(width, 280), geo.size.width * 0.7)

                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                MeetingHeaderBar(meeting: meeting)
                                Divider()
                                MeetingIntelligenceView(meeting: meeting)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if showInspector {
                                inspectorDragHandle(containerWidth: geo.size.width)
                                TranscriptPanelView(meeting: meeting, onSplitMeeting: { newMeeting in
                                    selectedMeeting = newMeeting
                                })
                                .frame(width: clampedWidth)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Meeting Selected",
                        systemImage: "doc.text",
                        description: Text("Select a meeting to view its details")
                    )
                }
            }
        case .recording:
            GeometryReader { geo in
                let defaultWidth = geo.size.width * 0.5
                let width = inspectorWidth ?? defaultWidth
                let clampedWidth = min(max(width, 280), geo.size.width * 0.7)

                HStack(spacing: 0) {
                    RecordingView(viewModel: recordingViewModel, showsTranscript: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        inspectorDragHandle(containerWidth: geo.size.width)
                        LiveTranscriptView(
                            segments: recordingViewModel.segments,
                            segmentConfidence: recordingViewModel.segmentConfidence
                        )
                        .frame(width: clampedWidth)
                    }
                }
            }
        case .interviews:
            InterviewHubView(
                interviewViewModel: interviewRecordingViewModel,
                selectedInterview: $selectedInterview,
                showInspector: $showInspector,
                inspectorWidth: $inspectorWidth
            )
        case .tasks:
            AllTasksView()
        case .people:
            PeopleView()
        case .topicMap:
            TopicMapView(viewModel: topicMapViewModel, onMeetingSelected: { meeting in
                selectedMeeting = meeting
                selectedDestination = .meetings
            })
        case .activityLog:
            LogView()
        case .settings:
            SettingsView()
        case .none:
            ContentUnavailableView(
                "Select a section",
                systemImage: "sidebar.left",
                description: Text("Choose a section from the sidebar")
            )
        }
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case mine = "Mine + Unassigned"
    case all = "All"
    var id: String { rawValue }
}

enum TaskSort: String, CaseIterable, Identifiable {
    case created = "Date Created"
    case dueDate = "Due Date"
    case meetingDate = "Meeting Date"
    case alphabetical = "Alphabetical"
    var id: String { rawValue }
}

enum TaskSortDirection: String, CaseIterable, Identifiable {
    case descending = "Descending"
    case ascending = "Ascending"
    var id: String { rawValue }
}

private let selfAssigneeSynonyms: Set<String> = ["me", "myself", "i"]

struct AllTasksView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("stalledThresholdDays") private var stalledThresholdDays = 7
    @AppStorage("myContactID") private var myContactIDString = ""
    @AppStorage("taskFilter") private var filterRaw = TaskFilter.mine.rawValue
    @AppStorage("taskSort") private var sortRaw = TaskSort.created.rawValue
    @AppStorage("taskSortDirection") private var sortDirectionRaw = TaskSortDirection.descending.rawValue
    @AppStorage("taskShowCompleted") private var showCompleted = true
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted })
    private var pendingItems: [ActionItem]

    @Query(filter: #Predicate<ActionItem> { $0.isCompleted })
    private var completedItems: [ActionItem]

    @Query private var allContacts: [Contact]

    @State private var detailTask: ActionItem?

    private var filter: TaskFilter {
        TaskFilter(rawValue: filterRaw) ?? .mine
    }

    private var sort: TaskSort {
        TaskSort(rawValue: sortRaw) ?? .created
    }

    private var sortDirection: TaskSortDirection {
        TaskSortDirection(rawValue: sortDirectionRaw) ?? .descending
    }

    private var myContact: Contact? {
        guard let id = UUID(uuidString: myContactIDString) else { return nil }
        return allContacts.first { $0.id == id }
    }

    /// Normalized tokens that should match an assignee string if it refers to "me".
    /// Includes raw synonyms ("me", "myself"), the full contact name, and the first
    /// word of the name — enough to catch the common AI-parsed forms.
    private var mySelfTokens: Set<String> {
        var tokens = selfAssigneeSynonyms
        if let name = myContact?.name {
            let lower = name.lowercased()
            tokens.insert(lower)
            if let first = lower.split(separator: " ").first {
                tokens.insert(String(first))
            }
        }
        return tokens
    }

    private func isUnassigned(_ item: ActionItem) -> Bool {
        item.assignedContact == nil
            && (item.assignee?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    private func isMine(_ item: ActionItem) -> Bool {
        if let assigned = item.assignedContact {
            return assigned.id == myContact?.id
        }
        guard let raw = item.assignee?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return false }
        return mySelfTokens.contains(raw.lowercased())
    }

    private func isVisible(_ item: ActionItem) -> Bool {
        switch filter {
        case .all:
            return true
        case .mine:
            return isMine(item) || isUnassigned(item)
        }
    }

    /// Single comparator used by every sorted view in this screen so the
    /// stalled section, the pending section, and the completed section all
    /// reorder consistently when the user picks a sort.
    private func compare(_ a: ActionItem, _ b: ActionItem) -> Bool {
        let ascending = sortDirection == .ascending
        switch sort {
        case .created:
            return ascending ? a.createdAt < b.createdAt : a.createdAt > b.createdAt
        case .dueDate:
            // Nil due dates always sink to the bottom regardless of direction.
            switch (a.dueDate, b.dueDate) {
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.createdAt > b.createdAt
            case let (.some(x), .some(y)): return ascending ? x < y : x > y
            }
        case .meetingDate:
            let ad = a.meeting?.date ?? .distantPast
            let bd = b.meeting?.date ?? .distantPast
            return ascending ? ad < bd : ad > bd
        case .alphabetical:
            let result = a.text.localizedCaseInsensitiveCompare(b.text)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func sorted(_ items: [ActionItem]) -> [ActionItem] {
        items.sorted(by: compare)
    }

    private var stalledItems: [StalledCommitment] {
        CommitmentTrackingService()
            .stalledCommitments(in: modelContext, threshold: stalledThresholdDays)
            .filter { isVisible($0.actionItem) }
            .sorted { compare($0.actionItem, $1.actionItem) }
    }

    private var visiblePending: [ActionItem] {
        sorted(pendingItems.filter(isVisible))
    }

    private var visibleCompleted: [ActionItem] {
        showCompleted ? sorted(completedItems.filter(isVisible)) : []
    }

    private var nonStalledPending: [ActionItem] {
        let stalledIDs = Set(stalledItems.map(\.id))
        return visiblePending.filter { !stalledIDs.contains($0.id) }
    }

    var body: some View {
        List {
            if !stalledItems.isEmpty {
                Section {
                    ForEach(stalledItems) { stalled in
                        HStack {
                            ActionItemRow(item: stalled.actionItem, onShowDetails: { detailTask = $0 })
                            Spacer()
                            Text("\(stalled.daysStalled)d")
                                .font(.caption2)
                                .fontDesign(.monospaced)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (stalled.daysStalled > 14 ? Color.red : .orange).opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(stalled.daysStalled > 14 ? .red : .orange)
                        }
                    }
                } header: {
                    Label("Stalled (\(stalledItems.count))", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                        .textCase(nil)
                }
            }

            Section {
                ForEach(nonStalledPending) { item in
                    ActionItemRow(item: item, onShowDetails: { detailTask = $0 })
                }
            } header: {
                Label("Pending (\(nonStalledPending.count))", systemImage: "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            if !visibleCompleted.isEmpty {
                Section {
                    ForEach(visibleCompleted) { item in
                        ActionItemRow(item: item, onShowDetails: { detailTask = $0 })
                    }
                } header: {
                    Label("Completed (\(visibleCompleted.count))", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .navigationTitle("All Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: $filterRaw) {
                    ForEach(TaskFilter.allCases) { f in
                        Text(f.rawValue).tag(f.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help(myContactIDString.isEmpty
                      ? "Set your contact in Settings to filter by Mine"
                      : "Filter tasks")
                .disabled(myContactIDString.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Section("Sort by") {
                        Picker("Sort", selection: $sortRaw) {
                            ForEach(TaskSort.allCases) { s in
                                Text(s.rawValue).tag(s.rawValue)
                            }
                        }
                    }
                    Section("Direction") {
                        Picker("Direction", selection: $sortDirectionRaw) {
                            ForEach(TaskSortDirection.allCases) { d in
                                Label(
                                    d.rawValue,
                                    systemImage: d == .ascending ? "arrow.up" : "arrow.down"
                                ).tag(d.rawValue)
                            }
                        }
                    }
                    Section {
                        Toggle("Show Completed", isOn: $showCompleted)
                    }
                } label: {
                    Label("Options", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Sort and display options")
            }
        }
        .overlay {
            if visiblePending.isEmpty && visibleCompleted.isEmpty {
                ContentUnavailableView(
                    pendingItems.isEmpty && completedItems.isEmpty
                        ? "No Action Items"
                        : "No Tasks Match Filter",
                    systemImage: "checkmark.circle",
                    description: Text(
                        pendingItems.isEmpty && completedItems.isEmpty
                            ? "Action items from meetings will appear here"
                            : "Switch to All to see tasks assigned to others"
                    )
                )
            }
        }
        .sheet(item: $detailTask) { task in
            TaskDetailView(task: task)
        }
    }
}

struct ActionItemRow: View {
    @Bindable var item: ActionItem
    var onDelete: ((ActionItem) -> Void)?
    var onShowDetails: ((ActionItem) -> Void)?
    @State private var showContactPicker = false

    private var excludedIDs: Set<PersistentIdentifier> {
        if let contact = item.assignedContact {
            return [contact.persistentModelID]
        }
        return []
    }

    var body: some View {
        HStack {
            Button {
                item.isCompleted.toggle()
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    if let contact = item.assignedContact {
                        Text(contact.initials)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(contact.avatarColor.gradient, in: Circle())
                        Text(contact.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let assignee = item.assignee, !assignee.isEmpty {
                        Text(assignee)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showContactPicker = true
                    } label: {
                        Image(systemName: item.assignedContact != nil ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if onShowDetails != nil {
                Spacer()
                Button {
                    onShowDetails?(item)
                } label: {
                    Image(systemName: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show task details")
            }
        }
        .contextMenu {
            if onShowDetails != nil {
                Button("Show Details") { onShowDetails?(item) }
                Divider()
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                let text = if let assignee = item.displayAssignee {
                    "\(item.text) (\(assignee))"
                } else {
                    item.text
                }
                NSPasteboard.general.setString(text, forType: .string)
            }
            Divider()
            Button("Assign Contact...") {
                showContactPicker = true
            }
            if item.assignedContact != nil {
                Button("Unlink Contact") {
                    item.assignedContact = nil
                }
            }
            if let onDelete {
                Divider()
                Button("Delete", role: .destructive) {
                    onDelete(item)
                }
            }
        }
        .popover(isPresented: $showContactPicker) {
            ContactPicker(excludedContacts: excludedIDs) { contact in
                item.assignedContact = contact
                showContactPicker = false
            }
        }
    }
}

