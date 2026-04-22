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

    private(set) var pending: [UUID] = []
    private(set) var currentJob: UUID?
    private(set) var currentState: String = "idle"

    private var worker: Task<Void, Never>?
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
        guard !pending.contains(meetingID), currentJob != meetingID else { return }
        pending.append(meetingID)
        persistPending()
        if let context = modelContainer?.mainContext {
            markState(meetingID: meetingID, state: "queued", in: context)
        }
        LogManager.send("ReProcessingQueue: enqueued meeting \(meetingID)", category: .transcription)
    }

    func cancelAll() {
        worker?.cancel()
        pending = []
        currentJob = nil
        currentState = "idle"
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
        // Don't start new work while a live recording/analysis is in progress.
        if recordingViewModel?.state != .idle { return }
        if currentJob != nil { return }
        guard !pending.isEmpty else { return }

        let meetingID = pending.removeFirst()
        persistPending()
        currentJob = meetingID
        defer {
            currentJob = nil
            currentState = "idle"
        }

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
        LogManager.send("Re-transcribing \"\(title)\" with WhisperKit large-v3", category: .transcription)

        // STEP 1: enumerate audio chunks
        let storage = StorageManager.shared
        let micBase = storage.micAudioURL(for: meetingID)
        let sysBase = storage.systemAudioURL(for: meetingID)
        let micChunks = AudioFileWriter.existingChunkURLs(base: micBase)
        let sysChunks = AudioFileWriter.existingChunkURLs(base: sysBase)
        guard !micChunks.isEmpty || !sysChunks.isEmpty else {
            markState(meetingID: meetingID, state: "failed", error: "No audio files on disk for this meeting", in: context)
            return
        }

        // STEP 2: transcribe (heavy work — off main actor via the actor hop)
        markState(meetingID: meetingID, state: "transcribing", in: context)
        currentState = "transcribing"
        let upgraded: [HighQualityTranscriber.Segment]
        do {
            upgraded = try await transcriber.transcribe(micChunks: micChunks, systemChunks: sysChunks)
        } catch {
            LogManager.send("Re-transcription failed for \(meetingID): \(error.localizedDescription)", category: .transcription, level: .error)
            markState(meetingID: meetingID, state: "failed", error: error.localizedDescription, in: context)
            return
        }

        // Check for cancellation / live recording mid-job. If a call started during
        // transcription, requeue this meeting and bail.
        if recordingViewModel?.state != .idle {
            LogManager.send("Live recording started during reprocess of \(meetingID); requeueing", category: .transcription)
            pending.insert(meetingID, at: 0)
            persistPending()
            markState(meetingID: meetingID, state: "queued", in: context)
            return
        }

        // STEP 3: swap segments (main actor, same model context)
        let (segmentSnapshots, audioRanges) = swapSegments(meeting: meeting, upgraded: upgraded, in: context)

        // STEP 4: re-run AI synthesis
        markState(meetingID: meetingID, state: "analyzing", in: context)
        currentState = "analyzing"
        await reRunAIAnalysis(meeting: meeting, segments: segmentSnapshots, context: context)

        // STEP 5: re-index embeddings
        markState(meetingID: meetingID, state: "reindexing", in: context)
        currentState = "reindexing"
        await reIndexEmbeddings(meeting: meeting)

        // STEP 6: mark done
        meeting.transcriptionModel = "whisperkit-large-v3"
        meeting.reProcessingState = nil
        meeting.reProcessingError = nil
        PersistenceGate.save(context, site: "reProcess/done", critical: true, meetingID: meetingID)
        LogManager.send("Re-transcription complete for \"\(title)\" — \(upgraded.count) segments (covers \(Int(audioRanges))s of audio)", category: .transcription)
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

    private func markState(meetingID: UUID, state: String, error: String? = nil, in context: ModelContext) {
        guard let meeting = fetchMeeting(meetingID: meetingID, in: context) else { return }
        meeting.reProcessingState = state
        meeting.reProcessingError = error
        PersistenceGate.save(context, site: "reProcess/markState(\(state))", meetingID: meetingID)
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
