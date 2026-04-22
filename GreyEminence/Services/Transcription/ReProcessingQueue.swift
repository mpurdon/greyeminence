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

        var progressFraction: Double? {
            guard chunksTotal > 0 else { return nil }
            return Double(chunksDone) / Double(chunksTotal)
        }
    }

    struct CompletionRecord: Equatable {
        let title: String
        let at: Date
    }

    private(set) var pending: [UUID] = []
    private(set) var current: RunningJob?
    private(set) var lastCompleted: CompletionRecord?

    static let completionFlashDuration: TimeInterval = 3

    private var worker: Task<Void, Never>?
    private var completionClearTask: Task<Void, Never>?
    private var modelContainer: ModelContainer?
    private weak var recordingViewModel: RecordingViewModel?
    private let transcriber = HighQualityTranscriber()

    private let persistenceKey = "reProcessingQueue.pending"

    // MARK: - Lifecycle

    func configure(modelContainer: ModelContainer, recordingViewModel: RecordingViewModel) {
        self.modelContainer = modelContainer
        self.recordingViewModel = recordingViewModel
        loadPendingFromDisk()
        startWorker()
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
        worker?.cancel()
        pending = []
        current = nil
        persistPending()
    }

    // MARK: - Worker

    private func startWorker() {
        worker?.cancel()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.workerTick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func workerTick() async {
        if recordingViewModel?.state != .idle { return }
        if current != nil { return }
        guard !pending.isEmpty else { return }

        let meetingID = pending.removeFirst()
        persistPending()
        current = RunningJob(id: meetingID, title: "", phase: .queued)
        defer { current = nil }

        await processJob(meetingID: meetingID)
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
        LogManager.send("Re-transcribing \"\(title)\" with WhisperKit large-v3 turbo", category: .transcription)

        let storage = StorageManager.shared
        let micChunks = AudioFileWriter.existingChunkURLs(base: storage.micAudioURL(for: meetingID))
        let sysChunks = AudioFileWriter.existingChunkURLs(base: storage.systemAudioURL(for: meetingID))
        guard !micChunks.isEmpty || !sysChunks.isEmpty else {
            markState(meeting: meeting, state: .failed, error: "No audio files on disk for this meeting", in: context)
            return
        }

        setPhase(.transcribing, for: meeting, in: context)
        let upgraded: [HighQualityTranscriber.Segment]
        do {
            upgraded = try await transcriber.transcribe(
                micChunks: micChunks,
                systemChunks: sysChunks,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateTranscriptionProgress(progress)
                    }
                }
            )
        } catch {
            LogManager.send("Re-transcription failed for \(meetingID): \(error.localizedDescription)", category: .transcription, level: .error)
            markState(meeting: meeting, state: .failed, error: error.localizedDescription, in: context)
            return
        }

        // Safety net: if every chunk failed individually and we ended up with
        // zero segments, DON'T replace the existing transcript — we'd wipe
        // the user's live transcription data in exchange for nothing.
        guard !upgraded.isEmpty else {
            LogManager.send("Re-transcription produced 0 segments for \(meetingID) — keeping original transcript", category: .transcription, level: .warning)
            markState(meeting: meeting, state: .failed, error: "Transcription produced no segments (all chunks failed inference)", in: context)
            return
        }

        // Live recording started mid-transcription — requeue and let it run later.
        if recordingViewModel?.state != .idle {
            LogManager.send("Live recording started during reprocess of \(meetingID); requeueing", category: .transcription)
            pending.insert(meetingID, at: 0)
            persistPending()
            markState(meeting: meeting, state: .queued, in: context)
            return
        }

        let (segmentSnapshots, audioRanges) = swapSegments(meeting: meeting, upgraded: upgraded, in: context)

        setPhase(.analyzing, for: meeting, in: context)
        await reRunAIAnalysis(meeting: meeting, segments: segmentSnapshots, context: context)

        setPhase(.reindexing, for: meeting, in: context)
        await reIndexEmbeddings(meeting: meeting)

        meeting.transcriptionModel = "whisperkit-large-v3-turbo"
        meeting.reProcessingState = nil
        meeting.reProcessingError = nil
        PersistenceGate.save(context, site: "reProcess/done", critical: true, meetingID: meetingID)
        scheduleCompletionFlash(title: title)
        LogManager.send("Re-transcription complete for \"\(title)\" — \(upgraded.count) segments (covers \(Int(audioRanges))s of audio)", category: .transcription)
    }

    private func setPhase(_ phase: ReProcessingState, for meeting: Meeting, in context: ModelContext) {
        if current?.phase != phase {
            current?.phase = phase
            // Reset progress on phase change — only transcribing reports chunks.
            current?.chunksDone = 0
            current?.chunksTotal = 0
        }
        markState(meeting: meeting, state: phase, in: context)
    }

    private func updateTranscriptionProgress(_ progress: HighQualityTranscriber.Progress) {
        guard var job = current else { return }
        if job.chunksDone != progress.chunksDone || job.chunksTotal != progress.chunksTotal {
            job.chunksDone = progress.chunksDone
            job.chunksTotal = progress.chunksTotal
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
        in context: ModelContext
    ) -> ([SegmentSnapshot], TimeInterval) {
        for old in meeting.segments { context.delete(old) }
        meeting.segments.removeAll()

        var totalDuration: TimeInterval = 0
        var snapshots: [SegmentSnapshot] = []
        for seg in upgraded {
            let speaker: Speaker = seg.source == .mic ? .me : .other("Speaker")
            let ts = TranscriptSegment(
                speaker: speaker,
                text: seg.text,
                startTime: seg.startTime,
                endTime: seg.endTime,
                isFinal: true
            )
            ts.meeting = meeting
            meeting.segments.append(ts)
            totalDuration = max(totalDuration, seg.endTime)
            snapshots.append(SegmentSnapshot(
                speaker: speaker,
                text: seg.text,
                formattedTimestamp: "",
                isFinal: true
            ))
        }
        if totalDuration > 0 {
            meeting.duration = totalDuration
        }
        PersistenceGate.save(context, site: "reProcess/swapSegments", critical: true, meetingID: meeting.id)
        return (snapshots, totalDuration)
    }

    private func reRunAIAnalysis(meeting: Meeting, segments: [SegmentSnapshot], context: ModelContext) async {
        guard !segments.isEmpty, let client = try? await AIClientFactory.makeClient() else { return }
        let service = AIIntelligenceService(client: client, meetingID: meeting.id)
        do {
            _ = try await service.analyze(segments: segments)
            guard let result = try await service.performFinalAnalysis(segments: segments) else { return }
            for old in meeting.insights { context.delete(old) }
            for old in meeting.actionItems { context.delete(old) }

            if let title = result.title, !title.isEmpty {
                meeting.title = title
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
                let item = ActionItem(text: parsed.text, assignee: parsed.assignee)
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

    private func markState(meeting: Meeting, state: ReProcessingState, error: String? = nil, in context: ModelContext) {
        let raw = state.rawValue
        if meeting.reProcessingState != raw || meeting.reProcessingError != error {
            meeting.reProcessingState = raw
            meeting.reProcessingError = error
            PersistenceGate.save(context, site: "reProcess/markState(\(raw))", meetingID: meeting.id)
        }
    }

    private func loadPendingFromDisk() {
        guard let strings = UserDefaults.standard.stringArray(forKey: persistenceKey) else { return }
        pending = strings.compactMap { UUID(uuidString: $0) }
        if !pending.isEmpty {
            LogManager.send("ReProcessingQueue: resumed \(pending.count) pending jobs from prior session", category: .transcription)
        }
    }

    private func persistPending() {
        let strings = pending.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: persistenceKey)
    }
}
