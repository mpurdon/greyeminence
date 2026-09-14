import AVFoundation
import Foundation
import SwiftData

/// Single-worker background queue for high-accuracy re-processing of completed
/// meetings. Runs entirely separately from the live transcription / AI
/// pipeline: its own actor, its own WhisperKit instance, its own model context.
///
/// Crucially, it pauses whenever a live recording is active. If the user ends
/// one call and immediately joins another, the just-ended meeting sits in the
/// queue until the new recording stops, and only then does its transcript get
/// upgraded. The active live session keeps the ANE/CPU to itself.
@MainActor
@Observable
final class ReProcessingQueue {
    static let shared = ReProcessingQueue()

    struct RunningJob: Equatable {
        let id: UUID
        var title: String
        var phase: ReProcessingState
        var chunksDone: Int = 0
        var chunksTotal: Int = 0
        /// Set once transcription has gone `warmUpGrace` without finishing
        /// a chunk. Whisper's first inference specialises the encoder for
        /// the Neural Engine when the cache is cold — after an app update, or
        /// after macOS purged Library/Caches under disk pressure — and that
        /// takes 10+ minutes with no progress to report. Without a word
        /// about it the bar looks hung, and a cancel looks ignored, because
        /// the compile is a synchronous XPC call nothing can interrupt.
        var isWarmingUp = false

        var progressFraction: Double? {
            guard chunksTotal > 0 else { return nil }
            return Double(chunksDone) / Double(chunksTotal)
        }

        /// The second line of the status bar.
        var detailText: String {
            switch phase {
            case .transcribing where isWarmingUp && chunksDone == 0:
                return "Preparing Whisper for the Neural Engine — the first run after an update or a cache purge takes 10+ minutes"
            case .transcribing where chunksTotal > 0:
                let pct = Int((progressFraction ?? 0) * 100)
                return "\(phase.stepDescription) — \(chunksDone)/\(chunksTotal) chunks (\(pct)%)"
            case .cancelling where isWarmingUp && chunksDone == 0:
                return "Cancelling — stops as soon as the Neural Engine finishes preparing Whisper; that step can't be interrupted"
            default:
                return phase.stepDescription
            }
        }
    }

    /// How long the transcription phase may sit at zero chunks before the
    /// status bar says the Neural Engine is compiling. Decoding the first
    /// 10 s chunk from a warm cache takes about two seconds.
    static let warmUpGrace: TimeInterval = 20
    private var warmUpTask: Task<Void, Never>?

    struct CompletionRecord: Equatable {
        let title: String
        let at: Date
    }

    private(set) var pending: [UUID] = []
    private(set) var current: RunningJob?
    private(set) var lastCompleted: CompletionRecord?

    static let completionFlashDuration: TimeInterval = 3

    private var worker: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?
    private var completionClearTask: Task<Void, Never>?
    private var modelContainer: ModelContainer?
    private weak var recordingViewModel: RecordingViewModel?
    private let transcriber = HighQualityTranscriber()
    /// Held for the same reason as the transcriber: `prepare()` loads models
    /// onto the Neural Engine, and the queue works through a backlog.
    private let diarizer = SpeakerDiarizationService()

    private let persistenceKey = "reProcessingQueue.pending"

    // MARK: - Lifecycle

    func configure(modelContainer: ModelContainer, recordingViewModel: RecordingViewModel) {
        self.modelContainer = modelContainer
        self.recordingViewModel = recordingViewModel
        loadPendingFromDisk()
        clearOrphanedStates()
        startWorker()
    }

