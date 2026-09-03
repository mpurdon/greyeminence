import Foundation
import SwiftUI
import SwiftData
import AVFoundation
import EventKit

@Observable
@MainActor
final class RecordingViewModel {
    enum RecordingState: Equatable {
        case idle
        case recording
        case paused
    }

    enum AIActivityState: Equatable {
        case idle
        case waiting(secondsRemaining: Int)
        case analyzing
    }

    var state: RecordingState = .idle
    var aiActivityState: AIActivityState = .idle
    /// True while `stopRecording` is tearing down the previous recording's
    /// audio capture and persisting its transcript. Set synchronously at the
    /// start of stop and cleared as soon as that fast teardown finishes (before
    /// the slow final-analysis pass). Blocks a new recording from starting
    /// during the window when the shared capture/coordinator actors are being
    /// shut down — starting one then would have both recordings fighting over
    /// the same `coordinator`/`micCapture`/`systemCapture` instances.
    private(set) var isFinishing = false
    var elapsedTime: TimeInterval = 0
    var segments: [TranscriptSegment] = []

    private var recordingStartDate: Date?
    private var accumulatedPauseDuration: TimeInterval = 0
    private var pauseStartDate: Date?
    var currentMeeting: Meeting?
    var streamingSummary: String = ""
    var actionItems: [ActionItem] = []
    var followUpQuestions: [String] = []
    var topics: [String] = []
    var manualNote: String = ""
    var errorMessage: String?
    var micLevel: Float = 0
    var systemLevel: Float = 0
    /// Wall-clock time of the most recent non-silent system-audio buffer.
    /// The mic-silence auto-pause consults this so it doesn't trip while the
    /// user is merely listening to a meeting (mic quiet, system audio flowing) —
    /// only a genuine device fault (both streams silent) should pause.
    private var lastSystemAudioActivityAt: Date?
    /// Total write failures for the current recording (mic + system). Exposed
    /// so the recording surface can flag "this recording had write errors"
    /// instead of the previous silent `try?` swallow.
    var audioWriteFailures: Int = 0
    /// The most recent write-error message, for surfacing in the banner/log.
    var lastAudioWriteError: String?
    var completedMeeting: Meeting?
    var segmentConfidence: [UUID: Float] = [:]
    var prepContext: MeetingPrepContext?

    // Interview section tagging — set by InterviewRecordingViewModel
    var currentSectionTag: String?
    var currentSectionTagID: UUID?
    private var segmentSectionTags: [UUID: (tag: String, tagID: UUID)] = [:]

    private let log = LogManager.shared
    private var timer: Timer?
    private var processingTasks: [Task<Void, Never>] = []
    private var modelContext: ModelContext?
    private var lastPersistedSegmentCount: Int = 0

    // Audio services
    private let micCapture = MicrophoneCaptureService()
    private let systemCapture = SystemAudioCaptureService()
    /// Live audio writers for the current recording. Created in `startRealCapture`
    /// so the periodic persistence loop can call `checkpoint()` on them to bound
    /// audio loss on crash. `nil` outside an active recording.
    private var micFileWriter: AudioFileWriter?
    private var systemFileWriter: AudioFileWriter?
    /// True when the most recent recording was started via the auto-detector
    /// rather than a user click. Used for diagnostic logging — a silent mic
    /// in this path is more likely than in a manual start because the user
    /// hasn't necessarily had a chance to grant permission or check device
    /// selection.
    private var autoDetectedRecordingStart: Bool = false

    // Screen-share capture
    enum ScreenCaptureState: Equatable {
        case off
        /// Enabled and scanning for a share window.
        case watching
        case capturing(windowTitle: String)
        /// Screen Recording TCC denied — inert for the rest of the recording.
        case denied
    }
    private(set) var screenCaptureState: ScreenCaptureState = .off
    private(set) var screenShareFrameCount = 0
    /// Plausible share windows from the last discovery poll, best first —
    /// drives the manual picker (M3).
    private(set) var screenShareCandidates: [WindowCandidate] = []
    /// Relative path + capture time of the newest kept frame, for the
    /// toolbar popover preview.
    private(set) var screenShareLatestFramePath: String?
    private(set) var screenShareLatestFrameAt: Date?
    /// True when the user paused capture from the popover (independent of
    /// recording pause — resuming the recording must not undo it).
    private(set) var screenCaptureUserPaused = false
    let screenCapture = ScreenShareCaptureService()
    /// Frames received from the capture actor but not yet flushed into
    /// SwiftData rows, each stamped with its elapsed-seconds timestamp.
    private var pendingScreenFrames: [(frame: KeptFrame, timestamp: TimeInterval)] = []
    /// Out-of-band vision analysis. `nil` when analysis is off, the AI is
    /// unconfigured, or the client can't send images — capture still runs.
    private var frameAnalysis: ScreenFrameAnalysisService?
    /// Rolling log of Claude's frame observations, in arrival order. Feeds
    /// the live UI and the transcript-intelligence injection.
    private(set) var screenObservationLog: [ScreenFrameAnalysisService.FrameObservation] = []
    /// Share sessions that ended mid-recording and are waiting for narrative
    /// synthesis (which runs once all their frames clear vision analysis).
    private var endedSessionsAwaitingSynthesis: Set<UUID> = []
    /// One-time "recap of the share that just ended" blocks handed to the
    /// next successful rolling pass.
    private var pendingRecapBlocksForRolling: [String] = []
    /// Lazily-built session synthesis service (main model). Rebuilt on
    /// demand — the stop path can run after live state was reset.
    private var sessionSynthesis: ShareSessionSynthesisService?
    /// How much of `screenObservationLog` the rolling analysis has already
    /// seen — advances only after a successful pass.
    private var lastSentObservationIndex = 0

    // Transcription
    private let coordinator = TranscriptionCoordinator()
    private let vocabularyManager = VocabularyManager()
    let speakerContactMapper = SpeakerContactMapper()

    // Calendar & Meeting Prep
    let calendarService = CalendarService()
    private let meetingPrepService = MeetingPrepService()

    /// Set after record-start when more than one calendar event sits within the
    /// match window. The app root observes this and presents a picker so the
    /// user can choose which meeting this recording belongs to. Empty means no
    /// choice is pending (zero or exactly one nearby event).
    var pendingCalendarChoices: [CalendarEvent] = []

    /// Calendar events near *now*, surfaced on the idle screen so the user can
    /// confirm which meeting they're about to record. Empty when calendar
    /// integration is off or nothing is nearby.
    var candidateEvents: [CalendarEvent] = []

    /// The meeting the user chose (or a lone candidate auto-picked) on the idle
    /// screen. Drives both the prep card and the record-start link, so we never
    /// guess silently or ask twice.
    var selectedEvent: CalendarEvent?

    /// True when the user explicitly chose "Not a calendar meeting", so
    /// record-start must not silently fall back to auto-matching.
    private(set) var calendarSelectionCleared = false

    // Auto-detection of external meeting activity (Teams/Zoom/etc.)
    let meetingDetector = MeetingDetectionService()
    private var autoDetectionConfigured = false

