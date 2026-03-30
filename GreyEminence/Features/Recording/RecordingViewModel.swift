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

    private let log = LogManager.shared
    private var timer: Timer?
    private var processingTasks: [Task<Void, Never>] = []

    // Audio services
    private let micCapture = MicrophoneCaptureService()
    private let systemCapture = SystemAudioCaptureService()
    private let micFileWriter = AudioFileWriter(outputURL: URL(fileURLWithPath: "/dev/null"))
    private let systemFileWriter = AudioFileWriter(outputURL: URL(fileURLWithPath: "/dev/null"))

    // Transcription
    private let coordinator = TranscriptionCoordinator()
    private let vocabularyManager = VocabularyManager()
    let speakerContactMapper = SpeakerContactMapper()

    // Calendar & Meeting Prep
    let calendarService = CalendarService()
    private let meetingPrepService = MeetingPrepService()

    // AI Intelligence
    private var intelligenceService: AIIntelligenceService?

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

    func startRecording(in modelContext: ModelContext) {
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

        modelContext.insert(meeting)
        currentMeeting = meeting
        state = .recording
        elapsedTime = 0
        recordingStartDate = Date()
        accumulatedPauseDuration = 0
        pauseStartDate = nil
        segments = []
        actionItems = []
        followUpQuestions = []
        topics = []
        streamingSummary = ""
        errorMessage = nil
        completedMeeting = nil

        log.log("Recording started", category: .audio)
        startTimer()
        startRealCapture(meetingID: meeting.id)
        startIntelligenceService()
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

    func stopRecording(in modelContext: ModelContext) {
        state = .idle
        aiActivityState = .idle
        timer?.invalidate()
        timer = nil

        // Cancel all processing tasks
        for task in processingTasks {
            task.cancel()
        }
        processingTasks = []

        let service = intelligenceService
        intelligenceService = nil

        guard let meeting = currentMeeting else {
            // No meeting — just clean up
            Task {
                await micCapture.stopCapture()
                await systemCapture.stopCapture()
                await micFileWriter.stop()
                await systemFileWriter.stop()
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
            await micFileWriter.stop()
            await systemFileWriter.stop()

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

            // Save segments to the meeting (mark all as final since recording ended)
            for segment in self.segments {
                let persistedSegment = TranscriptSegment(
                    speaker: segment.speaker,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    isFinal: true
                )
                persistedSegment.confidence = self.segmentConfidence[segment.id] ?? 1.0
                persistedSegment.meeting = meeting
                meeting.segments.append(persistedSegment)
            }

            try? modelContext.save()

            // Mark as analyzing before navigating so the UI shows a spinner
            meeting.isAnalyzing = true
            try? modelContext.save()

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
                    topics: self.topics
                )
                insight.meeting = meeting
                meeting.insights.append(insight)

                for actionItem in self.actionItems {
                    actionItem.meeting = meeting
                    meeting.actionItems.append(actionItem)
                }

                try? modelContext.save()
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
                }
            }
        }
        processingTasks.append(observeTask)

        // Start microphone capture
        let micTask = Task {
            do {
                let micStream = try await micCapture.startCapture()

                // Set up file writer for mic audio
                let micWriter = AudioFileWriter(outputURL: storageManager.micAudioURL(for: meetingID))

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

                let sysWriter = AudioFileWriter(outputURL: storageManager.systemAudioURL(for: meetingID))

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
            await MainActor.run {
                self.intelligenceService = service
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

    private func snapshotSegments() -> [SegmentSnapshot] {
        segments.map { segment in
            SegmentSnapshot(
                speaker: segment.speaker,
                text: segment.text,
                formattedTimestamp: segment.formattedTimestamp,
                isFinal: segment.isFinal
            )
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