    /// On launch, mark any meeting still showing an in-progress
    /// re-processing state as `.failed` with an "interrupted" reason.
    /// Auto-resuming used to happen here, but a single misbehaving job
    /// would crash the app, relaunch into auto-resume, and crash again
    /// in a loop with the user locked out. Opt-in via the meeting's
    /// Retry control instead: the failed badge tells them where to go.
    private func clearOrphanedStates() {
        guard let context = modelContainer?.mainContext else { return }
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.reProcessingState != nil })
        guard let stuck = try? context.fetch(descriptor), !stuck.isEmpty else { return }

        var interrupted = 0
        for meeting in stuck {
            let priorState = meeting.reProcessingState.flatMap(ReProcessingState.init(rawValue:))
            switch priorState {
            case .queued, .transcribing, .correcting, .analyzing, .reindexing:
                meeting.reProcessingState = ReProcessingState.failed.rawValue
                meeting.reProcessingError = "Interrupted on previous session — click Retry to resume"
                interrupted += 1
            case .cancelling:
                meeting.reProcessingState = nil
                meeting.reProcessingError = nil
            case .failed, nil:
                break
            }
        }
        PersistenceGate.save(context, site: "reProcess/clearOrphaned")
        LogManager.send("Marked \(interrupted) interrupted re-processing job(s) as failed", category: .transcription)
        if interrupted > 0 {
            TransientActivityCoordinator.shared.flash("\(interrupted) re-processing job\(interrupted == 1 ? "" : "s") interrupted — open meeting to retry")
        }
    }

    /// Add a meeting to the queue. Safe to call from any isolation.
    func enqueue(meetingID: UUID) {
        guard !pending.contains(meetingID), current?.id != meetingID else { return }
        pending.append(meetingID)
        persistPending()
        if let context = modelContainer?.mainContext,
           let meeting = fetchMeeting(meetingID: meetingID, in: context) {
            markState(meeting: meeting, state: .queued, in: context)
        }
        LogManager.send("ReProcessingQueue: enqueued meeting \(meetingID)", category: .transcription)
    }

    func cancelAll() {
        pending = []
        persistPending()
        jobTask?.cancel()
    }

    /// Cancel whatever meeting is currently running, leaving the rest of the
    /// queue alone. The running sub-chunk still has to finish (WhisperKit
    /// inference isn't cancellable mid-call), bounded to ~15 s, but the UI
    /// flips to "Cancelling…" immediately so cancel feels responsive in
    /// every window showing the meeting.
    func cancelCurrent(meetingID: UUID? = nil) {
        guard let current else { return }
        if let meetingID, current.id != meetingID { return }
        if self.current?.phase != .cancelling {
            self.current?.phase = .cancelling
        }
        if let context = modelContainer?.mainContext,
           let meeting = fetchMeeting(meetingID: current.id, in: context) {
            markState(meeting: meeting, state: .cancelling, in: context)
        }
        jobTask?.cancel()
        LogManager.send("Cancel requested for \"\(current.title)\"", category: .transcription)
    }

    /// A live recording just started — yield by cancelling the running job
    /// (WhisperKit will exit on its next sub-chunk boundary, ≤15 s) and
    /// pushing it back to the front of the queue. The queue's existing
    /// "skip when recording is active" guard then keeps it idle until the
    /// recording finishes. Without this, mid-transcription jobs would
    /// continue to compete with live transcription for the full duration
    /// of the current pass.
    func yieldToLiveRecording() {
        guard let current else { return }
        let id = current.id
        // Past transcription the job is a minute of AI calls and an index
        // write — nothing that competes with the live recording. Yielding
        // here re-queued a job that then finished on its own, and the whole
        // meeting was transcribed again from scratch (2026-09-11, 33 min).
        guard Self.isYieldable(current.phase) else {
            LogManager.send("Re-processing of \"\(current.title)\" is in its \(current.phase.label.lowercased()) phase — letting it finish", category: .transcription)
            return
        }
        LogManager.send("Yielding re-processing of \"\(current.title)\" to live recording", category: .transcription)
        if !pending.contains(id) { pending.insert(id, at: 0) }
        persistPending()
        if let context = modelContainer?.mainContext,
           let meeting = fetchMeeting(meetingID: id, in: context) {
            markState(meeting: meeting, state: .queued, in: context)
        }
        jobTask?.cancel()
    }

    /// Only the transcription phase is worth interrupting for a live
    /// recording; everything after it is short and off the Neural Engine.
    static func isYieldable(_ phase: ReProcessingState) -> Bool {
        switch phase {
        case .queued, .transcribing: true
        case .correcting, .analyzing, .reindexing, .cancelling, .failed: false
        }
    }

    // MARK: - Worker

    private func startWorker() {
        worker?.cancel()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Isolate each tick — an unexpected throw inside processJob
                // (e.g. an NSException or trap downstream) mustn't kill the
                // worker. If it does throw, log and continue; the queue
                // stays alive for the next job.
                do {
                    try await self.workerTickThrowing()
                } catch {
                    LogManager.send("ReProcessingQueue worker tick threw: \(error.localizedDescription) — continuing", category: .transcription, level: .error)
                    await self.clearCurrentAfterFault()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func clearCurrentAfterFault() {
        jobTask = nil
        current = nil
    }

    // MARK: Running alongside a live recording

    /// Re-processing used to wait for silence: five back-to-back meetings
    /// meant four hours of audio queued behind the last one. It can share
    /// the machine with a live recording, at low priority and under watch —
    /// the moment the live pipeline shows a backlog, it yields for the rest
    /// of that recording. The audio files are never at risk either way; the
    /// cost of getting this wrong is a lagging live transcript.
    static let runsDuringRecordingKey = "reprocess.runsDuringRecording"
    static var runsDuringRecording: Bool {
        UserDefaults.standard.object(forKey: runsDuringRecordingKey) as? Bool ?? true
    }
    /// Seconds into a recording before background work may start: the live
    /// recogniser and diarizer load their models in this window, and that
    /// is when contention was measured to freeze Whisper for minutes.
    static let recordingGrace: TimeInterval = 90
    /// Set when the live pipeline showed strain during this recording;
    /// cleared when the recording ends. One strike is enough — the
    /// recording is more important than the catch-up.
    private var pausedForThisRecording = false
    /// Whether the running job started while a recording was live, so the
    /// watchdog knows to look.
    private var jobRunsAlongsideRecording = false

    /// Whether the queue may start or continue work right now.
    private func mayRunNow() -> Bool {
        guard let vm = recordingViewModel else { return false }
        if vm.state == .idle {
            pausedForThisRecording = false
            return true
        }
        guard Self.runsDuringRecording, !pausedForThisRecording, let load = vm.liveLoad else { return false }
        return load.secondsSinceStart >= Self.recordingGrace && load.isHealthy
    }

    /// Called from the worker while a job runs alongside a recording.
    private func yieldIfLiveRecordingIsStrained() {
        guard jobRunsAlongsideRecording, let vm = recordingViewModel, vm.state != .idle, let load = vm.liveLoad else { return }
        guard !load.isHealthy else { return }
        pausedForThisRecording = true
        LogManager.send(
            String(format: "Live recording is falling behind (audio backlog %.1fs, recognition backlog %.1fs) — pausing re-processing until it ends", load.audioBacklogSeconds, load.recognitionBacklogSeconds),
            category: .transcription,
            level: .warning
        )
        yieldToLiveRecording()
    }

    private func workerTickThrowing() async throws {
        if recordingViewModel == nil { return }
        if current != nil {
            yieldIfLiveRecordingIsStrained()
            return
        }
        guard mayRunNow() else { return }
        guard !pending.isEmpty else { return }

        guard Self.hasEnoughDiskSpaceForReProcess() else {
            LogManager.send("ReProcessingQueue: skipping tick — insufficient disk space (<\(DiskSpace.describe(DiskSpace.criticalWatermark)) free)", category: .transcription, level: .warning)
            return
        }
        // Not blocking, but worth a line next to the job it may slow down:
        // this is the range where macOS purges the Neural Engine cache.
        if let warning = DiskSpace.warning(freeBytes: DiskSpace.freeBytes()) {
            LogManager.send("ReProcessingQueue: \(warning)", category: .transcription, level: .warning)
        }

        let meetingID = pending.removeFirst()
        persistPending()
        current = RunningJob(id: meetingID, title: "", phase: .queued)
        jobRunsAlongsideRecording = recordingViewModel?.state != .idle
        if jobRunsAlongsideRecording {
            LogManager.send("Re-processing alongside the live recording at low priority", category: .transcription)
        }

        // Utility priority: the live recording's work must win every
        // scheduling decision this shares with it.
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.processJob(meetingID: meetingID)
        }
        jobTask = task
        // The tick awaits the job, so the strain check runs from a sibling.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.yieldIfLiveRecordingIsStrained()
            }
        }
        await task.value
        watchdog.cancel()
        jobRunsAlongsideRecording = false
        jobTask = nil
        current = nil
        // A job that ran to completion must not be waiting in the queue as
        // well — a yield that arrived in its final second used to leave it
        // there, and it was then processed all over again.
        if let context = modelContainer?.mainContext,
           let meeting = fetchMeeting(meetingID: meetingID, in: context),
           meeting.reProcessingState == nil,
           pending.contains(meetingID) {
            pending.removeAll { $0 == meetingID }
            persistPending()
            LogManager.send("ReProcessingQueue: dropped a stale re-queue of a meeting that already finished", category: .transcription)
        }
    }

    /// Re-processing holds a ~1.5 GB WhisperKit model in memory and writes
    /// new AAC chunks and embeddings. Skip the tick rather than start a job
    /// that'll fail halfway through with a cryptic disk error.
    nonisolated static func hasEnoughDiskSpaceForReProcess() -> Bool {
        guard let available = DiskSpace.freeBytes() else {
            return true // can't tell — don't block
        }
        return available >= DiskSpace.criticalWatermark
    }

    private func processJob(meetingID: UUID) async {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        guard let meeting = fetchMeeting(meetingID: meetingID, in: context) else {
            LogManager.send("ReProcessingQueue: meeting \(meetingID) not found, skipping", category: .transcription, level: .warning)
            return
        }

        let title = meeting.title
        current?.title = title
        let jobStart = Date()
        var phaseStart = jobStart
        var transcribeDuration: TimeInterval = 0
        var analyzeDuration: TimeInterval = 0
        var reindexDuration: TimeInterval = 0
        LogManager.send("Re-transcribing \"\(title)\" with WhisperKit large-v3 turbo", category: .transcription)

        let storage = StorageManager.shared
        let audioSourceID = meeting.audioSourceMeetingID ?? meetingID
        let windowStart = meeting.audioStartOffset
        let windowEnd = meeting.audioEndOffset
        let allMic = AudioFileWriter.existingChunkURLs(base: storage.micAudioURL(for: audioSourceID))
        let allSys = AudioFileWriter.existingChunkURLs(base: storage.systemAudioURL(for: audioSourceID))
        let micChunks = Self.chunks(allMic, in: windowStart...(windowEnd ?? .greatestFiniteMagnitude))
        let sysChunks = Self.chunks(allSys, in: windowStart...(windowEnd ?? .greatestFiniteMagnitude))
        guard !micChunks.isEmpty || !sysChunks.isEmpty else {
            let where_ = audioSourceID == meetingID ? "this meeting" : "source meeting \(audioSourceID)"
            markState(meeting: meeting, state: .failed, error: "No audio files on disk for \(where_) in window \(Int(windowStart))…\(windowEnd.map { "\(Int($0))" } ?? "end")", in: context)
            return
        }

        setPhase(.transcribing, for: meeting, in: context)
        phaseStart = Date()
        let checkpoint = StorageManager.shared.loadReProcessCheckpoint(for: meetingID)
        // The same nouns feed both passes: Whisper gets them as a prompt so
        // it mishears fewer of them, and the correction pass gets them as
        // context so it knows what the mis-heard ones should have been.
        let correctionContext = TranscriptCorrectionService.Context.make(for: meeting)
        let promptText = HighQualityTranscriber.promptText(
            title: correctionContext.title,
            participants: correctionContext.participants,
            // Whisper's prompt is prose, not a weighted list, so it takes the
            // terms flat — but not the ones weighted as barely-ever, which is
            // the same reason the repair pass quarantines them.
            vocabulary: correctionContext.terms
                .filter { $0.boost > TranscriptCorrectionService.Context.rareBoostThreshold }
                .sorted { $0.boost > $1.boost }
                .map(\.text),
            topics: correctionContext.topics
        )
        let upgraded: [HighQualityTranscriber.Segment]
        do {
            upgraded = try await transcriber.transcribe(
                micChunks: micChunks,
                systemChunks: sysChunks,
                resumeFrom: checkpoint,
                promptText: promptText,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateTranscriptionProgress(progress)
                    }
                },
                onCheckpoint: { cp in
                    // Sendable closure — writes the sidecar atomically from
                    // the transcriber actor without bouncing to main.
                    StorageManager.shared.saveReProcessCheckpoint(cp, for: meetingID)
                }
            )
            transcribeDuration = Date().timeIntervalSince(phaseStart)
        } catch is CancellationError {
            // User-initiated cancel (state == .cancelling) deletes the
            // checkpoint so the next run starts fresh. Yield-to-recording
            // (state == .queued, set by yieldToLiveRecording before cancel)
            // keeps the checkpoint so the work resumes when audio frees up.
            let userCancelled = meeting.reProcessingState == ReProcessingState.cancelling.rawValue
            if userCancelled {
                StorageManager.shared.deleteReProcessCheckpoint(for: meetingID)
            }
            LogManager.send("Re-transcription cancelled for \"\(title)\" — checkpoint \(userCancelled ? "discarded" : "kept for resume")", category: .transcription)
            markState(meeting: meeting, state: nil, in: context)
            return
        } catch {
            StorageManager.shared.deleteReProcessCheckpoint(for: meetingID)
            LogManager.send("Re-transcription failed for \(meetingID): \(error.localizedDescription)", category: .transcription, level: .error)
            markState(meeting: meeting, state: .failed, error: error.localizedDescription, in: context)
            return
        }

        if Task.isCancelled {
            let userCancelled = meeting.reProcessingState == ReProcessingState.cancelling.rawValue
            if userCancelled {
                StorageManager.shared.deleteReProcessCheckpoint(for: meetingID)
            }
            LogManager.send("Re-transcription cancelled for \"\(title)\"", category: .transcription)
            markState(meeting: meeting, state: nil, in: context)
            return
        }

        // Safety net: if every chunk failed individually and we ended up with
        // zero segments, DON'T replace the existing transcript — we'd wipe
        // the user's live transcription data in exchange for nothing.
        guard !upgraded.isEmpty else {
            StorageManager.shared.deleteReProcessCheckpoint(for: meetingID)
            LogManager.send("Re-transcription produced 0 segments for \(meetingID) — keeping original transcript", category: .transcription, level: .warning)
            markState(meeting: meeting, state: .failed, error: "Transcription produced no segments (all chunks failed inference)", in: context)
            return
        }

        // Same protection against a pass that ran but barely heard anything.
        // A decoder misconfiguration (2026-09-09: prompt tokens) turned two
        // two-hour meetings into 13 and 19 segments, and the swap below
        // threw away the live transcripts that had them in full.
        let existingWords = meeting.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let newWords = upgraded.reduce(0) { $0 + $1.text.split(separator: " ").count }
        if HighQualityTranscriber.isImplausiblyThin(newWords: newWords, existingWords: existingWords) {
            StorageManager.shared.deleteReProcessCheckpoint(for: meetingID)
            LogManager.send(
                "Re-transcription of \"\(title)\" heard far less than the live transcript (\(newWords) vs \(existingWords) words) — keeping original",
                category: .transcription,
                level: .error
            )
            markState(
                meeting: meeting,
                state: .failed,
                error: "Re-transcription heard far less than the live transcript (\(newWords) vs \(existingWords) words) — original kept",
                in: context
            )
            return
        }

        // A recording is live and background work is not allowed alongside
        // it — requeue and let it run later. When it is allowed, carry on:
        // what follows is a minute of AI calls and an index write.
        if recordingViewModel?.state != .idle, !Self.runsDuringRecording {
            LogManager.send("Live recording started during reprocess of \(meetingID); requeueing", category: .transcription)
            pending.insert(meetingID, at: 0)
            persistPending()
            markState(meeting: meeting, state: .queued, in: context)
            return
        }

        // Past this point we've got a full transcript — the checkpoint has
        // served its purpose. Subsequent analyze + reindex are cheap to
        // redo if interrupted, so no further checkpointing is needed.
        StorageManager.shared.deleteReProcessCheckpoint(for: meetingID)

        // Diarize the system track before swapping, so the new transcript can
        // be attributed as it is written rather than relabelled afterwards.
        let diarized = await diarizeSystemTrack(chunks: sysChunks, title: title)
        let (segmentSnapshots, audioRanges, attributionVoiceCount) = swapSegments(
            meeting: meeting,
            upgraded: upgraded,
            diarized: diarized,
            in: context
        )
        if let voiceCount = attributionVoiceCount, voiceCount > 0 {
            LogManager.send("Diarization found \(voiceCount) distinct voice(s) in \"\(title)\"", category: .transcription)
        }

        // Fix mis-hearings before the summary is built from them.
        setPhase(.correcting, for: meeting, in: context)
        phaseStart = Date()
        let correctedLines = await applyCorrections(meeting: meeting, correctionContext: correctionContext, in: context)
        let correctDuration = Date().timeIntervalSince(phaseStart)
        let analysisSegments = correctedLines > 0 ? Self.snapshots(of: meeting) : segmentSnapshots

        setPhase(.analyzing, for: meeting, in: context)
        phaseStart = Date()
        await reRunAIAnalysis(meeting: meeting, segments: analysisSegments, context: context)
        analyzeDuration = Date().timeIntervalSince(phaseStart)

        setPhase(.reindexing, for: meeting, in: context)
        phaseStart = Date()
        await reIndexEmbeddings(meeting: meeting)
        reindexDuration = Date().timeIntervalSince(phaseStart)

        meeting.transcriptionModel = "whisperkit-large-v3-turbo"
        meeting.reProcessingState = nil
        meeting.reProcessingError = nil
        PersistenceGate.save(context, site: "reProcess/done", critical: true, meetingID: meetingID)
        scheduleCompletionFlash(title: title)

        let totalDuration = Date().timeIntervalSince(jobStart)
        let chunksProcessed = micChunks.count + sysChunks.count
        let throughput = transcribeDuration > 0 ? audioRanges / transcribeDuration : 0
        let wordCount = upgraded.reduce(0) { $0 + $1.text.split(separator: " ").count }
        LogManager.send(
            """
            Re-processing report for "\(title)":
              total:       \(Self.fmt(totalDuration))
              transcribe:  \(Self.fmt(transcribeDuration)) (\(chunksProcessed) chunks, \(String(format: "%.1fx", throughput)) realtime)
              correct:     \(Self.fmt(correctDuration)) (\(correctedLines) line(s) fixed)
              analyze:     \(Self.fmt(analyzeDuration))
              reindex:     \(Self.fmt(reindexDuration))
              output:      \(upgraded.count) segments, \(wordCount) words, covers \(Self.fmt(audioRanges)) of audio
            """,
            category: .transcription
        )
    }

    /// Best-effort: a failure here costs attribution, not the transcript. The
    /// upgraded text is the point of re-processing and must survive a
    /// diarizer that won't load.
    private func diarizeSystemTrack(chunks: [URL], title: String) async -> [DiarizedSegment] {
        guard !chunks.isEmpty else { return [] }
        do {
            try await diarizer.prepare()
            return try await diarizer.diarizeTrack(chunkURLs: chunks)
        } catch is CancellationError {
            return []
        } catch {
            LogManager.send(
                "Diarization unavailable for \"\(title)\" — transcript keeps text but not speakers: \(error.localizedDescription)",
                category: .transcription,
                level: .warning
            )
            return []
        }
    }

    private static func fmt(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }

    private func setPhase(_ phase: ReProcessingState, for meeting: Meeting, in context: ModelContext) {
        if current?.phase != phase {
            current?.phase = phase
            // Reset progress on phase change — only transcribing reports chunks.
            current?.chunksDone = 0
            current?.chunksTotal = 0
            current?.isWarmingUp = false
            warmUpTask?.cancel()
            if phase == .transcribing {
                warmUpTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.warmUpGrace))
                    guard !Task.isCancelled, let self, var job = self.current,
                          job.phase == .transcribing, job.chunksDone == 0 else { return }
                    job.isWarmingUp = true
                    self.current = job
                    LogManager.send(
                        "Whisper has not finished its first chunk after \(Int(Self.warmUpGrace))s — the Neural Engine is compiling the model. That happens after an app update or when macOS purged Library/Caches (low disk space); it is a one-off of 10+ minutes and cannot be interrupted, not even by cancel.",
                        category: .transcription,
                        level: .warning
                    )
                }
            }
        }
        markState(meeting: meeting, state: phase, in: context)
    }

    private func updateTranscriptionProgress(_ progress: HighQualityTranscriber.Progress) {
        guard var job = current else { return }
        if job.chunksDone != progress.chunksDone || job.chunksTotal != progress.chunksTotal {
            job.chunksDone = progress.chunksDone
            job.chunksTotal = progress.chunksTotal
            if progress.chunksDone > 0 {
                if job.isWarmingUp {
                    LogManager.send("Neural Engine model preparation finished — transcription is under way", category: .transcription)
                }
                job.isWarmingUp = false
                warmUpTask?.cancel()
            }
            current = job
        }
    }

    private func scheduleCompletionFlash(title: String) {
        lastCompleted = CompletionRecord(title: title, at: .now)
        completionClearTask?.cancel()
        completionClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.completionFlashDuration + 0.1))
            guard !Task.isCancelled, let self else { return }
            lastCompleted = nil
        }
    }

    // MARK: - Pipeline steps

    private func swapSegments(
        meeting: Meeting,
        upgraded: [HighQualityTranscriber.Segment],
        diarized: [DiarizedSegment],
        in context: ModelContext
    ) -> ([SegmentSnapshot], TimeInterval, Int?) {
        for old in meeting.segments { context.delete(old) }
        meeting.segments.removeAll()

        // Build detached TranscriptSegments from the upgraded output and run
        // mic/system dedup before persisting — otherwise echoed speech (the
        // same phrase captured by both the mic and the system audio tap)
        // shows up twice in the final transcript.
        // Attribution for the system side comes from the diarization pass over
        // the same audio. Without it every remote voice collapsed into one
        // anonymous "Speaker" — which is what made a four-person meeting read
        // as a conversation between the user and a single monolith.
        let attribution = SpeakerIdentification.attribute(diarized: diarized, meeting: meeting)

        let raw: [TranscriptSegment] = upgraded.map { seg in
            let speaker: Speaker
            if seg.source == .mic {
                speaker = .me
            } else {
                // With several remote voices an unattributed stretch keeps the
                // honest label rather than going to whoever spoke nearby; with
                // one, the attribution hands it to that voice.
                speaker = attribution?.speaker(from: seg.startTime, to: seg.endTime) ?? .unidentified
            }
            let segment = TranscriptSegment(
                speaker: speaker,
                text: seg.text,
                startTime: seg.startTime,
                endTime: seg.endTime,
                isFinal: true
            )
            segment.confidence = seg.confidence
            if seg.source == .mic { segment.micLevel = seg.level }
            return segment
        }
        let dedup = TranscriptDeduplicator.deduplicate(raw)
        if dedup.removedCount > 0 || dedup.reassignedCount > 0 {
            LogManager.send(
                "Re-processing dedup removed \(dedup.removedCount) echo segment(s), reattributed \(dedup.reassignedCount) quiet line(s) to the far side"
                    + (dedup.userLevelBaseline.map { String(format: " (user voice baseline RMS %.4f)", $0) } ?? ""),
                category: .transcription
            )
        }

        var totalDuration: TimeInterval = 0
        var snapshots: [SegmentSnapshot] = []
        for ts in dedup.segments {
            ts.meeting = meeting
            meeting.segments.append(ts)
            totalDuration = max(totalDuration, ts.endTime)
            snapshots.append(SegmentSnapshot(
                speaker: ts.speaker,
                text: ts.text,
                formattedTimestamp: "",
                isFinal: true
            ))
        }
        if totalDuration > 0 {
            meeting.duration = totalDuration
        }
        PersistenceGate.save(context, site: "reProcess/swapSegments", critical: true, meetingID: meeting.id)
        return (snapshots, totalDuration, attribution?.voiceCount)
    }

    /// Fix mis-heard words on the transcript as it stands, without
    /// re-transcribing. The on-demand path for a meeting that was processed
    /// before this pass existed; re-indexes search when anything changed.
    /// Returns how many lines were corrected.
    func correctTranscript(for meeting: Meeting, in context: ModelContext) async -> Int {
        let correctionContext = TranscriptCorrectionService.Context.make(for: meeting)
        let corrected = await applyCorrections(meeting: meeting, correctionContext: correctionContext, in: context)
        if corrected > 0 {
            await reIndexEmbeddings(meeting: meeting)
        }
        return corrected
    }

    private func applyCorrections(
        meeting: Meeting,
        correctionContext: TranscriptCorrectionService.Context,
        in context: ModelContext
    ) async -> Int {
        let segments = meeting.segments.sorted { $0.startTime < $1.startTime }
        guard !segments.isEmpty else { return 0 }
        guard let client = try? await AIClientFactory.makeClient() else {
            LogManager.send("Transcript correction skipped: AI not configured", category: .transcription, meetingID: meeting.id)
            return 0
        }
        let lines = segments.enumerated().map { offset, segment in
            TranscriptCorrectionService.Line(
                index: offset,
                speaker: segment.speaker.displayName,
                text: segment.text,
                confidence: segment.confidence,
                isUserEdited: segment.isEdited
            )
        }
        do {
            let corrections = try await TranscriptCorrectionService(client: client)
                .corrections(for: lines, context: correctionContext, meetingID: meeting.id)
            let applied = TranscriptCorrectionService.apply(corrections, to: segments)
            if applied > 0 {
                PersistenceGate.save(context, site: "reProcess/corrections", critical: true, meetingID: meeting.id)
            }
            LogManager.send(
                "Transcript correction: \(applied) of \(lines.count) line(s) fixed (\(corrections.count) proposed)",
                category: .transcription,
                meetingID: meeting.id
            )
            return applied
        } catch {
            LogManager.send(
                "Transcript correction skipped: \(error.localizedDescription)",
                category: .transcription,
                level: .warning,
                meetingID: meeting.id
            )
            return 0
        }
    }

    /// The analysis input, rebuilt after corrections so the summary sees
    /// the fixed words. Same shape `swapSegments` produces.
    private static func snapshots(of meeting: Meeting) -> [SegmentSnapshot] {
        meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: "", isFinal: true) }
    }

    private func reRunAIAnalysis(meeting: Meeting, segments: [SegmentSnapshot], context: ModelContext) async {
        guard !segments.isEmpty, let client = try? await AIClientFactory.makeClient() else { return }
        let service = AIIntelligenceService(
            client: client,
            meetingID: meeting.id,
            relatedContextProvider: RelatedMeetingContext.provider(excludingMeetingID: meeting.id)
        )
        do {
            let roster = MeetingRoster.snapshot(for: meeting)
            // Persisted screen observations ride along — this pass REPLACES
            // the live insights, and without them the screen-aware summary
            // produced at stop time would be silently degraded.
            let screenBlock = ScreenObservationFormatter.finalBlock(for: meeting)
            if screenBlock != nil {
                LogManager.send("Re-analysis: injecting screen context (\(meeting.sessionSummaries.count) recap(s), \(meeting.screenFrames.count) frame(s))", category: .screen, meetingID: meeting.id)
            }
            let finalResult = try await AIUsageContext.attribute(.reanalysis, meetingID: meeting.id) {
                _ = try await service.analyze(segments: segments, roster: roster, screenObservations: screenBlock)
                return try await service.performFinalAnalysis(segments: segments, roster: roster, screenObservations: screenBlock)
            }
            guard let result = finalResult else { return }
            for old in meeting.insights { context.delete(old) }
            for old in meeting.actionItems { context.delete(old) }

            if let title = result.title {
                meeting.applyGeneratedTitle(title)
            }
            let insight = MeetingInsight(
                summary: result.summary,
                followUpQuestions: result.followUps,
                topics: result.topics,
                rawLLMResponse: result.rawResponse,
                modelIdentifier: client.modelIdentifier,
                promptVersion: AIPromptTemplates.promptVersion
            )
            insight.meeting = meeting
            meeting.insights.append(insight)
            for parsed in result.actionItems {
                let item = ActionItem(parsed: parsed, sourceSegments: meeting.segments)
                item.meeting = meeting
                meeting.actionItems.append(item)
            }
            PersistenceGate.save(context, site: "reProcess/aiAnalysis", critical: true, meetingID: meeting.id)
        } catch {
            LogManager.send("Re-analysis failed for \(meeting.id): \(error.localizedDescription)", category: .ai, level: .warning)
        }
    }

    private func reIndexEmbeddings(meeting: Meeting) async {
        guard let store = EmbeddingStore.shared else { return }
        // Old chunk records key on the previous transcription's segment UUIDs;
        // the upsert in indexMeeting can't reach them since the new pass uses
        // fresh UUIDs. Drop them first so search isn't polluted with both.
        let pruned = store.deleteRecords(forMeetingID: meeting.id)
        if pruned > 0 {
            LogManager.send("Pruned \(pruned) stale embedding(s) before re-index for meeting \(meeting.id)", category: .general)
        }
        let providerRaw = UserDefaults.standard.string(forKey: "embeddingProvider") ?? EmbeddingProvider.nlEmbedding.rawValue
        let provider = EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
        let indexer = EmbeddingIndexer(store: store, service: provider.makeService())
        await indexer.indexMeeting(meeting)
    }

    // MARK: - Helpers

    private func fetchMeeting(meetingID: UUID, in context: ModelContext) -> Meeting? {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        return try? context.fetch(descriptor).first
    }

    /// Filter chunks to those overlapping the requested audio-timeline window.
    /// Accepts ~10s slop at boundaries (chunks are atomic and not re-encoded).
    static func chunks(_ urls: [URL], in window: ClosedRange<TimeInterval>) -> [URL] {
        var result: [URL] = []
        var cumulative: TimeInterval = 0
        for url in urls {
            // Same question the transcriber's timeline asks, so it gets the
            // same answer — including the finite guard this copy lacked.
            let duration = HighQualityTranscriber.assumedDuration(of: url, fallback: 10)
            let chunkRange = cumulative...(cumulative + duration)
            if chunkRange.upperBound > window.lowerBound && chunkRange.lowerBound < window.upperBound {
                result.append(url)
            }
            cumulative += duration
            if cumulative >= window.upperBound { break }
        }
        return result
    }

    private func markState(meeting: Meeting, state: ReProcessingState?, error: String? = nil, in context: ModelContext) {
        let raw = state?.rawValue
        if meeting.reProcessingState != raw || meeting.reProcessingError != error {
            meeting.reProcessingState = raw
            meeting.reProcessingError = error
            PersistenceGate.save(context, site: "reProcess/markState(\(raw ?? "nil"))", meetingID: meeting.id)
        }
    }

    /// Deliberately does NOT restore the persisted queue. A job that was queued
    /// before app quit is indistinguishable from one whose processing crashed
    /// mid-flight, and surprising the user by silently re-running yesterday's
    /// work (especially when they click Re-transcribe on something else and it
    /// picks up the old job first) is worse than making them re-click.
    private func loadPendingFromDisk() {
        if let strings = UserDefaults.standard.stringArray(forKey: persistenceKey), !strings.isEmpty {
            LogManager.send("ReProcessingQueue: discarded \(strings.count) stale pending job(s) from prior session", category: .transcription)
        }
        pending = []
        persistPending()
    }

    private func persistPending() {
        let strings = pending.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: persistenceKey)
    }
}
