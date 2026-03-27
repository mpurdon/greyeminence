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
    @State private var inspectorWidth: CGFloat?
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
                .padding(.top, 8)
        }
        .toolbar {
            if selectedDestination == .meetings || selectedDestination == .recording {
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
            selectedMeeting = meeting
            selectedDestination = .meetings
            showInspector = true
            recordingViewModel.completedMeeting = nil
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
            } detail: {
                if let meeting = selectedMeeting {
                    GeometryReader { geo in
                        let defaultWidth = geo.size.width * 0.5
                        let width = inspectorWidth ?? defaultWidth
                        let clampedWidth = min(max(width, 280), geo.size.width * 0.7)

                        HStack(spacing: 0) {
                            MeetingDetailView(meeting: meeting, onSplitMeeting: { newMeeting in
                                selectedMeeting = newMeeting
                            })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if showInspector {
                                inspectorDragHandle(containerWidth: geo.size.width)
                                MeetingIntelligenceView(meeting: meeting)
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
                    RecordingView(viewModel: recordingViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector {
                        inspectorDragHandle(containerWidth: geo.size.width)
                        LiveMeetingIntelligenceView(
                            summary: recordingViewModel.streamingSummary,
                            actionItems: recordingViewModel.actionItems,
                            followUpQuestions: recordingViewModel.followUpQuestions,
                            topics: recordingViewModel.topics,
                            aiActivityState: recordingViewModel.aiActivityState
                        )
                        .frame(width: clampedWidth)
                    }
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
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted })
    private var pendingItems: [ActionItem]

    @Query(filter: #Predicate<ActionItem> { $0.isCompleted })
    private var completedItems: [ActionItem]

    private var stalledItems: [StalledCommitment] {
        CommitmentTrackingService().stalledCommitments(in: modelContext)
    }

    private var nonStalledPending: [ActionItem] {
        let stalledIDs = Set(stalledItems.map(\.id))
        return pendingItems.filter { !stalledIDs.contains($0.id) }
    }

    var body: some View {
        List {
            if !stalledItems.isEmpty {
                Section {
                    ForEach(stalledItems) { stalled in
                        HStack {
                            ActionItemRow(item: stalled.actionItem)
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
                    ActionItemRow(item: item)
                }
            } header: {
                Label("Pending (\(nonStalledPending.count))", systemImage: "circle")
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
        }
        .contextMenu {
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
        }
        .popover(isPresented: $showContactPicker) {
            ContactPicker(excludedContacts: excludedIDs) { contact in
                item.assignedContact = contact
                showContactPicker = false
            }
        }
    }
}

