import Foundation
import SwiftUI
import SwiftData
import AVFoundation

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

    // Transcription
    private let coordinator = TranscriptionCoordinator()
    private let vocabularyManager = VocabularyManager()
    let speakerContactMapper = SpeakerContactMapper()

    // Calendar & Meeting Prep
    let calendarService = CalendarService()
    private let meetingPrepService = MeetingPrepService()

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

    /// Refresh meeting prep context based on detected calendar event and contacts.
    func refreshPrepContext(in modelContext: ModelContext) {
        guard let event = calendarService.currentEvent else {
            prepContext = nil
            return
        }

        let attendeeNames = calendarService.attendeeNames(for: event)
        let descriptor = FetchDescriptor<Contact>()
        let contacts = (try? modelContext.fetch(descriptor)) ?? []
        let matched = calendarService.matchContacts(attendees: attendeeNames, existing: contacts)
        let matchedContacts = matched.compactMap(\.contact)

        guard !matchedContacts.isEmpty else {
            prepContext = nil
            return
        }

        let recurrenceID = calendarService.recurrenceID(for: event)
        var seriesID: UUID?
        if recurrenceID != nil {
            let meetingDesc = FetchDescriptor<Meeting>(
                predicate: #Predicate<Meeting> { $0.calendarEventID != nil }
            )
            if let meetings = try? modelContext.fetch(meetingDesc) {
                seriesID = meetings.first(where: { $0.calendarEventID == recurrenceID })?.seriesID
            }
        }

        prepContext = meetingPrepService.gatherPrepContext(
            attendees: matchedContacts,
            seriesID: seriesID,
            in: modelContext
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
    }

    /// Wire the auto-detection service to this view model. Called once from the
    /// view layer so the detector can reach back through `modelContextProvider`
    /// to start/stop recordings when external mic activity rises and falls.
    func configureAutoDetection(enabled: Bool, modelContextProvider: @escaping @MainActor () -> ModelContext?) {
        if !autoDetectionConfigured {
            meetingDetector.onStartRequested = { [weak self] in
                guard let self else { return }
                guard let ctx = modelContextProvider() else { return }
                self.startRecording(in: ctx, autoDetected: true)
            }
            meetingDetector.onStopRequested = { [weak self] in
                guard let self else { return }
                guard let ctx = modelContextProvider() else { return }
                self.stopRecording(in: ctx, autoDetected: true)
            }
            autoDetectionConfigured = true
        }
        setAutoDetectionEnabled(enabled)
    }

    func setAutoDetectionEnabled(_ enabled: Bool) {
        if enabled {
            meetingDetector.enable()
            // If recording is already in progress when enabled, tell the detector
            // so it doesn't try to auto-start on top of the existing session.
            if state != .idle {
                meetingDetector.noteManualStart()
            }
        } else {
            meetingDetector.disable()
        }
    }

    func startRecording(in modelContext: ModelContext, autoDetected: Bool = false) {
        // Guard against rapid double-click / stale UI triggering two starts in
        // a row. If we're already recording or paused, ignore silently and log
        // — creating a second meeting on top of a live one corrupts segment
        // attribution and leaks audio files.
        guard state == .idle else {
            log.log("startRecording ignored: already in state \(state)", category: .audio, level: .warning)
            return
        }

        if autoDetected {
            meetingDetector.noteAutoStart()
        } else {
            meetingDetector.noteManualStart()
        }

        let meeting = Meeting(title: "Meeting \(DateFormatter.shortDate.string(from: .now))")

        // Calendar integration: auto-set title and match attendees
        let calendarEnabled = UserDefaults.standard.bool(forKey: "calendarIntegration")
        if calendarEnabled, let event = calendarService.currentOrUpcomingEvent() {
            meeting.title = event.title ?? meeting.title
            meeting.calendarEventID = event.calendarItemIdentifier
            meeting.calendarEventTitle = event.title

            // Match attendees to contacts
            let attendeeNames = calendarService.attendeeNames(for: event)
            let descriptor = FetchDescriptor<Contact>()
            let contacts = (try? modelContext.fetch(descriptor)) ?? []
            let matched = calendarService.matchContacts(attendees: attendeeNames, existing: contacts)
            for (_, contact) in matched {
                if let contact, !meeting.attendees.contains(where: { $0.id == contact.id }) {
                    meeting.attendees.append(contact)
                }
            }

            // Pre-populate speaker mapper from attendee aliases
            speakerContactMapper.prepopulate(from: meeting.attendees)

            // Match to recurring series
            calendarService.matchToSeries(event: event, meeting: meeting, in: modelContext)

            log.log("Calendar event matched: \(event.title ?? "untitled")", category: .general)
        }

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
        self.modelContext = modelContext
        currentMeeting = meeting
        state = .recording
        elapsedTime = 0
        recordingStartDate = Date()
        accumulatedPauseDuration = 0
        pauseStartDate = nil
        lastPersistedSegmentCount = 0
        segmentSectionTags = [:]
        segments = []
        actionItems = []
        followUpQuestions = []
        topics = []
        streamingSummary = ""
        errorMessage = nil
        completedMeeting = nil

        // Persist active recording ID so we can detect interrupted recordings on restart.
        // Two-layer breadcrumb: UserDefaults for fast lookup, lock file on disk as a
        // fallback in case UserDefaults is cleared. The lock file also makes the
        // in-progress state visible to the user in Finder.
        UserDefaults.standard.set(meeting.id.uuidString, forKey: "activeRecordingMeetingID")
        RecordingLockFile.write(for: meeting.id, isInterviewMeeting: meeting.isInterviewMeeting)

        log.log("Recording started", category: .audio)
        startTimer()
        startRealCapture(meetingID: meeting.id)
        startIntelligenceService()
        startPeriodicPersistence()
    }

    func pauseRecording() {
        state = .paused
        timer?.invalidate()
        pauseStartDate = Date()
        Task {
            await micCapture.suspendCapture()
            await systemCapture.suspendCapture()
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
        Task {
            await micCapture.resumeCapture()
            await systemCapture.resumeCapture()
        }
        log.log("Recording resumed", category: .audio)
    }

    func stopRecording(in modelContext: ModelContext, autoDetected: Bool = false) {
        if autoDetected {
            meetingDetector.noteAutoStop()
        } else {
            meetingDetector.noteManualStop()
        }

        state = .idle
        aiActivityState = .idle
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

        guard let meeting = currentMeeting else {
            // No meeting — just clean up
            let micWriter = micFileWriter
            let sysWriter = systemFileWriter
            micFileWriter = nil
            systemFileWriter = nil
            Task {
                await micCapture.stopCapture()
                await systemCapture.stopCapture()
                await micWriter?.stop()
                await sysWriter?.stop()
                await coordinator.stop()
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

            // Stop coordinator — drains remaining recognition results and diarization
            await coordinator.stop()

            // Read segments AFTER coordinator is fully stopped
            let rawSegments = self.coordinator.segments
            self.log.log("Recording stopped (\(rawSegments.count) raw segments)", category: .audio)

            // Deduplicate mic echo segments before persisting
            let dedupResult = TranscriptDeduplicator.deduplicate(rawSegments)
            self.segments = dedupResult.segments
            if dedupResult.removedCount > 0 {
                self.log.log("Deduplication removed \(dedupResult.removedCount) echo segment(s)", category: .transcription)
            }

            // Remove any incrementally-persisted segments, then save the final deduped set
            for existing in meeting.segments {
                modelContext.delete(existing)
            }
            meeting.segments.removeAll()

            for segment in self.segments {
                let persistedSegment = TranscriptSegment(
                    speaker: segment.speaker,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    isFinal: true
                )
                persistedSegment.confidence = self.segmentConfidence[segment.id] ?? 1.0
                persistedSegment.sectionTag = segment.sectionTag
                persistedSegment.sectionTagID = segment.sectionTagID
                persistedSegment.meeting = meeting
                meeting.segments.append(persistedSegment)
            }

            let finalSegmentsOK = PersistenceGate.save(
                modelContext,
                site: "stopRecording/finalSegments",
                critical: true,
                meetingID: meeting.id
            )
            if !finalSegmentsOK {
                self.errorMessage = "Failed to save final transcript. The recording files are preserved on disk; please check disk space and retry export."
            }
            self.lastPersistedSegmentCount = 0

            // Mark as analyzing before navigating so the UI shows a spinner
            meeting.isAnalyzing = true
            PersistenceGate.save(
                modelContext,
                site: "stopRecording/markAnalyzing",
                critical: false,
                meetingID: meeting.id
            )

            // Navigate to completed meeting
            self.completedMeeting = meeting

            // Try final AI analysis (may fail or return nil — that's OK)
            if let service {
                let finalSegmentSnapshots = self.snapshotSegments()
                do {
                    if let result = try await service.performFinalAnalysis(segments: finalSegmentSnapshots) {
                        self.streamingSummary = result.summary
                        self.actionItems = result.actionItems.map { ActionItem(text: $0.text, assignee: $0.assignee) }
                        self.followUpQuestions = result.followUps
                        self.topics = result.topics
                        self.latestRawResponse = result.rawResponse
                        if let title = result.title, !title.isEmpty {
                            meeting.title = title
                        }
                    }
                } catch {
                    meeting.analysisError = error.localizedDescription
                    self.log.log("Final analysis failed (persisting existing insights): \(error.localizedDescription)", category: .ai, level: .warning)
                }
            }

            // Analysis complete
            meeting.isAnalyzing = false

            // Always persist whatever insights we have from rolling analysis
            let summary = self.streamingSummary
            if !summary.isEmpty {
                let insight = MeetingInsight(
                    summary: summary,
                    followUpQuestions: self.followUpQuestions,
                    topics: self.topics,
                    rawLLMResponse: self.latestRawResponse,
                    modelIdentifier: self.aiModelIdentifier,
                    promptVersion: AIPromptTemplates.promptVersion
                )
                insight.meeting = meeting
                meeting.insights.append(insight)

                for actionItem in self.actionItems {
                    actionItem.meeting = meeting
                    meeting.actionItems.append(actionItem)
                }

                let insightsOK = PersistenceGate.save(
                    modelContext,
                    site: "stopRecording/finalInsights",
                    critical: true,
                    meetingID: meeting.id
                )
                if !insightsOK && self.errorMessage == nil {
                    self.errorMessage = "Failed to save AI insights — the transcript is still saved, try Reanalyze from the meeting detail view."
                }
            }
        }
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
        let micTask = Task {
            do {
                let micStream = try await micCapture.startCapture()

                for await taggedBuffer in micStream {
                    guard !Task.isCancelled else { break }

                    // Write to file
                    if !(await micWriter.isWriting) {
                        try? await micWriter.start(inputFormat: taggedBuffer.buffer.format)
                    }
                    try? await micWriter.write(taggedBuffer.buffer)

                    // Calculate mic level for UI
                    let level = self.calculateRMS(taggedBuffer.buffer)
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

                    // Write to file
                    if !(await sysWriter.isWriting) {
                        try? await sysWriter.start(inputFormat: taggedBuffer.buffer.format)
                    }
                    try? await sysWriter.write(taggedBuffer.buffer)

                    // Calculate system level for UI
                    let level = self.calculateRMS(taggedBuffer.buffer)
                    await MainActor.run {
                        self.systemLevel = level
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
    }

    // MARK: - AI Intelligence

    private func startIntelligenceService() {
        let prepCtx = prepContext
        let aiTask = Task { [weak self] in
            guard let self else { return }

            guard let client = try? await AIClientFactory.makeClient() else {
                await MainActor.run {
                    self.log.log("AI not configured — skipping intelligence", category: .ai, level: .warning)
                }
                return
            }

            let model = UserDefaults.standard.string(forKey: "claudeModel") ?? "claude-sonnet-4-20250514"
            await MainActor.run {
                self.log.log("AI intelligence service starting (model: \(model))", category: .ai)
            }
            let meetingID = await MainActor.run { self.currentMeeting?.id }
            let service = AIIntelligenceService(client: client, prepContext: prepCtx, meetingID: meetingID)
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
                await MainActor.run {
                    self.log.log("AI sending \(snapshots.count) segments to Claude API", category: .ai)
                }

                do {
                    if let result = try await service.analyze(segments: snapshots) {
                        await MainActor.run {
                            self.streamingSummary = result.summary
                            self.actionItems = result.actionItems.map {
                                ActionItem(text: $0.text, assignee: $0.assignee)
                            }
                            self.followUpQuestions = result.followUps
                            self.topics = result.topics
                            self.latestRawResponse = result.rawResponse
                            self.log.log("AI analysis complete (\(result.actionItems.count) actions, \(result.topics.count) topics)", category: .ai)
                        }
                    }
                } catch {
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
                isFinal: segment.isFinal
            )
        }
    }

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
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartDate else { return }
                self.elapsedTime = Date().timeIntervalSince(start) - self.accumulatedPauseDuration
            }
        }
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
