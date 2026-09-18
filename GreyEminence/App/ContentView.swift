import SwiftUI
import SwiftData

enum SidebarDestination: String, Hashable, CaseIterable {
    case dashboard = "Dashboard"
    case meetings = "Meetings"
    case archive = "Archive"
    case recording = "New Recording"
    case tasks = "Tasks"
    case interviews = "Interviews"
    case people = "People"
    case topicMap = "Topic Map"
    case ask = "Ask"
    case activityLog = "Activity Log"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .meetings: "list.bullet.rectangle"
        case .archive: "archivebox"
        case .recording: "record.circle"
        case .tasks: "checkmark.circle"
        case .interviews: "person.badge.shield.checkmark"
        case .people: "person.2"
        case .topicMap: "bubble.left.and.bubble.right"
        case .ask: "sparkles.square.filled.on.square"
        case .activityLog: "list.bullet.clipboard"
        case .settings: "gear"
        }
    }

    var iconColor: Color {
        switch self {
        case .dashboard: .blue
        case .meetings: .indigo
        case .archive: .brown
        case .recording: .red
        case .tasks: .orange
        case .interviews: .cyan
        case .people: .green
        case .topicMap: .purple
        case .ask: .pink
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
    @State private var askViewModel = AskViewModel()
    @State private var pendingScrollSegmentID: UUID?
    /// Transcript → screen-share player: set by a timestamp tap or an Ask
    /// deep link; consumed by ScreenSharePlayerSection (expand, seek, clear).
    @State private var pendingSeekTime: TimeInterval?
    @AppStorage("showInspector") private var showInspector = true
    @State private var sidebarExpanded = false
    @State private var inspectorWidth: CGFloat?
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false
    @AppStorage("myContactID") private var myContactIDString = ""
    @AppStorage("autoStartRecording") private var autoStartRecording = false
    @State private var showProfileSetup = false
    @State private var interruptedMeeting: Meeting?
    @State private var showResumeAlert = false
    /// Highest app version whose feature highlights the user has seen. Empty on
    /// first launch under this system — seeded in `presentWhatsNewIfNeeded`.
    @AppStorage("lastSeenHighlightVersion") private var lastSeenHighlightVersion = ""
    /// Staged What's New presentation — non-nil means "show it". Set by the
    /// post-update check and, via the focused value below, by Help → What's New.
    @State private var whatsNew: WhatsNewPresentation?
    @State private var selectedInterview: Interview?
    var recordingViewModel: RecordingViewModel
    var interviewRecordingViewModel: InterviewRecordingViewModel

    var body: some View {
        VStack(spacing: 0) {
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
            CallPromptBar(viewModel: recordingViewModel)
            ReProcessingStatusBar()
            TransientActivityStatusBar()
        }
        .toolbar {
            // Title-bar badge marking a local Debug run (empty in Release).
            ToolbarItem(placement: .navigation) {
                DevBuildBanner()
            }
            if selectedDestination == .meetings || selectedDestination == .archive || selectedDestination == .recording || selectedDestination == .interviews || selectedDestination == .ask {
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
            // The test bundle is hosted by this app, so a test run launches it
            // for real. None of what follows may touch the developer's live
            // store: maintenance rewrites rows, recovery re-imports frames,
            // auto-detection can start a recording. Tests exercise these
            // services directly with their own contexts instead.
            guard !TestEnvironment.isRunningTests else { return }

            Task { @MainActor in
                // Updates first. The appcast check fired when the updater
                // started; everything below waits for its answer so an
                // "Install and Relaunch" lands on an idle app, not on a
                // recording auto-detection just started or a maintenance
                // pass mid-write. Capped inside the gate, so an offline
                // launch proceeds after the timeout.
                let outcome = await TransientActivityCoordinator.shared.runAsync("Checking for updates…") {
                    await StartupUpdateGate.shared.waitForDecision()
                }
                LogManager.shared.log("Startup update gate released: \(outcome)", category: .update)
                runLaunchSequence()
            }
        }
        .onChange(of: autoStartRecording) { _, enabled in
            recordingViewModel.setAutoDetectionEnabled(enabled)
        }
        // Lets Help → What's New present the sheet in this window when it's the
        // key one — see FocusedValues.whatsNewPresentation.
        .focusedSceneValue(\.whatsNewPresentation, $whatsNew)
        .sheet(isPresented: $showProfileSetup) {
            MyProfileSetupSheet()
        }
        // "What's New" — post-update or on demand from the Help menu. Dismissal
        // (any path — Got it, Escape, Try it) records the current version via
        // onDismiss so the post-update sheet never re-nags.
        .sheet(item: $whatsNew, onDismiss: {
            lastSeenHighlightVersion = FeatureHighlightCatalog.currentVersion
        }) { presentation in
            WhatsNewSheet(
                highlights: presentation.highlights,
                version: FeatureHighlightCatalog.currentVersion
            ) { highlight in
                // Deep-link into the feature, and count that as discovering it
                // so the in-context badge doesn't also fire.
                whatsNew = nil
                if let destination = highlight.destination {
                    selectedDestination = destination
                }
                FeatureDiscovery.shared.markSeen(highlight.id)
            }
        }
        // Presented at the root so it appears regardless of which destination is
        // active — a recording (and its multi-event calendar choice) can be
        // started from the menu bar or auto-detector while the Recording tab
        // isn't open.
        .sheet(isPresented: Binding(
            get: { !recordingViewModel.pendingCalendarChoices.isEmpty },
            set: { if !$0 { recordingViewModel.pendingCalendarChoices = [] } }
        )) {
            CalendarEventPickerSheet(
                events: recordingViewModel.pendingCalendarChoices,
                onPick: { event in
                    recordingViewModel.matchCalendarEventManually(event, in: modelContext)
                    recordingViewModel.pendingCalendarChoices = []
                },
                onSkip: { recordingViewModel.pendingCalendarChoices = [] }
            )
        }
        .alert(
            MeetingPinPrompt.title,
            isPresented: Binding(
                get: { recordingViewModel.pinPromptMeeting != nil },
                set: { if !$0 { recordingViewModel.pinPromptMeeting = nil } }
            ),
            presenting: recordingViewModel.pinPromptMeeting
        ) { meeting in
            Button("Pin") {
                meeting.isPinned = true
                FeatureDiscovery.shared.markSeen(MeetingPinPrompt.featureID)
            }
            Button("Not Now", role: .cancel) {
                FeatureDiscovery.shared.markSeen(MeetingPinPrompt.featureID)
            }
        } message: { meeting in
            Text("\u{201C}\(meeting.title)\u{201D} just finished. \(MeetingPinPrompt.message)")
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

    /// Revert any Interview rows stuck in `.recording` back to `.scheduled`.
    /// The recording engine is process-local — if the app was restarted or
    /// crashed mid-interview, the status persists but no audio is being
    /// captured. `checkForInterruptedRecording` already declines to resume
    /// interview meetings (they're too complex to restore), so without this
    /// the row's Start button stays hidden forever and the user is stuck
    /// looking at a "In Progress" badge they can't act on. Reverting to
    /// `.scheduled` restores the Start button so they can re-enter cleanly.
    private func recoverOrphanedInterviews() {
        let descriptor = FetchDescriptor<Interview>()
        let interviews = (try? modelContext.fetch(descriptor)) ?? []
        var reverted = 0
        for interview in interviews where interview.status == .recording {
            interview.status = .scheduled
            interview.interruptedAt = .now
            reverted += 1
        }
        guard reverted > 0 else { return }
        PersistenceGate.save(
            modelContext,
            site: "ContentView.recoverOrphanedInterviews",
            critical: true
        )
        LogManager.send("Recovered \(reverted) orphaned interview row(s) — reverted to scheduled", category: .general)
        TransientActivityCoordinator.shared.flash(
            "Restored \(reverted) interrupted interview\(reverted == 1 ? "" : "s") — click Start to resume"
        )
    }

    /// Decide whether to show the post-update "What's New" sheet, and stage its
    /// highlights. Runs once per launch from `onAppear`.
    private func presentWhatsNewIfNeeded() {
        // Never interrupt an in-progress recording that survived a relaunch.
        guard recordingViewModel.state == .idle else { return }

        if lastSeenHighlightVersion.isEmpty {
            // First launch under this system. A brand-new user (no profile set,
            // no changelog reads) is onboarding — suppress the sheet and just
            // start tracking from here so they only ever see FUTURE updates.
            // An existing user upgrading INTO the system sees the current
            // highlights once (seed to "0.0.0"), then only newer ones after.
            let brandNewUser = myContactIDString.isEmpty && ChangelogReadStore.readVersions().isEmpty
            if brandNewUser {
                lastSeenHighlightVersion = FeatureHighlightCatalog.currentVersion
                // Same reasoning for the one-shot prompts: they introduce a
                // change to people who knew the old behaviour.
                FeatureDiscovery.shared.markSeen(MeetingPinPrompt.featureID)
                return
            }
            lastSeenHighlightVersion = "0.0.0"
        }

        let pending = FeatureHighlightCatalog.pending(since: lastSeenHighlightVersion)
        guard !pending.isEmpty else { return }

        // Sequence behind the first-run profile sheet so the two never stack.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard !showProfileSetup else { return }
            whatsNew = WhatsNewPresentation(highlights: pending)
        }
    }

    /// Everything launch does once the update check has answered — see
    /// `StartupUpdateGate`. Order matters: the interrupted-recording check
    /// runs before auto-detection can start a new one.
    private func runLaunchSequence() {
        // Both fetch from SwiftData on the main actor, so they are worth
        // naming: silence during them is indistinguishable from a hang.
        TransientActivityCoordinator.shared.run("Checking for an interrupted recording…") {
            checkForInterruptedRecording()
        }
        TransientActivityCoordinator.shared.run("Checking interviews…") {
            recoverOrphanedInterviews()
        }
        // Prompt for profile if not configured (with slight delay so window settles)
        if myContactIDString.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                showProfileSetup = true
            }
        }
        presentWhatsNewIfNeeded()
        recordingViewModel.configureAutoDetection(enabled: autoStartRecording) { [modelContext] in
            modelContext
        }
        // Disk pressure is the one thing that makes every later step
        // slow — purged caches, recompiles, failing writes — so say so
        // at launch, not after the first symptom.
        LogManager.shared.log("Free disk space: \(DiskSpace.freeBytes().map(DiskSpace.describe) ?? "unknown")", category: .general)
        recordingViewModel.surfaceDiskSpaceWarning(context: "launch")
        Task(priority: .background) { @MainActor [modelContext] in
            let report = await TransientActivityCoordinator.shared.runAsync("Running startup maintenance…") {
                await MaintenanceService.runStartupMaintenance(modelContext: modelContext) { done, total, name in
                    // Name the step and show how far along it is: a bar
                    // that says only "running" for a minute is
                    // indistinguishable from one that has hung.
                    let coordinator = TransientActivityCoordinator.shared
                    if !name.isEmpty { coordinator.retitle("Startup maintenance — \(name.lowercased())") }
                    coordinator.setProgress(completed: done, total: total)
                }
            }
            if !report.skipped {
                TransientActivityCoordinator.shared.flash("Maintenance complete")
            }
            // Unthrottled (unlike maintenance): rows lost to a schema
            // downgrade should come back on the very next launch, and
            // the no-op case costs one fetch + a directory check.
            let recovered = await TransientActivityCoordinator.shared.runAsync(
                "Checking screen-share frames…"
            ) {
                await ScreenFrameRecoveryService.recoverAtLaunch(modelContext: modelContext)
            }
            if recovered > 0 {
                TransientActivityCoordinator.shared.flash("Recovered \(recovered) screen-share frame(s)")
            }
            // Opt-in, once a day, and only when there are open tasks no
            // pass has rated yet — see TaskTriageSettings.isAutoRunDue.
            await TaskTriageService.runAutomaticPassIfDue(in: modelContext)
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
        let allMeetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        let orphansFetched = allMeetings.filter {
            $0.status == statusRecording || $0.status == statusPaused
        }

        // Build the protected-IDs set BEFORE purging. The lock-file scan must
        // come first so a recording whose meeting row failed to save (so it's
        // missing from `allMeetings`) doesn't get its audio nuked just because
        // SwiftData doesn't know about it. The lock file is the on-disk
        // breadcrumb that "this audio is in-progress, don't touch."
        let lockFiles = RecordingLockFile.scanAll()
        var referenced = Set(allMeetings.map(\.id))
        for m in allMeetings {
            if let src = m.audioSourceMeetingID { referenced.insert(src) }
        }
        for lock in lockFiles {
            referenced.insert(lock.meetingID)
        }

        let purged = StorageManager.shared.purgeOrphanedRecordings(referencedIDs: referenced)
        if purged.count > 0 {
            let mb = Double(purged.bytes) / 1_048_576
            LogManager.send(
                "Purged \(purged.count) orphaned recording folder(s), freed \(String(format: "%.1f", mb)) MB",
                category: .general
            )
        }

        // Recording-retention sweep: drop audio files for completed meetings
        // older than the configured threshold. Transcripts + meeting rows
        // stay; only the (large) m4a files go. 0 = unlimited.
        let retentionDays = UserDefaults.standard.integer(forKey: "recordingRetentionDays")
        if retentionDays > 0 {
            var ages: [UUID: Date] = [:]
            for m in allMeetings where m.status == .completed {
                ages[m.id] = m.date.addingTimeInterval(m.duration)
            }
            let aged = StorageManager.shared.purgeRecordingsOlderThan(
                days: retentionDays,
                meetingFinishedAt: ages
            )
            if aged.count > 0 {
                let mb = Double(aged.bytes) / 1_048_576
                LogManager.send(
                    "Retention sweep: removed audio for \(aged.count) meeting(s) older than \(retentionDays) day\(retentionDays == 1 ? "" : "s"), freed \(String(format: "%.1f", mb)) MB",
                    category: .general
                )
            }
        }

        if !lockFiles.isEmpty {
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
                // No useful data — just delete it (plus any stray audio on disk)
                MeetingDeletion.delete(meeting, in: modelContext, allMeetings: orphans)
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

    /// Jump from an Ask snippet to the moment it came from: select its
    /// meeting, then scroll the transcript (or seek the screen-share player)
    /// once the detail view has mounted.
    private func openMeeting(for result: SearchResult) {
        let descriptor = FetchDescriptor<Meeting>()
        guard let meeting = (try? modelContext.fetch(descriptor))?.first(where: { $0.id == result.meetingID }) else { return }
        selectedMeeting = meeting
        selectedDestination = .meetings
        switch result.sourceKind {
        case .transcriptSegment:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pendingScrollSegmentID = result.sourceID
            }
        case .screenObservation:
            // The embedding record doesn't carry the frame's timestamp —
            // resolve it at click time and seek the player there.
            let timestamp = meeting.screenFrames.first(where: { $0.id == result.sourceID })?.timestamp
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if let timestamp {
                    pendingSeekTime = timestamp
                }
            }
        default:
            break
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
                MeetingListView(
                    selectedMeeting: $selectedMeeting,
                    onShowArchive: { selectedDestination = .archive }
                )
                    .navigationSplitViewColumnWidth(min: 280, ideal: 300)
            } detail: {
                if let meeting = selectedMeeting {
                    GeometryReader { geo in
                        // Priority for collapsing: center > sidebar > transcript.
                        // The center pane gets a healthy floor (60% min), and
                        // the transcript inspector is clamped to at most 45%
                        // of the available width so the header never squishes
                        // into the character-wrapping disaster from earlier.
                        let defaultWidth = geo.size.width * 0.4
                        let width = inspectorWidth ?? defaultWidth
                        let clampedWidth = min(max(width, 280), geo.size.width * 0.45)

                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                MeetingHeaderBar(meeting: meeting)
                                Divider()
                                MeetingIntelligenceView(
                                    meeting: meeting,
                                    pendingSeekTime: $pendingSeekTime,
                                    onPlayheadSegment: { pendingScrollSegmentID = $0 }
                                )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(2)
                            if showInspector {
                                inspectorDragHandle(containerWidth: geo.size.width)
                                TranscriptPanelView(
                                    meeting: meeting,
                                    onSplitMeeting: { newMeeting in
                                        selectedMeeting = newMeeting
                                    },
                                    scrollToSegmentID: $pendingScrollSegmentID,
                                    onSeekToTime: meeting.screenFrames.isEmpty ? nil : { pendingSeekTime = $0 }
                                )
                                .frame(width: clampedWidth)
                                .layoutPriority(0)
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
        case .archive:
            NavigationSplitView {
                ArchiveView(selectedMeeting: $selectedMeeting)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 480)
            } detail: {
                if let meeting = selectedMeeting {
                    GeometryReader { geo in
                        let defaultWidth = geo.size.width * 0.4
                        let width = inspectorWidth ?? defaultWidth
                        let clampedWidth = min(max(width, 280), geo.size.width * 0.45)

                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                MeetingHeaderBar(meeting: meeting)
                                Divider()
                                MeetingIntelligenceView(
                                    meeting: meeting,
                                    pendingSeekTime: $pendingSeekTime,
                                    onPlayheadSegment: { pendingScrollSegmentID = $0 }
                                )
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(2)
                            if showInspector {
                                inspectorDragHandle(containerWidth: geo.size.width)
                                TranscriptPanelView(
                                    meeting: meeting,
                                    onSplitMeeting: { newMeeting in
                                        selectedMeeting = newMeeting
                                    },
                                    scrollToSegmentID: $pendingScrollSegmentID,
                                    onSeekToTime: meeting.screenFrames.isEmpty ? nil : { pendingSeekTime = $0 }
                                )
                                .frame(width: clampedWidth)
                                .layoutPriority(0)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Meeting Selected",
                        systemImage: "doc.text",
                        description: Text("Pick a meeting from the archive to view its details")
                    )
                }
            }
        case .recording:
            GeometryReader { geo in
                // Keep the live transcript a healthy panel but never let it crowd
                // the recording pane (whose toolbar is horizontally dense): floor
                // the recording side at ~50% by clamping the inspector to 50% max.
                let defaultWidth = geo.size.width * 0.4
                let width = inspectorWidth ?? defaultWidth
                let clampedWidth = min(max(width, 280), geo.size.width * 0.5)

                HStack(spacing: 0) {
                    RecordingView(viewModel: recordingViewModel, showsTranscript: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(2)
                    // Only show the live transcript pane while a recording is
                    // active. When idle (e.g. returning here to start a new one)
                    // there's nothing live to show, and rendering it would
                    // surface the previous recording's transcript.
                    if showInspector && recordingViewModel.state != .idle {
                        inspectorDragHandle(containerWidth: geo.size.width)
                        RecordingInspectorPanel(viewModel: recordingViewModel)
                            .frame(width: clampedWidth)
                            .layoutPriority(0)
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
        case .ask:
            GeometryReader { geo in
                // Same split as the meeting detail: conversation on the left,
                // the evidence behind it in the inspector slot where the
                // transcript sits everywhere else in the app.
                let defaultWidth = geo.size.width * 0.32
                let width = inspectorWidth ?? defaultWidth
                let clampedWidth = min(max(width, 280), geo.size.width * 0.45)

                HStack(spacing: 0) {
                    AskView(viewModel: askViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(2)
                    if showInspector {
                        inspectorDragHandle(containerWidth: geo.size.width)
                        AskSourcesPanel(viewModel: askViewModel, onResultSelected: { result in
                            openMeeting(for: result)
                        })
                        .frame(width: clampedWidth)
                        .layoutPriority(0)
                    }
                }
            }
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
    case priority = "Priority"
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
    @AppStorage("taskShowDismissed") private var showDismissed = false
    @Query(filter: #Predicate<ActionItem> { !$0.isCompleted && $0.dismissedAt == nil })
    private var pendingItems: [ActionItem]

    @Query(filter: #Predicate<ActionItem> { $0.isCompleted })
    private var completedItems: [ActionItem]

    @Query(filter: #Predicate<ActionItem> { $0.dismissedAt != nil })
    private var dismissedItems: [ActionItem]

    @Query private var allContacts: [Contact]

    @State private var detailTask: ActionItem?
    @State private var showBulkDismissConfirmation = false
    @State private var isTidying = false
    @State private var tidyError: String?

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
        case .priority:
            // Unrated items sink to the bottom regardless of direction;
            // within a rating, newest first.
            switch (a.priority, b.priority) {
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.createdAt > b.createdAt
            case let (.some(x), .some(y)):
                if x == y { return a.createdAt > b.createdAt }
                return ascending ? x.rank > y.rank : x.rank < y.rank
            }
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

    private var visibleDismissed: [ActionItem] {
        showDismissed ? sorted(dismissedItems.filter(isVisible)) : []
    }

    private var nonStalledPending: [ActionItem] {
        let stalledIDs = Set(stalledItems.map(\.id))
        return visiblePending.filter { !stalledIDs.contains($0.id) }
    }

    /// One AI pass over the open tasks the current filter shows: rate,
    /// merge duplicates, drop non-tasks. Applied immediately — the outcome
    /// lands in the status bar and every deletion in the activity log.
    private func tidyWithAI() {
        guard !isTidying else { return }
        isTidying = true
        FeatureDiscovery.shared.markSeen("ai-task-tidy")
        let scope = pendingItems.filter(isVisible)
        Task { @MainActor in
            defer { isTidying = false }
            do {
                let report = try await TransientActivityCoordinator.shared.runAsync("Tidying tasks with AI…") {
                    try await TaskTriageService.run(pending: scope, in: modelContext)
                }
                TransientActivityCoordinator.shared.flash("Tasks tidied: \(report.summary)")
            } catch {
                tidyError = error.localizedDescription
            }
        }
    }

    private func bulkDismissStalled() {
        for stalled in stalledItems {
            stalled.actionItem.dismissedAt = .now
        }
        PersistenceGate.save(
            modelContext,
            site: "AllTasksView.bulkDismissStalled"
        )
        LogManager.send("Marked \(stalledItems.count) stalled task(s) as Won't Do (filter: \(filter.rawValue))", category: .general)
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

            if !visibleDismissed.isEmpty {
                Section {
                    ForEach(visibleDismissed) { item in
                        ActionItemRow(item: item, onShowDetails: { detailTask = $0 })
                    }
                } header: {
                    Label("Won't Do (\(visibleDismissed.count))", systemImage: "nosign")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                Button {
                    tidyWithAI()
                } label: {
                    if isTidying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Tidy with AI", systemImage: "sparkles")
                    }
                }
                .disabled(isTidying || pendingItems.isEmpty)
                .help("Rank open tasks by importance, merge duplicates and remove anything that isn't a task — applied right away")
                .newFeatureBadge("ai-task-tidy")
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
                        Toggle("Show Won't Do", isOn: $showDismissed)
                    }
                    if !stalledItems.isEmpty {
                        Section {
                            Button(role: .destructive) {
                                showBulkDismissConfirmation = true
                            } label: {
                                Label("Mark Stalled as Won't Do (\(stalledItems.count))", systemImage: "nosign")
                            }
                        }
                    }
                } label: {
                    Label("Options", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Sort and display options")
            }
        }
        .confirmationDialog(
            "Mark \(stalledItems.count) stalled task\(stalledItems.count == 1 ? "" : "s") as Won't Do?",
            isPresented: $showBulkDismissConfirmation,
            titleVisibility: .visible
        ) {
            Button("Mark as Won't Do", role: .destructive) {
                bulkDismissStalled()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Affects the current \(filter.rawValue) filter. Items can be restored from the Won't Do section.")
        }
        .alert("Couldn't tidy tasks", isPresented: Binding(
            get: { tidyError != nil },
            set: { if !$0 { tidyError = nil } }
        )) {
            Button("OK") { tidyError = nil }
        } message: {
            Text(tidyError ?? "")
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
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: ActionItem
    var onDelete: ((ActionItem) -> Void)?
    var onShowDetails: ((ActionItem) -> Void)?
    @State private var showContactPicker = false

    private func persist(_ site: String) {
        PersistenceGate.save(modelContext, site: "ActionItemRow.\(site)", meetingID: item.meeting?.id)
    }

    private var excludedIDs: Set<PersistentIdentifier> {
        if let contact = item.assignedContact {
            return [contact.persistentModelID]
        }
        return []
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                item.isCompleted.toggle()
                persist("toggleCompleted")
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .strikethrough(item.isCompleted || item.isDismissed)
                    .foregroundStyle(item.isCompleted || item.isDismissed ? .secondary : .primary)
                    .textSelection(.enabled)
                // Assignee row only when one is set — assign/unlink live in the
                // context menu, so unassigned items stay a single clean line
                // rather than a second row with a dangling icon.
                if let contact = item.assignedContact {
                    HStack(spacing: 4) {
                        Text(contact.initials)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(contact.avatarColor.gradient, in: Circle())
                        Text(contact.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let assignee = item.assignee, !assignee.isEmpty {
                    Text(assignee)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Why the AI tidy-up pass put this in Won't Do — the reader
                // deciding whether to restore it needs the reason on the row.
                if item.isDismissed, let note = item.dismissalNote {
                    Label(note, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let priority = item.priority, !item.isCompleted, !item.isDismissed {
                TaskPriorityBadge(priority: priority)
            }

            if onShowDetails != nil {
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
                    persist("unlinkContact")
                }
            }
            Divider()
            if item.isDismissed {
                Button("Restore (mark Pending)") {
                    item.dismissedAt = nil
                    item.dismissalNote = nil
                    persist("restoreFromDismissed")
                }
            } else if !item.isCompleted {
                Button("Mark as Won't Do") {
                    item.dismissedAt = .now
                    persist("dismiss")
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
            ContactPicker(
                excludedContacts: excludedIDs,
                prioritizedContacts: item.meeting?.presentAttendees ?? []
            ) { contact in
                item.assignedContact = contact
                persist("assignContact")
                showContactPicker = false
            }
        }
    }
}

/// Compact importance marker from the AI tidy-up pass. Low is shown too —
/// an unrated item and a low one should not look the same.
struct TaskPriorityBadge: View {
    let priority: ActionItemPriority

    private var tint: Color {
        switch priority {
        case .high: .red
        case .medium: .orange
        case .low: .gray
        }
    }

    var body: some View {
        Text(priority.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .help("Importance rated by the AI tidy-up pass")
    }
}