    // AI Intelligence
    private var intelligenceService: AIIntelligenceService?
    private var aiModelIdentifier: String?
    /// Raw response from the most recent successful AI analysis (rolling or final).
    /// Persisted alongside the final MeetingInsight for debugging and replay.
    private var latestRawResponse: String?

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }

    /// Load nearby calendar events for the idle screen and choose a default
    /// selection. Exactly one candidate auto-selects (the unambiguous case);
    /// zero or 2+ leave the choice to the user — a conflict we must not resolve
    /// silently. Honors an explicit "Not a calendar meeting".
    func refreshCalendarCandidates(in modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: "calendarIntegration") else {
            candidateEvents = []
            selectedEvent = nil
            prepContext = nil
            return
        }
        if calendarService.authorizationState != .authorized {
            await calendarService.requestAccess()
        }
        candidateEvents = await calendarService.eventsInWindow(minutes: 60)
        if candidateEvents.count == 1, selectedEvent == nil, !calendarSelectionCleared {
            selectEvent(candidateEvents[0], in: modelContext)
        } else if selectedEvent == nil {
            // 0 or 2+ with nothing chosen yet → no prep until the user picks.
            prepContext = nil
        }
    }

    /// Choose (or re-choose) the meeting being prepped/recorded; regenerates prep.
    func selectEvent(_ event: CalendarEvent, in modelContext: ModelContext) {
        selectedEvent = event
        calendarSelectionCleared = false
        refreshPrepContext(in: modelContext)
    }

    /// Explicit "Not a calendar meeting": clears the selection + prep and
    /// suppresses record-start auto-matching for this idle session.
    func clearSelectedEvent() {
        selectedEvent = nil
        calendarSelectionCleared = true
        prepContext = nil
    }

    /// Undo a clear, re-offering the chooser (or auto-picking a lone candidate).
    func reopenCalendarSelection(in modelContext: ModelContext) {
        calendarSelectionCleared = false
        if candidateEvents.count == 1 {
            selectEvent(candidateEvents[0], in: modelContext)
        }
    }

    /// Rebuild the prep card for the currently `selectedEvent` (if any). Prep is
    /// drawn only from prior recorded occurrences of the *same* recurring meeting
    /// (resolved inside the service) — never from unrelated meetings that merely
    /// share attendees.
    func refreshPrepContext(in modelContext: ModelContext) {
        guard let event = selectedEvent else {
            prepContext = nil
            return
        }
        prepContext = meetingPrepService.gatherPrepContext(for: event, in: modelContext)
    }

    /// Apply a calendar event's metadata (title, attendees, series) to a meeting.
    /// Used both at record-start (auto-match from `currentOrUpcomingEvent`) and
    /// from the toolbar's manual picker when the user wants to override or
    /// supply a match the auto-detector missed.
    func applyCalendarMatch(
        event: CalendarEvent,
        to meeting: Meeting,
        in modelContext: ModelContext,
        source: String
    ) {
        // At record-start the recording adopts the event's title; attendee +
        // series matching lives in CalendarService.linkEvent (shared with the
        // post-hoc "link a past meeting" flow).
        calendarService.linkEvent(event, to: meeting, in: modelContext, setTitle: true)
        speakerContactMapper.prepopulate(from: meeting.attendees)
    }

    /// Manual variant invoked from the recording toolbar. Operates on the
    /// in-progress `currentMeeting` and persists immediately so a crash
    /// before the next periodic save doesn't drop the user's choice.
    func matchCalendarEventManually(_ event: CalendarEvent, in modelContext: ModelContext) {
        guard let meeting = currentMeeting else { return }
        applyCalendarMatch(event: event, to: meeting, in: modelContext, source: "manual")
        PersistenceGate.save(
            modelContext,
            site: "matchCalendarEventManually",
            meetingID: meeting.id
        )
    }

    /// Cancel the calendar association on the in-progress recording. Clears the
    /// event linkage and restores the auto-generated title (or lets the next
    /// analysis pass generate one).
    func unlinkCalendarEvent(in modelContext: ModelContext) {
        guard let meeting = currentMeeting else { return }
        meeting.unlinkCalendarEvent()
        // The event's attendees were just pruned; rebuild the speaker mappings
        // from scratch so aliases of removed contacts stop claiming speakers.
        speakerContactMapper.reset()
        speakerContactMapper.prepopulate(from: meeting.attendees)
        log.log("Calendar event unlinked from recording", category: .general)
        PersistenceGate.save(
            modelContext,
            site: "unlinkCalendarEvent",
            meetingID: meeting.id
        )
    }

    var formattedTime: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Check if there's an interrupted recording from a previous session.
    static func interruptedMeetingID() -> UUID? {
        guard let str = UserDefaults.standard.string(forKey: "activeRecordingMeetingID") else { return nil }
        return UUID(uuidString: str)
    }

    /// Resume recording on a previously interrupted meeting.
    func resumeInterruptedRecording(meeting: Meeting, in modelContext: ModelContext) {
        self.modelContext = modelContext
        currentMeeting = meeting
        meeting.status = .recording

        // Restore persisted segments into the in-memory array
        let sorted = meeting.segments.sorted { $0.startTime < $1.startTime }
        segments = sorted
        lastPersistedSegmentCount = sorted.count

        // Resume timer from where it left off
        let previousDuration = meeting.duration
        state = .recording
        elapsedTime = previousDuration
        recordingStartDate = Date().addingTimeInterval(-previousDuration)
        accumulatedPauseDuration = 0
        pauseStartDate = nil
        actionItems = []
        followUpQuestions = []
        topics = []
        streamingSummary = ""
        errorMessage = nil
        completedMeeting = nil
        audioWriteFailures = 0
        lastAudioWriteError = nil

        // Re-populate speaker mapper from attendees
        speakerContactMapper.prepopulate(from: meeting.attendees)

        log.log("Resuming interrupted recording (\(sorted.count) existing segments, \(meeting.formattedDuration) elapsed)", category: .audio)

        // Validate any audio chunks left on disk from the interrupted session.
        // Broken (unfinalized) chunks are renamed to .corrupted so they're
        // preserved for forensic recovery but excluded from playback.
        // AudioFileWriter.start will scan existing valid chunks and resume
        // writing at the next index, so prior audio is never truncated.
        let storageManager = StorageManager.shared
        let micBase = storageManager.micAudioURL(for: meeting.id)
        let sysBase = storageManager.systemAudioURL(for: meeting.id)
        Task.detached {
            _ = await AudioChunkValidator.validateChunks(base: micBase)
            _ = await AudioChunkValidator.validateChunks(base: sysBase)
        }

        startTimer()
        startRealCapture(meetingID: meeting.id)
        startIntelligenceService()
        startPeriodicPersistence()
        startScreenShareCapture(meetingID: meeting.id)
    }

    /// Resolves the context for callbacks that outlive a single view update.
    private var modelContextProvider: (@MainActor () -> ModelContext?)?

    /// Name of the app whose call is awaiting an answer. Non-nil puts the
    /// prompt bar on screen and an item in the menu bar; cleared when
    /// answered, when the call ends, or when a recording starts by any route.
    var pendingCallPromptApp: String?

    /// The in-app state and the notification are one question, so they are
    /// always withdrawn together — every exit path goes through here rather
    /// than remembering both halves.
    private func clearCallPrompt() {
        pendingCallPromptApp = nil
        CallPromptService.shared.dismissPrompt()
    }

    /// Start recording the call we asked about. Registered as an auto-start so
    /// it still stops on its own when the call ends.
    func acceptCallPrompt(in modelContext: ModelContext) {
        // startRecording clears the prompt itself.
        guard state == .idle else { return clearCallPrompt() }
        startRecording(in: modelContext, autoDetected: true)
    }

    /// Decline for this call. The detector re-arms when the app releases the
    /// mic, so the next call asks again.
    func dismissCallPrompt() {
        clearCallPrompt()
        log.log("Call prompt dismissed by user", category: .audio)
    }

    /// Wires detector callbacks once; safe to call repeatedly.
    func configureAutoDetection(enabled: Bool, modelContextProvider: @escaping @MainActor () -> ModelContext?) {
        if !autoDetectionConfigured {
            meetingDetector.onStartRequested = { [weak self] in
                guard let self, let ctx = modelContextProvider() else { return }
                self.startRecording(in: ctx, autoDetected: true)
            }
            meetingDetector.onStopRequested = { [weak self] in
                guard let self, let ctx = modelContextProvider() else { return }
                CallPromptService.shared.dismissPrompt()
                self.stopRecording(in: ctx, autoDetected: true)
            }
            // Apps that hold the mic outside of calls ask first. Accepting
            // starts an *auto* recording, so it still stops on its own when
            // the call ends.
            //
            // Asked two ways on purpose: a notification (you are in the other
            // app, not this one) and in-app UI. Notification delivery depends
            // on system permission and can simply not arrive, and a prompt you
            // never see is the same as no feature at all.
            meetingDetector.onConfirmationRequested = { [weak self] holder in
                let appName = holder.appName ?? "Call"
                self?.pendingCallPromptApp = appName
                CallPromptService.shared.promptToRecord(appName: appName)
            }
            meetingDetector.onConfirmationExpired = { [weak self] in
                self?.clearCallPrompt()
            }
            // Capture only `self` weakly: CallPromptService is a process-
            // lifetime singleton, and capturing the context provider here
            // would pin a live ModelContext for the whole run.
            self.modelContextProvider = modelContextProvider
            CallPromptService.shared.onStartRequested = { [weak self] in
                guard let self, let ctx = self.modelContextProvider?() else { return }
                self.acceptCallPrompt(in: ctx)
            }
            autoDetectionConfigured = true
        }
        setAutoDetectionEnabled(enabled)
    }

    func setAutoDetectionEnabled(_ enabled: Bool) {
        if enabled {
            meetingDetector.enable(currentlyRecording: state != .idle)
        } else {
            meetingDetector.disable()
        }
    }

    func startRecording(in modelContext: ModelContext, autoDetected: Bool = false, resuming existing: Meeting? = nil) {
        // Guard against rapid double-click / stale UI triggering two starts in
        // a row. If we're already recording or paused, ignore silently and log
        // — creating a second meeting on top of a live one corrupts segment
        // attribution and leaks audio files.
        guard state == .idle else {
            log.log("startRecording ignored: already in state \(state)", category: .audio, level: .warning)
            return
        }

        // The previous recording's audio teardown is still in flight. `state` is
        // already `.idle` during that window, so the check above doesn't catch
        // it — but starting now would have the new recording and the old
        // teardown both driving the shared capture/coordinator actors. Refuse
        // until the (fast) teardown clears the flag.
        guard !isFinishing else {
            log.log("startRecording ignored: still finishing the previous recording", category: .audio, level: .warning)
            errorMessage = "Finishing the previous recording — try again in a moment."
            return
        }

        meetingDetector.noteStart(autoDetected ? .auto : .manual)
        autoDetectedRecordingStart = autoDetected
        // However the recording began, the question is answered.
        clearCallPrompt()

        let meeting: Meeting
        if let existing {
            meeting = existing
            log.log("Recording resumed into existing meeting \(existing.id)", category: .audio)
        } else {
            meeting = Meeting(title: "Meeting \(DateFormatter.shortDate.string(from: .now))")

            // Which app is this call in? Best-effort provenance — a solo
            // recording legitimately has no other app holding the mic. The
            // detector's poll (≤5s old) is preferred over a fresh Core Audio
            // enumeration, which would run inline on the record-start path
            // for a field that is pure metadata.
            let holders = meetingDetector.isPolling
                ? meetingDetector.currentHolders
                : meetingDetector.snapshotHolders()
            if let source = holders.first {
                meeting.sourceAppBundleID = source.bundleID
                meeting.sourceAppName = source.appName
                log.log("Recording source app: \(source.appName ?? source.bundleID ?? "unknown")", category: .audio)
            }

            // Calendar linking runs after the recording is live (see
            // matchCalendarAtStart) so a network fetch (Microsoft Graph) never
            // delays the start of capture.

            // Always add "me" as an attendee — the user must be present to record.
            let myContactIDString = UserDefaults.standard.string(forKey: "myContactID") ?? ""
            if let myID = UUID(uuidString: myContactIDString),
               !meeting.attendees.contains(where: { $0.id == myID }) {
                let descriptor = FetchDescriptor<Contact>(predicate: #Predicate { $0.id == myID })
                if let me = try? modelContext.fetch(descriptor).first {
                    meeting.attendees.append(me)
                }
            }

            modelContext.insert(meeting)
            // Persist the meeting row immediately so a crash within the first 10s
            // (before the periodic save fires) doesn't leave audio on disk with
            // no SwiftData row to claim it. The lock file below is the second
            // safety net, but only the row guarantees the audio won't be purged
            // as orphan on next launch.
            PersistenceGate.save(
                modelContext,
                site: "startRecording/insert",
                critical: true,
                meetingID: meeting.id
            )
        }
        self.modelContext = modelContext
        currentMeeting = meeting
        state = .recording
        elapsedTime = 0
        recordingStartDate = Date()
        accumulatedPauseDuration = 0
        pauseStartDate = nil
        if existing != nil {
            let saved = meeting.segments.sorted { $0.startTime < $1.startTime }
            segments = saved
            lastPersistedSegmentCount = saved.count
        } else {
            lastPersistedSegmentCount = 0
            segments = []
        }
        segmentSectionTags = [:]
        actionItems = []
        followUpQuestions = []
        topics = []
        streamingSummary = ""
        errorMessage = nil
        completedMeeting = nil
        audioWriteFailures = 0
        lastAudioWriteError = nil
        lastSystemAudioActivityAt = nil

        // Persist active recording ID so we can detect interrupted recordings on restart.
        // Two-layer breadcrumb: UserDefaults for fast lookup, lock file on disk as a
        // fallback in case UserDefaults is cleared. The lock file also makes the
        // in-progress state visible to the user in Finder.
        UserDefaults.standard.set(meeting.id.uuidString, forKey: "activeRecordingMeetingID")
        RecordingLockFile.write(for: meeting.id, isInterviewMeeting: meeting.isInterviewMeeting)

        log.log("Recording started", category: .audio)
        // Free up the ANE / CPU for live transcription — any in-flight
        // re-processing job stays mid-transcribe for minutes otherwise.
        ReProcessingQueue.shared.yieldToLiveRecording()
        startTimer()
        startRealCapture(meetingID: meeting.id)
        startIntelligenceService()
        startPeriodicPersistence()
        startScreenShareCapture(meetingID: meeting.id)

        if existing == nil {
            matchCalendarAtStart(for: meeting, in: modelContext)
        }
    }

    /// Fetch nearby calendar events (local + Microsoft Graph) and link the
    /// in-progress recording — one match auto-links, several raise the picker.
    /// Runs as a detached task so a network fetch never delays record-start.
    private func matchCalendarAtStart(for meeting: Meeting, in modelContext: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "calendarIntegration") else {
            log.log("Calendar match skipped: calendarIntegration toggle is off", category: .general)
            return
        }
        // The user already chose (or declined) a meeting on the idle screen —
        // honor it instead of re-fetching and risking a different pick.
        if let chosen = selectedEvent {
            applyCalendarMatch(event: chosen, to: meeting, in: modelContext, source: "idle-selection")
            PersistenceGate.save(modelContext, site: "matchCalendarAtStart", meetingID: meeting.id)
            return
        }
        if calendarSelectionCleared {
            log.log("Calendar match skipped: user chose 'Not a calendar meeting'", category: .general)
            return
        }
        // No idle selection (e.g. started from the menu bar or auto-detector):
        // fetch nearby and either auto-link the single match or raise the picker.
        let meetingID = meeting.id
        Task { @MainActor in
            if calendarService.authorizationState != .authorized {
                await calendarService.requestAccess()
            }
            let nearby = await calendarService.eventsInWindow(minutes: 60)
            // Bail if the user stopped/started a different recording meanwhile.
            guard let current = currentMeeting, current.id == meetingID else { return }
            if nearby.count == 1 {
                applyCalendarMatch(event: nearby[0], to: current, in: modelContext, source: "auto")
                PersistenceGate.save(modelContext, site: "matchCalendarAtStart", meetingID: current.id)
            } else if nearby.count > 1 {
                pendingCalendarChoices = nearby
                log.log("Calendar: \(nearby.count) events within ±60m — prompting user to pick", category: .general)
            } else {
                log.log("Calendar match: no event within ±60m of recording start", category: .general)
            }
        }
    }

    func pauseRecording() {
        state = .paused
        timer?.invalidate()
        pauseStartDate = Date()
        Task {
            await micCapture.suspendCapture()
            await systemCapture.suspendCapture()
            await screenCapture.suspend()
        }
        log.log("Recording paused", category: .audio)
    }

    func resumeRecording() {
        // Accumulate the pause duration before restarting timer
        if let pauseStart = pauseStartDate {
            accumulatedPauseDuration += Date().timeIntervalSince(pauseStart)
            pauseStartDate = nil
        }
        state = .recording
        startTimer()
        let keepScreenCapturePaused = screenCaptureUserPaused
        Task {
            await micCapture.resumeCapture()
            await systemCapture.resumeCapture()
            if !keepScreenCapturePaused {
                await screenCapture.resume()
            }
        }
        log.log("Recording resumed", category: .audio)
    }

    /// Termination-time flush. Stops audio capture, finalizes the m4a file,
    /// drains the recognition coordinator, and persists whatever segments are
    /// in memory — but skips the final AI analysis because it can take up to
    /// 90 seconds and shouldn't hold up app quit. Designed to be called from
    /// `applicationShouldTerminate` with a hard ~5s timeout on the caller side.
    /// Returns once the audio + transcript are durable on disk.
    func flushForTermination() async {
        guard let meeting = currentMeeting else { return }
        let meetingID = meeting.id
        timer?.invalidate()
        timer = nil

        for task in processingTasks {
            task.cancel()
        }
        processingTasks = []
        intelligenceService = nil

        await micCapture.stopCapture()
        await systemCapture.stopCapture()
        await screenCapture.stop()
        let micWriter = self.micFileWriter
        let sysWriter = self.systemFileWriter
        self.micFileWriter = nil
        self.systemFileWriter = nil
        await micWriter?.stop()
        await sysWriter?.stop()
        await coordinator.stop()

        let rawSegments = self.coordinator.segments
        let dedupResult = TranscriptDeduplicator.deduplicate(rawSegments)
        self.segments = dedupResult.segments

        guard let context = self.modelContext else { return }

        for existing in meeting.segments {
            context.delete(existing)
        }
        meeting.segments.removeAll()

        for segment in self.segments {
            let persisted = TranscriptSegment(
                speaker: segment.speaker,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                isFinal: true
            )
            persisted.confidence = self.segmentConfidence[segment.id] ?? 1.0
            persisted.sectionTag = segment.sectionTag
            persisted.sectionTagID = segment.sectionTagID
            persisted.meeting = meeting
            meeting.segments.append(persisted)
        }

        flushPendingScreenFrames(to: meeting)

        // The meeting stays `.recording` so launch-time orphan recovery picks
        // it up and marks it `(interrupted)` — that's the contract for an
        // unexpected exit. Quitting mid-recording shouldn't pretend the
        // meeting completed cleanly.
        PersistenceGate.save(
            context,
            site: "flushForTermination",
            critical: true,
            meetingID: meetingID
        )
    }

    func stopRecording(in modelContext: ModelContext, autoDetected: Bool = false) {
        // Re-entrancy guard: a second stop (rapid double-click, or an auto-stop
        // racing a manual one) would tear down the capture actors twice and
        // double-persist. Ignore once we've left the recording/paused states.
        guard state == .recording || state == .paused else {
            log.log("stopRecording ignored: state is \(state)", category: .audio, level: .warning)
            return
        }

        meetingDetector.noteStop(autoDetected ? .auto : .manual)

        state = .idle
        aiActivityState = .idle
        // Block a new recording from starting until the audio teardown below
        // finishes (cleared in the async task / no-meeting path). See `isFinishing`.
        isFinishing = true
        timer?.invalidate()
        timer = nil

        // Clear active recording marker (both layers). The lock file is
        // removed here so a clean stop produces a quiet directory on disk.
        UserDefaults.standard.removeObject(forKey: "activeRecordingMeetingID")
        if let meetingID = currentMeeting?.id {
            RecordingLockFile.remove(for: meetingID)
        }
        self.modelContext = modelContext

        // Cancel all processing tasks
        for task in processingTasks {
            task.cancel()
        }
        processingTasks = []

        let service = intelligenceService
        intelligenceService = nil
        let frameService = frameAnalysis
        frameAnalysis = nil

        guard let meeting = currentMeeting else {
            // No meeting — just clean up
            let micWriter = micFileWriter
            let sysWriter = systemFileWriter
            micFileWriter = nil
            systemFileWriter = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.micCapture.stopCapture()
                await self.systemCapture.stopCapture()
                await self.screenCapture.stop()
                await micWriter?.stop()
                await sysWriter?.stop()
                await self.coordinator.stop()
                self.resetLiveStateAfterStop()
                self.isFinishing = false
            }
            return
        }

        meeting.status = .completed
        meeting.duration = elapsedTime

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Stop audio capture first (no more audio flowing in)
            await micCapture.stopCapture()
            await systemCapture.stopCapture()
            let finalMicWriter = self.micFileWriter
            let finalSysWriter = self.systemFileWriter
            self.micFileWriter = nil
            self.systemFileWriter = nil
            await finalMicWriter?.stop()
            await finalSysWriter?.stop()

            // Stop screen capture — ends any open share session and finishes
            // the event stream. Frames already received are flushed below.
            await screenCapture.stop()

            // Stop coordinator — drains remaining recognition results and diarization
            await coordinator.stop()

            // Read segments AFTER coordinator is fully stopped
            let rawSegments = self.coordinator.segments
            self.log.log("Recording stopped (\(rawSegments.count) raw segments)", category: .audio)

            // Deduplicate mic echo segments before persisting
            let dedupResult = TranscriptDeduplicator.deduplicate(rawSegments)
            let finalSegments = dedupResult.segments
            if dedupResult.removedCount > 0 {
                self.log.log("Deduplication removed \(dedupResult.removedCount) echo segment(s)", category: .transcription)
            }
            let confidence = self.segmentConfidence

            // Remove any incrementally-persisted segments, then save the final deduped set
            for existing in meeting.segments {
                modelContext.delete(existing)
            }
            meeting.segments.removeAll()

            for segment in finalSegments {
                let persistedSegment = TranscriptSegment(
                    speaker: segment.speaker,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    isFinal: true
                )
                persistedSegment.confidence = confidence[segment.id] ?? 1.0
                persistedSegment.sectionTag = segment.sectionTag
                persistedSegment.sectionTagID = segment.sectionTagID
                persistedSegment.meeting = meeting
                meeting.segments.append(persistedSegment)
            }

            self.flushPendingScreenFrames(to: meeting)

            let finalSegmentsOK = PersistenceGate.save(
                modelContext,
                site: "stopRecording/finalSegments",
                critical: true,
                meetingID: meeting.id
            )
            if !finalSegmentsOK {
                self.errorMessage = "Failed to save final transcript. The recording files are preserved on disk; please check disk space and retry export."
            }

            // Mark as analyzing before navigating so the UI shows a spinner
            meeting.isAnalyzing = true
            PersistenceGate.save(
                modelContext,
                site: "stopRecording/markAnalyzing",
                critical: false,
                meetingID: meeting.id
            )

            // Capture the transcript + rolling-analysis results into locals
            // BEFORE clearing live state, so the final-analysis pass below runs
            // entirely off captured values. This decoupling is what lets us
            // reset the view model now — clearing the stale transcript and
            // letting a new recording start — without the in-flight analysis
            // clobbering it.
            let finalSnapshots = finalSegments.map { seg in
                SegmentSnapshot(
                    speaker: seg.speaker,
                    text: seg.text,
                    formattedTimestamp: seg.formattedTimestamp,
                    isFinal: seg.isFinal,
                    startTime: seg.startTime
                )
            }
            var resultSummary = self.streamingSummary
            var resultActionItems = self.actionItems
            var resultFollowUps = self.followUpQuestions
            var resultTopics = self.topics
            var resultRaw = self.latestRawResponse
            let modelID = self.aiModelIdentifier
            var observationsAtStop = self.screenObservationLog

            // The transcript is durable and the rolling insights are captured,
            // and the audio actors are stopped — so the live view-model state is
            // now safe to clear. Releasing the finishing gate lets the user
            // start a new recording while the (slow) final analysis continues
            // below on the captured locals.
            self.resetLiveStateAfterStop()
            self.isFinishing = false

            // Navigate to completed meeting
            self.completedMeeting = meeting

            // Best-effort final screen-frame batch — the last captured
            // changes get their observations before the final transcript
            // pass runs, so it can see them. Failure just leaves OCR-only
            // frames.
            if let frameService {
                let batch = await frameService.analyzePendingBatch(recentTopics: resultTopics)
                self.applyFrameAnalysis(batch, to: meeting)
                observationsAtStop.append(contentsOf: batch.observations)
                if !batch.observations.isEmpty {
                    PersistenceGate.save(
                        modelContext,
                        site: "stopRecording/frameObservations",
                        critical: false,
                        meetingID: meeting.id
                    )
                }
            }

            // Sweep every share session that still lacks a narrative —
            // including the one open at stop — so the final analysis
            // receives session recaps instead of raw bullets. Failures
            // simply leave that session on per-frame fallback lines.
            let unsummarizedSessions = Set(meeting.screenFrames.map(\.sessionID))
                .subtracting(meeting.sessionSummaries.map(\.sessionID))
            for sessionID in unsummarizedSessions {
                _ = await self.synthesizeSession(sessionID: sessionID, meeting: meeting, segments: finalSnapshots)
            }

            // Try final AI analysis (may fail or return nil — that's OK)
            if let service {
                do {
                    let roster = MeetingRoster.snapshot(for: meeting)
                    let screenBlock = ScreenObservationFormatter.finalBlock(for: meeting)
                        ?? ScreenObservationFormatter.finalBlock(observationsAtStop)
                    if screenBlock != nil {
                        self.log.log("Injecting screen context into final analysis (\(meeting.sessionSummaries.count) recap(s), \(observationsAtStop.count) live observation(s))", category: .screen)
                    }
                    if let result = try await service.performFinalAnalysis(
                        segments: finalSnapshots,
                        roster: roster,
                        screenObservations: screenBlock
                    ) {
                        resultSummary = result.summary
                        resultActionItems = result.actionItems.map { parsed in
                            ActionItem(parsed: parsed, sourceSegments: meeting.segments)
                        }
                        resultFollowUps = result.followUps
                        resultTopics = result.topics
                        resultRaw = result.rawResponse
                        if let title = result.title {
                            meeting.applyGeneratedTitle(title)
                        }
                    }
                } catch is CancellationError {
                    // App quitting / teardown raced — not a real analysis failure.
                    self.log.log("Final analysis cancelled — keeping rolling insights", category: .ai)
                } catch {
                    meeting.analysisError = error.localizedDescription
                    self.log.log("Final analysis failed (persisting existing insights): \(error.localizedDescription)", category: .ai, level: .warning)
                }
            }

            // Analysis complete
            meeting.isAnalyzing = false

            // Always persist whatever insights we have (final pass, or the
            // rolling-analysis fallback captured above).
            if !resultSummary.isEmpty {
                let insight = MeetingInsight(
                    summary: resultSummary,
                    followUpQuestions: resultFollowUps,
                    topics: resultTopics,
                    rawLLMResponse: resultRaw,
                    modelIdentifier: modelID,
                    promptVersion: AIPromptTemplates.promptVersion
                )
                insight.meeting = meeting
                meeting.insights.append(insight)

                for actionItem in resultActionItems {
                    actionItem.meeting = meeting
                    meeting.actionItems.append(actionItem)
                }

                let insightsOK = PersistenceGate.save(
                    modelContext,
                    site: "stopRecording/finalInsights",
                    critical: true,
                    meetingID: meeting.id
                )
                if !insightsOK {
                    // Surface on the meeting itself (we've already navigated away
                    // from the recording screen, so the VM's errorMessage banner
                    // wouldn't be visible). The detail view shows analysisError.
                    meeting.analysisError = "Failed to save AI insights — the transcript is saved; use Reanalyze to retry."
                    self.log.log("Failed to save AI insights for \(meeting.id) — transcript is saved; Reanalyze available from the meeting detail view", category: .ai, level: .warning)
                }
            }

            // Index the meeting for semantic search using the live (fast)
            // transcript. If re-transcription is enabled, the queued
            // re-processing pass will replace these embeddings with ones
            // derived from the high-accuracy transcript when it completes.
            if let store = EmbeddingStore.shared {
                let providerRaw = UserDefaults.standard.string(forKey: "embeddingProvider") ?? EmbeddingProvider.nlEmbedding.rawValue
                let provider = EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
                let indexer = EmbeddingIndexer(store: store, service: provider.makeService())
                Task { @MainActor in
                    await indexer.indexMeeting(meeting)
                }
            }

            // Mark the live transcription quality and queue the meeting for
            // high-accuracy re-processing (unless disabled in settings).
            if meeting.transcriptionModel == nil {
                meeting.transcriptionModel = "fluidaudio-parakeet-v2"
            }
            let autoReprocess = UserDefaults.standard.object(forKey: "autoReprocessMeetings") as? Bool ?? true
            if autoReprocess {
                ReProcessingQueue.shared.enqueue(meetingID: meeting.id)
            }
        }
    }

    /// Clear the transient live-recording state once a recording has been
    /// stopped and its transcript persisted. Leaves the recording screen in a
    /// clean "ready to record" state (no stale transcript / insights) and
    /// releases references to the finished meeting. Deliberately does NOT touch
    /// `errorMessage` (a save failure set during teardown should stay visible)
    /// or `aiModelIdentifier` (captured into a local before this is called).
    private func resetLiveStateAfterStop() {
        segments = []
        segmentConfidence = [:]
        segmentSectionTags = [:]
        streamingSummary = ""
        actionItems = []
        followUpQuestions = []
        topics = []
        latestRawResponse = nil
        currentMeeting = nil
        elapsedTime = 0
        lastPersistedSegmentCount = 0
        prepContext = nil
        pendingCalendarChoices = []
        candidateEvents = []
        selectedEvent = nil
        calendarSelectionCleared = false
        currentSectionTag = nil
        currentSectionTagID = nil
        aiActivityState = .idle
        screenCaptureState = .off
        screenShareFrameCount = 0
        screenShareCandidates = []
        screenShareLatestFramePath = nil
        screenShareLatestFrameAt = nil
        screenCaptureUserPaused = false
        pendingScreenFrames = []
        frameAnalysis = nil
        screenObservationLog = []
        lastSentObservationIndex = 0
        budgetRefusedFrameIDs = []
        endedSessionsAwaitingSynthesis = []
        pendingRecapBlocksForRolling = []
        sessionSynthesis = nil
    }

    // MARK: - Screen-Share Capture

    /// Start watching for a popped-out share window. No-op when the feature
    /// is disabled. The consumer task joins `processingTasks` so stop/flush
    /// cancels it uniformly with everything else.
    private func startScreenShareCapture(meetingID: UUID) {
        guard ScreenShareSettings.isEnabled else { return }
        let service = screenCapture
        let config = ScreenShareCaptureService.Config(
            intervalSeconds: ScreenShareSettings.intervalSeconds,
            autoDetect: ScreenShareSettings.autoDetect,
            changeThreshold: ScreenShareSettings.changeThreshold,
            maxKeptFrames: ScreenShareSettings.maxKeptFrames
        )
        let task = Task { [weak self] in
            guard let self else { return }
            let stream = await service.start(meetingID: meetingID, config: config)
            await MainActor.run { self.screenCaptureState = .watching }
            for await event in stream {
                if Task.isCancelled { break }
                await MainActor.run { self.handleScreenCaptureEvent(event) }
            }
        }
        processingTasks.append(task)
        startScreenFrameAnalysis(meetingID: meetingID)
    }

    /// Build the vision analysis service and its cadence loop. Degrades to
    /// capture-only (frames keep OCR text) when analysis is off, the AI is
    /// unconfigured, or the provider can't send images.
    private func startScreenFrameAnalysis(meetingID: UUID) {
        guard ScreenShareSettings.analysisEnabled else { return }
        let maxAnalyzed = ScreenShareSettings.maxAnalyzedFrames
        let task = Task { [weak self] in
            let client: any AIClient
            do {
                guard let made = try await AIClientFactory.makeFrameAnalysisClient() else {
                    LogManager.send("Screen-frame analysis skipped: no API key configured", category: .screen, level: .warning, meetingID: meetingID)
                    return
                }
                client = made
            } catch {
                LogManager.send("Screen-frame analysis skipped: AI client failed — \(error.localizedDescription)", category: .screen, level: .warning, meetingID: meetingID)
                return
            }
            guard client.supportsImages else {
                LogManager.send("Screen-frame analysis skipped: \(client.modelIdentifier) has no image support", category: .screen, level: .warning, meetingID: meetingID)
                return
            }
            let service = ScreenFrameAnalysisService(
                client: client,
                meetingID: meetingID,
                maxAnalyzedPerMeeting: maxAnalyzed
            )
            await MainActor.run { self?.frameAnalysis = service }

            // Offset from the transcript loop's 30s/45s cadence so screen
            // observations land between rolling passes.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                if await MainActor.run(body: { self?.state == .recording }) {
                    let topics = await MainActor.run { self?.topics ?? [] }
                    let result = await service.analyzePendingBatch(recentTopics: topics)
                    await MainActor.run { self?.applyFrameAnalysis(result) }
                    await self?.synthesizeEligibleEndedSessions()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        processingTasks.append(task)
    }

    /// Write a batch's outcomes onto the persisted rows and the observation
    /// log. Rows are matched by frame ID; the 10s persistence loop has long
    /// since flushed them by the time a 60s-cadence batch returns.
    private func applyFrameAnalysis(_ result: ScreenFrameAnalysisService.BatchResult) {
        guard let meeting = currentMeeting else { return }
        applyFrameAnalysis(result, to: meeting)
        screenObservationLog.append(contentsOf: result.observations)
    }

    /// Row-only application — does NOT touch the live observation log, so
    /// the stop path can apply its final batch after live state is reset.
    private func applyFrameAnalysis(_ result: ScreenFrameAnalysisService.BatchResult, to meeting: Meeting) {
        guard !result.observations.isEmpty || !result.failedIDs.isEmpty || !result.skippedIDs.isEmpty else { return }
        var rowsByID: [UUID: ScreenShareFrame] = [:]
        for row in meeting.screenFrames {
            rowsByID[row.id] = row
        }
        for observation in result.observations {
            guard let row = rowsByID[observation.frameID] else { continue }
            row.observation = observation.observation
            row.contentTypeRaw = observation.contentType
            row.keyEntities = observation.keyEntities
            row.analysisState = .analyzed
            row.analysisModelIdentifier = result.modelIdentifier
        }
        for id in result.failedIDs {
            rowsByID[id]?.analysisState = .failed
        }
        for id in result.skippedIDs {
            rowsByID[id]?.analysisState = .skipped
        }
        if !result.observations.isEmpty {
            log.log("Applied \(result.observations.count) screen observation(s)", category: .screen)
        }
    }

    // MARK: - Session narrative synthesis

    /// Synthesize narratives for ended sessions whose frames are all done
    /// with vision analysis. Runs from the 60s frame loop; the stop path
    /// sweeps whatever remains (including the session still open at stop).
    private func synthesizeEligibleEndedSessions() async {
        guard !endedSessionsAwaitingSynthesis.isEmpty, let meeting = currentMeeting else { return }
        for sessionID in Array(endedSessionsAwaitingSynthesis) {
            // Frames still buffered for the 10s persistence loop, or still
            // pending vision — try again next tick.
            guard !pendingScreenFrames.contains(where: { $0.0.sessionID == sessionID }) else { continue }
            let frames = meeting.screenFrames.filter { $0.sessionID == sessionID }
            guard !frames.isEmpty else {
                endedSessionsAwaitingSynthesis.remove(sessionID)  // session left no kept frames
                continue
            }
            guard !frames.contains(where: { $0.analysisState == .pendingVision }) else { continue }

            endedSessionsAwaitingSynthesis.remove(sessionID)
            if let narrative = await synthesizeSession(sessionID: sessionID, meeting: meeting, segments: snapshotSegments()) {
                let span = ShareSessionSynthesisService.span(
                    start: frames.map(\.timestamp).min() ?? 0,
                    end: frames.map(\.timestamp).max() ?? 0
                )
                pendingRecapBlocksForRolling.append(
                    "Recap of the share that just ended (\(span)):\n\(narrative.narrative)"
                )
            }
        }
    }

    /// Synthesize and persist one session's narrative. Returns nil when the
    /// session has nothing analyzed, already has a summary, or synthesis
    /// fails — every nil degrades to the per-frame fallback in the final
    /// block. The summary row's `.unique` sessionID is the exactly-once
    /// backstop if two paths race.
    private func synthesizeSession(
        sessionID: UUID,
        meeting: Meeting,
        segments: [SegmentSnapshot]
    ) async -> ShareSessionSynthesisService.SessionNarrative? {
        guard !meeting.sessionSummaries.contains(where: { $0.sessionID == sessionID }) else { return nil }
        let frames = meeting.screenFrames.filter { $0.sessionID == sessionID }
        let observations: [ShareSessionSynthesisService.FrameObservationLine] = frames.compactMap { row in
            guard let text = row.observation, !text.isEmpty else { return nil }
            return ShareSessionSynthesisService.FrameObservationLine(
                timestamp: row.timestamp,
                formattedTimestamp: row.formattedTimestamp,
                observation: text
            )
        }
        guard !observations.isEmpty else { return nil }

        let startTime = frames.map(\.timestamp).min() ?? 0
        let endTime = frames.map(\.timestamp).max() ?? startTime
        let input = ShareSessionSynthesisService.makeInput(
            sessionID: sessionID,
            meetingID: meeting.id,
            windowTitle: frames.first?.windowTitle,
            startTime: startTime,
            endTime: endTime,
            observations: observations,
            segments: segments
        )

        let service: ShareSessionSynthesisService
        if let existing = sessionSynthesis {
            service = existing
        } else {
            guard let client = try? await AIClientFactory.makeClient() else {
                log.log("Session synthesis skipped: AI client unavailable", category: .screen, level: .warning)
                return nil
            }
            let made = ShareSessionSynthesisService(client: client)
            sessionSynthesis = made
            service = made
        }

        do {
            let narrative = try await service.synthesize(input)
            let summary = ShareSessionSummary(
                sessionID: sessionID,
                windowTitle: frames.first?.windowTitle,
                startTime: startTime,
                endTime: endTime,
                narrative: narrative.narrative,
                keyMoments: narrative.keyMoments,
                entities: narrative.entities,
                modelIdentifier: narrative.modelIdentifier
            )
            summary.meeting = meeting
            meeting.sessionSummaries.append(summary)
            if let modelContext {
                PersistenceGate.save(modelContext, site: "sessionSynthesis", critical: false, meetingID: meeting.id)
            }
            return narrative
        } catch {
            log.log("Session synthesis failed (final analysis falls back to per-frame lines): \(error.localizedDescription)", category: .screen, level: .warning)
            return nil
        }
    }

    private func handleScreenCaptureEvent(_ event: ScreenCaptureEvent) {
        switch event {
        case .sessionStarted(_, let windowTitle, let appBundleID):
            screenCaptureState = .capturing(windowTitle: windowTitle)
            // Fallback provenance: if nothing held the mic when we started
            // (or it was an app we couldn't name), the app whose window is
            // being shared is a good answer.
            if currentMeeting?.sourceAppBundleID == nil, !appBundleID.isEmpty {
                currentMeeting?.sourceAppBundleID = appBundleID
                currentMeeting?.sourceAppName = MeetingAppRegistry.displayName(for: appBundleID)
                    ?? ShareAppProfiles.profile(for: appBundleID)?.displayName
            }

        case .frameKept(let frame):
            // Stamp elapsed seconds on the same clock as segment.startTime.
            // Capture is suspended while paused, so the accumulated pause
            // duration at receipt time is correct for the capture moment.
            guard let start = recordingStartDate else { return }
            let elapsed = max(0, frame.capturedAt.timeIntervalSince(start) - accumulatedPauseDuration)
            pendingScreenFrames.append((frame, elapsed))
            screenShareFrameCount += 1
            screenShareLatestFramePath = frame.relativeImagePath
            screenShareLatestFrameAt = frame.capturedAt
            enqueueForAnalysis(frame, elapsed: elapsed)

        case .frameDropped:
            break

        case .sessionEnded(let sessionID, let reason):
            endedSessionsAwaitingSynthesis.insert(sessionID)
            var stoppedTitle = ""
            if case .capturing(let windowTitle) = screenCaptureState {
                stoppedTitle = windowTitle
                screenCaptureState = .watching
            }
            let titlePart = stoppedTitle.isEmpty ? "" : " for \"\(stoppedTitle)\""
            let stillWatching = reason == .capReached ? "" : " — still watching for new shares"
            log.log("Screen capture stopped\(titlePart): \(reason.logReason)\(stillWatching)", category: .screen)

        case .permissionDenied:
            screenCaptureState = .denied
            errorMessage = "Screen Recording permission is off — shared-screen capture is disabled for this recording. Enable it in System Settings → Privacy & Security → Screen Recording."

        case .candidatesChanged(let candidates):
            screenShareCandidates = candidates
        }
    }

    /// Popover control: pause/resume frame capture without touching the
    /// recording itself. Recording-pause also suspends capture, so resuming
    /// the recording re-suspends when the user's own pause is still active
    /// (see `resumeRecording`).
    func toggleScreenCapturePause() {
        screenCaptureUserPaused.toggle()
        let paused = screenCaptureUserPaused
        Task {
            if paused {
                await screenCapture.suspend()
            } else if state == .recording {
                await screenCapture.resume()
            }
        }
    }

    /// Manual window selection from the picker sheet. `nil` returns to
    /// auto-detect.
    func selectShareWindow(_ windowID: CGWindowID?) {
        Task {
            await screenCapture.selectWindow(windowID)
        }
    }

    /// Hand a kept frame to the vision service. Budget refusals are recorded
    /// so the row is flushed as `skipped` instead of `pendingVision`.
    private func enqueueForAnalysis(_ frame: KeptFrame, elapsed: TimeInterval) {
        guard let frameAnalysis else { return }
        let snapshot = ScreenFrameAnalysisService.FrameSnapshot(
            frameID: frame.id,
            sessionID: frame.sessionID,
            timestamp: elapsed,
            formattedTimestamp: Self.formatElapsed(elapsed),
            jpegData: frame.jpegData,
            ocrExcerpt: frame.ocrText,
            isVisualOnlyChange: frame.isVisualOnlyChange
        )
        Task { [weak self] in
            let refused = await frameAnalysis.enqueue([snapshot])
            if !refused.isEmpty {
                await MainActor.run {
                    self?.budgetRefusedFrameIDs.formUnion(refused)
                }
            }
        }
    }

    private static func formatElapsed(_ elapsed: TimeInterval) -> String {
        String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
    }

    /// Frame IDs the analysis service refused for budget — flushed as
    /// `skipped` rows rather than leaving them `pendingVision` forever.
    private var budgetRefusedFrameIDs: Set<UUID> = []

    /// Flush buffered frames into SwiftData rows on `meeting`. Runs inside
    /// the caller's save (periodic loop, stop, or termination flush) — this
    /// only appends rows, it does not save.
    private func flushPendingScreenFrames(to meeting: Meeting) {
        guard !pendingScreenFrames.isEmpty else { return }
        for (frame, timestamp) in pendingScreenFrames {
            let row = ScreenShareFrame(
                id: frame.id,
                sessionID: frame.sessionID,
                sequence: frame.sequence,
                timestamp: timestamp,
                capturedAt: frame.capturedAt,
                imagePath: frame.relativeImagePath,
                windowTitle: frame.windowTitle,
                ocrText: frame.ocrText,
                dedupeHash: Int64(bitPattern: frame.dHash),
                isVisualOnlyChange: frame.isVisualOnlyChange,
                analysisState: initialAnalysisState(for: frame.id)
            )
            row.meeting = meeting
            meeting.screenFrames.append(row)
        }
        log.log("Persisted \(pendingScreenFrames.count) screen frame(s) (total: \(meeting.screenFrames.count))", category: .screen)
        pendingScreenFrames = []
    }

    private func initialAnalysisState(for frameID: UUID) -> FrameAnalysisState {
        if budgetRefusedFrameIDs.contains(frameID) { return .skipped }
        return frameAnalysis != nil ? .pendingVision : .ocrOnly
    }

    func addManualNote() {
        guard !manualNote.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let segment = TranscriptSegment(
            speaker: .me,
            text: "[Note] \(manualNote)",
            startTime: elapsedTime,
            endTime: elapsedTime,
            isFinal: true
        )
        segments.append(segment)
        manualNote = ""
    }

    // MARK: - Real Audio Capture

    private func startRealCapture(meetingID: UUID) {
        let storageManager = StorageManager.shared

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log.log("Mic permission at capture start: \(micAuthStatus.rawValue) (\(Self.describe(authorization: micAuthStatus)))\(autoDetectedRecordingStart ? " [auto-detected]" : "")", category: .audio)
        if micAuthStatus != .authorized {
            errorMessage = "Microphone permission is not granted (\(Self.describe(authorization: micAuthStatus))). Mic audio will not be captured. Grant permission in System Settings → Privacy & Security → Microphone."
            log.log("Mic permission not granted — recording will have no mic audio", category: .audio, level: .warning)
        }

        if let free = Self.freeDiskBytesForRecordings(), free < 500_000_000 {
            let mb = Double(free) / 1_048_576
            errorMessage = "Low disk space (\(String(format: "%.0f", mb)) MB free). A long recording may fail to save. Consider freeing space before continuing."
            log.log("Low disk space at recording start: \(Int(mb)) MB free", category: .audio, level: .warning)
        }

        // Wire vocabulary manager into coordinator
        coordinator.vocabularyManager = vocabularyManager

        // Start transcription coordinator
        let coordTask = Task {
            do {
                try await coordinator.start()
                await MainActor.run {
                    self.log.log("Transcription coordinator started", category: .transcription)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Transcription setup failed: \(error.localizedDescription)"
                    self.log.log("Transcription setup failed: \(error.localizedDescription)", category: .transcription, level: .error)
                }
            }
        }
        processingTasks.append(coordTask)

        // Observe coordinator segments and confidence
        let observeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await MainActor.run {
                    let rawSegments = self.coordinator.segments
                    let newConfidence = self.coordinator.segmentConfidence
                    guard rawSegments.count != self.segments.count
                        || newConfidence.count != self.segmentConfidence.count else { return }
                    let dedupResult = TranscriptDeduplicator.deduplicate(rawSegments)
                    self.segments = dedupResult.segments
                    self.segmentConfidence = newConfidence

                    // Record the current section tag for any segment we haven't seen yet,
                    // then apply all recorded tags to the segments array.
                    if let tag = self.currentSectionTag, let tagID = self.currentSectionTagID {
                        for segment in self.segments where self.segmentSectionTags[segment.id] == nil {
                            self.segmentSectionTags[segment.id] = (tag: tag, tagID: tagID)
                        }
                    }
                    for i in 0..<self.segments.count {
                        if let recorded = self.segmentSectionTags[self.segments[i].id] {
                            self.segments[i].sectionTag = recorded.tag
                            self.segments[i].sectionTagID = recorded.tagID
                        }
                    }
                }
            }
        }
        processingTasks.append(observeTask)

        // Create the live writers up front so the persistence loop can reach
        // them for `checkpoint()`. Captured into the tasks below.
        let micWriter = AudioFileWriter(outputURL: storageManager.micAudioURL(for: meetingID))
        let sysWriter = AudioFileWriter(outputURL: storageManager.systemAudioURL(for: meetingID))
        self.micFileWriter = micWriter
        self.systemFileWriter = sysWriter

        // Start microphone capture
        let autoDetectedStart = self.autoDetectedRecordingStart
        let micTask = Task {
            do {
                let micStream = try await micCapture.startCapture()

                var firstBufferLogged = false
                var bufferCount: Int = 0
                var summedAmplitude: Float = 0
                var lastDiagLog = Date()
                var silenceWarningSurfaced = false
                let captureStart = Date()

                for await taggedBuffer in micStream {
                    guard !Task.isCancelled else { break }

                    let level = self.calculateRMS(taggedBuffer.buffer)
                    bufferCount += 1
                    summedAmplitude += level
                    if !firstBufferLogged {
                        firstBufferLogged = true
                        await MainActor.run {
                            self.log.log("First mic buffer arrived (RMS \(String(format: "%.4f", level)), \(taggedBuffer.buffer.frameLength) frames @ \(Int(taggedBuffer.buffer.format.sampleRate))Hz, autoDetected=\(autoDetectedStart))", category: .audio)
                        }
                    }
                    // Periodic amplitude summary so silent-mic recordings are
                    // visible in the log without spamming. Once every ~30 s.
                    // The silence-auto-pause check piggybacks on this window:
                    // we evaluate the just-computed avg BEFORE resetting,
                    // otherwise the reset zeroes the counters and the next
                    // buffer flips the freshly-empty average to 0 and trips
                    // the auto-pause spuriously.
                    if Date().timeIntervalSince(lastDiagLog) > 30 {
                        let avg = summedAmplitude / Float(max(bufferCount, 1))
                        let bufferCountAtFlush = bufferCount
                        await MainActor.run {
                            self.log.log("Mic activity: \(bufferCountAtFlush) buffers, avg RMS \(String(format: "%.4f", avg)) over last 30s", category: .audio, level: avg < 0.001 ? .warning : .info)
                        }

                        // Auto-pause only when the mic has been silent AND no
                        // system audio is flowing — that combination means a real
                        // fault (mic perm revoked, device hardware-muted, input
                        // volume at 0, another app holding the mic). If system
                        // audio is active the user is just listening to a meeting;
                        // pausing would throw away the meeting capture too.
                        if !silenceWarningSurfaced,
                           Date().timeIntervalSince(captureStart) > 60,
                           bufferCountAtFlush > 0,
                           avg < 0.0005 {
                            let systemRecentlyActive = await MainActor.run {
                                guard let last = self.lastSystemAudioActivityAt else { return false }
                                return Date().timeIntervalSince(last) < 45
                            }
                            if systemRecentlyActive {
                                await MainActor.run {
                                    self.log.log("Mic silent (avg RMS \(String(format: "%.4f", avg))) but system audio active — keeping recording.", category: .audio)
                                }
                            } else {
                                silenceWarningSurfaced = true
                                await MainActor.run {
                                    self.errorMessage = "Mic is silent — recording auto-paused. Check System Settings → Privacy & Security → Microphone, Sound → Input level, and any conferencing app holding the mic, then resume."
                                    self.log.log("Mic + system audio silent over the last 30s (mic avg RMS \(String(format: "%.4f", avg)) < 0.0005). Auto-pausing recording.", category: .audio, level: .error)
                                    if self.state == .recording {
                                        self.pauseRecording()
                                    }
                                }
                            }
                        }

                        bufferCount = 0
                        summedAmplitude = 0
                        lastDiagLog = Date()
                    }

                    if !(await micWriter.isWriting) {
                        do {
                            try await micWriter.start(inputFormat: taggedBuffer.buffer.format)
                        } catch let err as AudioFileWriterError {
                            if case .encoderPreflightFailed = err {
                                await MainActor.run {
                                    self.errorMessage = "Mic audio encoder rejected the input format (\(err.localizedDescription)). Audio will not be saved for this recording."
                                }
                                self.log.log("Mic preflight failed: \(err.localizedDescription)", category: .audio, level: .error)
                                break
                            }
                            await self.recordWriteFailure(source: "mic", writer: micWriter, error: err)
                        } catch {
                            await self.recordWriteFailure(source: "mic", writer: micWriter, error: error)
                        }
                    }
                    do {
                        try await micWriter.write(taggedBuffer.buffer)
                    } catch {
                        let stop = await self.recordWriteFailure(source: "mic", writer: micWriter, error: error)
                        if stop { break }
                    }

                    await MainActor.run {
                        self.micLevel = level
                    }

                    // Feed to transcription coordinator
                    await self.coordinator.feedMicAudio(taggedBuffer.buffer, at: taggedBuffer.timestamp)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Mic capture failed: \(error.localizedDescription)"
                    self.log.log("Mic capture error: \(error.localizedDescription)", category: .audio, level: .error)
                }
            }
        }
        processingTasks.append(micTask)

        // Start system audio capture
        let sysTask = Task {
            do {
                let sysStream = try await systemCapture.startCapture()

                for await taggedBuffer in sysStream {
                    guard !Task.isCancelled else { break }

                    if !(await sysWriter.isWriting) {
                        do {
                            try await sysWriter.start(inputFormat: taggedBuffer.buffer.format)
                        } catch let err as AudioFileWriterError {
                            if case .encoderPreflightFailed = err {
                                await MainActor.run {
                                    self.errorMessage = "System audio encoder rejected the input format (\(err.localizedDescription)). Audio will not be saved for this recording."
                                }
                                self.log.log("System preflight failed: \(err.localizedDescription)", category: .audio, level: .error)
                                break
                            }
                            await self.recordWriteFailure(source: "system", writer: sysWriter, error: err)
                        } catch {
                            await self.recordWriteFailure(source: "system", writer: sysWriter, error: error)
                        }
                    }
                    do {
                        try await sysWriter.write(taggedBuffer.buffer)
                    } catch {
                        let stop = await self.recordWriteFailure(source: "system", writer: sysWriter, error: error)
                        if stop { break }
                    }

                    // Calculate system level for UI
                    let level = self.calculateRMS(taggedBuffer.buffer)
                    await MainActor.run {
                        self.systemLevel = level
                        if level > 0.0005 {
                            self.lastSystemAudioActivityAt = Date()
                        }
                    }

                    // Feed to transcription coordinator
                    await self.coordinator.feedSystemAudio(
                        taggedBuffer.buffer,
                        at: taggedBuffer.timestamp
                    )
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "System audio capture unavailable: \(error.localizedDescription)"
                    self.log.log("System audio error: \(error.localizedDescription)", category: .audio, level: .error)
                }
            }
        }
        processingTasks.append(sysTask)

        startAudioFlowWatchdog()
    }

    /// Poll capture services every 2 s for "no buffer received in too long".
    /// Catches the class of failures where the IOProc stops firing silently —
    /// route change, sleep/wake, tap tear-down — which otherwise leave the
    /// user staring at a running timer and an empty transcript.
    private func startAudioFlowWatchdog() {
        let micSvc = micCapture
        let sysSvc = systemCapture
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))  // grace for startup
            var micWarned = false
            var sysWarned = false
            var micRecoveryReported = false
            while !Task.isCancelled {
                guard let self else { return }
                if await self.state != .recording {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }

                let now = Date()
                // Deliberately not nested in `if let lastBufferTimestamp`: the
                // original failure delivered *no* buffers at all, so the case
                // that needs recovery most is the one where it stays nil.
                let micStale = micSvc.lastBufferTimestamp.map { now.timeIntervalSince($0) }
                if let micStale, micStale <= 3 {
                    if micWarned {
                        micWarned = false
                        await micSvc.noteHealthy()
                    }
                } else if (micStale ?? .greatestFiniteMagnitude) > 10 {
                    if !micWarned {
                        micWarned = true
                        let detail = micStale.map { "no mic buffer for \(Int($0))s" }
                            ?? "mic delivered no buffers"
                        await MainActor.run {
                            self.log.log("Audio watchdog: \(detail)", category: .audio, level: .warning)
                        }
                    }
                    // Backstop for the configuration-change observer: some
                    // device grabs stop the tap without posting a change. The
                    // stall threshold and retry cadence live in the actor
                    // alongside its attempt budget, so there is one policy
                    // rather than a second copy here.
                    if await micSvc.recoverIfStalled(reason: "watchdog") == .failed, !micRecoveryReported {
                        micRecoveryReported = true
                        await MainActor.run {
                            self.errorMessage = "Your microphone stopped feeding this recording and could not be restarted. Other participants are still being captured. Stopping and starting the recording usually clears it."
                        }
                    }
                }
                if let last = sysSvc.lastBufferTimestamp {
                    let stale = now.timeIntervalSince(last)
                    if stale > 15 && !sysWarned {
                        await MainActor.run {
                            self.log.log("Audio watchdog: no system buffer for \(Int(stale))s", category: .audio, level: .warning)
                            self.errorMessage = "System audio has stopped flowing (\(Int(stale))s). This usually means the default output device changed — stopping and restarting the recording may help."
                        }
                        sysWarned = true
                    } else if stale <= 3 {
                        sysWarned = false
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        processingTasks.append(task)
    }

    // MARK: - AI Intelligence

    private func startIntelligenceService() {
        let prepCtx = prepContext
        let aiTask = Task { [weak self] in
            guard let self else { return }

            let client: any AIClient
            do {
                guard let made = try await AIClientFactory.makeClient() else {
                    await MainActor.run {
                        self.log.log("AI intelligence skipped: no API key configured", category: .ai, level: .warning)
                    }
                    return
                }
                client = made
            } catch {
                await MainActor.run {
                    self.log.log("AI intelligence skipped: client failed — \(error.localizedDescription)", category: .ai, level: .warning)
                    self.errorMessage = "AI unavailable: \(error.localizedDescription)"
                }
                return
            }

            let model = AIModelCatalog.mainModel
            await MainActor.run {
                self.log.log("AI intelligence service starting (model: \(model))", category: .ai)
            }
            let meetingID = await MainActor.run { self.currentMeeting?.id }
            let service = AIIntelligenceService(
                client: client,
                prepContext: prepCtx,
                meetingID: meetingID,
                relatedContextProvider: RelatedMeetingContext.provider(excludingMeetingID: meetingID)
            )
            let clientModelID = client.modelIdentifier
            await MainActor.run {
                self.intelligenceService = service
                self.aiModelIdentifier = clientModelID
            }

            // Countdown before first analysis
            await self.countdown(seconds: 30, label: "first analysis")

            while !Task.isCancelled {
                await MainActor.run {
                    self.aiActivityState = .analyzing
                }

                let snapshots = await MainActor.run { self.snapshotSegments() }
                // Fresh roster each pass — the attendee list changes when a
                // calendar event is linked/unlinked mid-recording.
                let roster = await MainActor.run { self.currentMeeting.map { MeetingRoster.snapshot(for: $0) } }
                await MainActor.run {
                    self.log.log("AI sending \(snapshots.count) segments to Claude API", category: .ai)
                }

                // New screen observations since the last successful pass,
                // plus any one-time session-recap blocks. Both only advance
                // on success, so a failed pass re-sends them next time.
                let observationBatch = await MainActor.run { () -> (block: String, endIndex: Int, recapCount: Int)? in
                    let rolling = ScreenObservationFormatter.rollingBlock(
                        self.screenObservationLog,
                        afterIndex: self.lastSentObservationIndex
                    )
                    let recaps = self.pendingRecapBlocksForRolling
                    var parts: [String] = recaps
                    if let rolling {
                        parts.append(rolling.block)
                        self.log.log("Injecting \(rolling.endIndex - self.lastSentObservationIndex) screen observation(s) into rolling analysis", category: .screen)
                    }
                    if !recaps.isEmpty {
                        self.log.log("Injecting \(recaps.count) session recap(s) into rolling analysis", category: .screen)
                    }
                    guard !parts.isEmpty else { return nil }
                    return (
                        parts.joined(separator: "\n\n"),
                        rolling?.endIndex ?? self.lastSentObservationIndex,
                        recaps.count
                    )
                }

                do {
                    if let result = try await service.analyze(
                        segments: snapshots,
                        roster: roster,
                        screenObservations: observationBatch?.block
                    ) {
                        await MainActor.run {
                            self.streamingSummary = result.summary
                            self.actionItems = result.actionItems.map { parsed in
                                ActionItem(parsed: parsed, sourceSegments: self.segments)
                            }
                            self.followUpQuestions = result.followUps
                            self.topics = result.topics
                            self.latestRawResponse = result.rawResponse
                            if let observationBatch {
                                self.lastSentObservationIndex = observationBatch.endIndex
                                let consumed = min(observationBatch.recapCount, self.pendingRecapBlocksForRolling.count)
                                self.pendingRecapBlocksForRolling.removeFirst(consumed)
                            }
                            self.log.log("AI analysis complete (\(result.actionItems.count) actions, \(result.topics.count) topics)", category: .ai)
                        }
                    }
                } catch is CancellationError {
                    break  // recording stopped/paused — normal, not a user error
                } catch let urlError as URLError where urlError.code == .cancelled {
                    break
                } catch {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.errorMessage = "AI analysis: \(error.localizedDescription)"
                        self.log.log("AI analysis error: \(error.localizedDescription)", category: .ai, level: .error)
                    }
                }

                // Countdown before next analysis
                await self.countdown(seconds: 45, label: "next analysis")
            }
        }
        processingTasks.append(aiTask)
    }

    private func countdown(seconds: Int, label: String) async {
        await MainActor.run {
            self.log.log("AI waiting \(seconds)s before \(label)", category: .ai)
            self.aiActivityState = .waiting(secondsRemaining: seconds)
        }
        var remaining = seconds
        while remaining > 0 {
            guard !Task.isCancelled else { return }
            // Don't count down while paused
            let isPaused = await MainActor.run { self.state == .paused }
            if !isPaused {
                remaining -= 1
                await MainActor.run {
                    self.aiActivityState = .waiting(secondsRemaining: remaining)
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func snapshotSegments() -> [SegmentSnapshot] {
        segments.map { segment in
            SegmentSnapshot(
                speaker: segment.speaker,
                text: segment.text,
                formattedTimestamp: segment.formattedTimestamp,
                isFinal: segment.isFinal,
                startTime: segment.startTime
            )
        }
    }

    /// Wall-clock date when the current recording started. Exposed so the
    /// interview view model can convert phase Date boundaries into segment
    /// elapsed-second offsets.
    var currentRecordingStartDate: Date? { recordingStartDate }

    // MARK: - Periodic Persistence

    /// Periodically saves new segments and elapsed time to SwiftData so data survives crashes.
    /// Seconds between transcript flushes during active recording. Small enough
    /// that a crash only costs a handful of segments, large enough not to churn
    /// SwiftData on every new word.
    private static let persistenceInterval: Duration = .seconds(10)

    private func startPeriodicPersistence() {
        let task = Task { [weak self] in
            // First save happens one interval in, so the very first segments
            // are durable shortly after recording begins.
            try? await Task.sleep(for: Self.persistenceInterval)

            while !Task.isCancelled {
                await MainActor.run {
                    self?.persistIncrementalProgress()
                }
                try? await Task.sleep(for: Self.persistenceInterval)
            }
        }
        processingTasks.append(task)
    }

    private func persistIncrementalProgress() {
        guard let meeting = currentMeeting, let modelContext, state == .recording else { return }

        // If the persistence layer has faulted, stop trying to write — further
        // appends would just accumulate unsavable state. Surface a clear message
        // so the user can investigate (disk full, permissions, corruption).
        if PersistenceGate.isFaulted {
            if errorMessage == nil {
                errorMessage = "Saving transcript to database failed repeatedly. Recording is paused. Check disk space and permissions. (\(PersistenceGate.lastFailureMessage ?? "unknown error"))"
            }
            return
        }

        // Update duration
        meeting.duration = elapsedTime

        // Screen frames flush on every tick — they arrive independently of
        // speech, so the segment-count guard below must not gate them.
        flushPendingScreenFrames(to: meeting)

        // Persist only new segments since last save
        let newSegments = Array(segments.dropFirst(lastPersistedSegmentCount))
        guard !newSegments.isEmpty || lastPersistedSegmentCount == 0 else {
            PersistenceGate.save(modelContext, site: "persistIncrementalProgress/touchOnly", critical: true, meetingID: meeting.id)
            return
        }

        for segment in newSegments {
            let persisted = TranscriptSegment(
                speaker: segment.speaker,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                isFinal: segment.isFinal
            )
            persisted.confidence = segmentConfidence[segment.id] ?? 1.0
            persisted.sectionTag = segment.sectionTag
            persisted.sectionTagID = segment.sectionTagID
            persisted.meeting = meeting
            meeting.segments.append(persisted)
        }

        lastPersistedSegmentCount = segments.count
        let ok = PersistenceGate.save(modelContext, site: "persistIncrementalProgress", critical: true, meetingID: meeting.id)
        if ok {
            log.log("Persisted \(newSegments.count) new segments (total: \(lastPersistedSegmentCount))", category: .audio)
        }

        // Checkpoint the audio writers so the current chunks are finalized on disk.
        // AVAudioFile doesn't expose fsync, and only writes the AAC container metadata
        // when the file is closed — so without chunking, a crash mid-recording leaves
        // all audio unplayable. Chunk files cap the loss window to roughly
        // `persistenceInterval`.
        let micWriter = micFileWriter
        let sysWriter = systemFileWriter
        Task {
            do {
                try await micWriter?.checkpoint()
            } catch {
                LogManager.send("Mic audio checkpoint failed: \(error.localizedDescription)", category: .audio, level: .warning)
            }
            do {
                try await sysWriter?.checkpoint()
            } catch {
                LogManager.send("System audio checkpoint failed: \(error.localizedDescription)", category: .audio, level: .warning)
            }
        }
    }

    // MARK: - Helpers

    private func startTimer() {
        // Use .common mode so the timer fires during NSMenu event-tracking (e.g.
        // the phase-icon dropdown) — .scheduledTimer uses .default only, which
        // pauses while any macOS menu is open, making the elapsed-time display freeze.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartDate else { return }
                self.elapsedTime = Date().timeIntervalSince(start) - self.accumulatedPauseDuration
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Record a write failure and decide whether the capture loop should stop.
    /// 1st failure logs at warning, 3rd surfaces a user-visible error, 10th
    /// returns true so the caller breaks out of the capture loop — at that
    /// point we're dropping every buffer anyway and want to stop the
    /// recording cleanly so the user isn't staring at a frozen timer.
    @discardableResult
    private func recordWriteFailure(source: String, writer: AudioFileWriter, error: Error) async -> Bool {
        let consecutive = await writer.consecutiveWriteFailures
        let total = await writer.totalWriteFailures
        audioWriteFailures = (await micFileWriter?.totalWriteFailures ?? 0)
            + (await systemFileWriter?.totalWriteFailures ?? 0)
        lastAudioWriteError = error.localizedDescription

        if consecutive == 1 {
            log.log("\(source) write failed: \(error.localizedDescription)", category: .audio, level: .warning)
        }
        if consecutive == 3 {
            errorMessage = "\(source.capitalized) audio write is failing (\(error.localizedDescription)). The recording may be incomplete."
            log.log("\(source) write has failed 3 times consecutively: \(error.localizedDescription)", category: .audio, level: .error)
        }
        if consecutive >= 10 {
            log.log("\(source) write failed 10+ times consecutively — stopping capture loop (total failures: \(total))", category: .audio, level: .error)
            errorMessage = "\(source.capitalized) audio capture stopped after repeated write failures. Saving what we have."
            // Auto-finalize the meeting so the user isn't watching a running
            // timer with no audio being written. Without this the capture
            // loop exits but the recording UI keeps ticking, and any further
            // user speech is silently lost.
            if state == .recording, let context = modelContext {
                log.log("Auto-stopping recording due to sustained \(source) write failures", category: .audio, level: .error)
                stopRecording(in: context)
            }
            return true
        }
        return false
    }

    nonisolated static func describe(authorization: AVAuthorizationStatus) -> String {
        switch authorization {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    nonisolated static func freeDiskBytesForRecordings() -> Int64? {
        let url = StorageManager.shared.recordingsURL
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private nonisolated func calculateRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelData[0][i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        // Convert to 0-1 range (rough normalization)
        return min(rms * 5, 1.0)
    }
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
