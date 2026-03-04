import SwiftUI
import SwiftData

enum SidebarDestination: String, Hashable, CaseIterable {
    case dashboard = "Dashboard"
    case meetings = "Meetings"
    case recording = "New Recording"
    case tasks = "Tasks"
    case people = "People"
    case activityLog = "Activity Log"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .meetings: "list.bullet.rectangle"
        case .recording: "record.circle"
        case .tasks: "checkmark.circle"
        case .people: "person.2"
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
        case .people: .green
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
    @State private var selectedDestination: SidebarDestination? = .dashboard
    @State private var selectedMeeting: Meeting?
    @State private var showInspector = true
    @State private var sidebarExpanded = true
    var recordingViewModel: RecordingViewModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                selection: $selectedDestination,
                isExpanded: $sidebarExpanded
            )
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button {
                        sidebarExpanded.toggle()
                    } label: {
                        Label("Toggle Sidebar", systemImage: "sidebar.left")
                    }
                    .keyboardShortcut("s", modifiers: .command)

                    if selectedDestination == .meetings || selectedDestination == .recording {
                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Toggle Insights", systemImage: "sidebar.right")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                    }
                }
            }
        }
        .onChange(of: recordingViewModel.completedMeeting) { _, meeting in
            guard let meeting else { return }
            selectedMeeting = meeting
            selectedDestination = .meetings
            showInspector = true
            recordingViewModel.completedMeeting = nil
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
            } detail: {
                if let meeting = selectedMeeting {
                    MeetingDetailView(meeting: meeting)
                        .inspector(isPresented: $showInspector) {
                            MeetingIntelligenceView(meeting: meeting)
                                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
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
            HStack(spacing: 0) {
                RecordingView(viewModel: recordingViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    Divider()
                    LiveMeetingIntelligenceView(
                        summary: recordingViewModel.streamingSummary,
                        actionItems: recordingViewModel.actionItems,
                        followUpQuestions: recordingViewModel.followUpQuestions,
                        topics: recordingViewModel.topics,
                        aiActivityState: recordingViewModel.aiActivityState
                    )
                    .frame(width: 320)
                }
            }
        case .tasks:
            AllTasksView()
        case .people:
            PeopleView()
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

struct AllTasksView: View {
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted })
    private var pendingItems: [ActionItem]

    @Query(filter: #Predicate<ActionItem> { $0.isCompleted })
    private var completedItems: [ActionItem]

    var body: some View {
        List {
            Section {
                ForEach(pendingItems) { item in
                    ActionItemRow(item: item)
                }
            } header: {
                Label("Pending (\(pendingItems.count))", systemImage: "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }
            if !completedItems.isEmpty {
                Section {
                    ForEach(completedItems) { item in
                        ActionItemRow(item: item)
                    }
                } header: {
                    Label("Completed (\(completedItems.count))", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
        .navigationTitle("All Tasks")
        .overlay {
            if pendingItems.isEmpty && completedItems.isEmpty {
                ContentUnavailableView(
                    "No Action Items",
                    systemImage: "checkmark.circle",
                    description: Text("Action items from meetings will appear here")
                )
            }
        }
    }
}

struct ActionItemRow: View {
    @Bindable var item: ActionItem
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
                if let assignee = item.displayAssignee {
                    HStack(spacing: 4) {
                        if let contact = item.assignedContact {
                            Text(contact.initials)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(contact.avatarColor.gradient, in: Circle())
                        }
                        Text(assignee)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            if item.assignedContact != nil {
                Button("Unlink Contact") {
                    item.assignedContact = nil
                }
            }
            Button("Assign Contact...") {
                showContactPicker = true
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

