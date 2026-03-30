import AVFoundation
import FluidAudio

/// Orchestrates audio capture, speech recognition, and speaker diarization
/// into a unified timeline of transcript segments.
@Observable
@MainActor
final class TranscriptionCoordinator {
    var segments: [TranscriptSegment] = []
    var isProcessing = false

    private let formatConverter = AudioFormatConverter()
    private let micAsr = FluidAsrService(source: .microphone)
    private let systemAsr = FluidAsrService(source: .system)
    private let diarization = SpeakerDiarizationService()

    private var processingTasks: [Task<Void, Never>] = []

    // Buffer system audio samples for diarization (need ~10s chunks)
    private var systemAudioBuffer: [Float] = []
    private var systemBufferStartTime: TimeInterval = 0
    private let diarizationChunkDuration: TimeInterval = 10.0

    // Buffer mic audio for diarization (used when system audio is silent)
    private var micAudioBuffer: [Float] = []
    private var micBufferStartTime: TimeInterval = 0
    private var hasSystemSpeech = false

    // Track current draft text for replacement
    private var currentMicDraftID: UUID?
    private var currentSystemDraftID: UUID?

    // Track live confidence per segment (in-memory only, not persisted)
    private(set) var segmentConfidence: [UUID: Float] = [:]

    // Vocabulary manager for custom term boosting
    var vocabularyManager: VocabularyManager?

    /// Maximum gap (seconds) between consecutive confirmed results from the
    /// same speaker before they are merged into a single segment.
    private let segmentMergeWindow: TimeInterval = 5.0

    /// Cached ASR models — survives across recordings so only the first load is slow.
    private static var cachedModels: AsrModels?

    /// In-flight model loading task — prevents duplicate concurrent downloads.
    private static var modelLoadingTask: Task<AsrModels, Error>?

    /// Pre-load ASR models (call early, e.g. when recording view appears).
    static func preloadModels() async {
        guard cachedModels == nil else { return }
        do {
            let models = try await loadModels()
            _ = models // preloaded into cache
        } catch {
            LogManager.send("ASR model pre-load failed: \(error.localizedDescription)", category: .transcription, level: .warning)
        }
    }

    /// Shared model loading — ensures only one download runs at a time.
    private static func loadModels() async throws -> AsrModels {
        if let cached = cachedModels { return cached }

        // Join in-flight download if one is already running
        if let existing = modelLoadingTask {
            return try await existing.value
        }

        let task = Task {
            LogManager.send("Downloading ASR models…", category: .transcription)
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            LogManager.send("ASR models ready", category: .transcription)
            return models
        }
        modelLoadingTask = task

        do {
            let models = try await task.value
            cachedModels = models
            modelLoadingTask = nil
            return models
        } catch {
            modelLoadingTask = nil
            throw error
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        // Clean up any lingering state from a previous run
        await micAsr.stopRecognition()
        await systemAsr.stopRecognition()

        isProcessing = true
        segments = []
        segmentConfidence = [:]
        systemAudioBuffer = []
        micAudioBuffer = []
        hasSystemSpeech = false

        // Prepare diarization concurrently with model loading
        let diarizationTask = Task {
            do {
                try await diarization.prepare()
                try await diarization.startStreaming()
                LogManager.send("Diarization ready", category: .transcription)
            } catch {
                LogManager.send("Diarization setup failed (non-fatal): \(error.localizedDescription)", category: .transcription, level: .warning)
            }
        }

        // Load ASR models (uses cache, or joins in-flight preload download)
        let models = try await Self.loadModels()

        await diarizationTask.value

        // Build vocabulary context if available
        let vocabContext = vocabularyManager?.buildContext()
        if let vocabContext {
            LogManager.shared.log("Vocabulary boosting: \(vocabContext.terms.count) terms", category: .transcription)
        }

        // Start streaming ASR for both sources (sharing loaded models)
        LogManager.shared.log("Starting streaming ASR", category: .transcription)
        let micStream = try await micAsr.startRecognition(models: models, vocabularyContext: vocabContext)
        let sysStream = try await systemAsr.startRecognition(models: models, vocabularyContext: vocabContext)
        LogManager.shared.log("Mic and system ASR streams active", category: .transcription)

        // Process mic recognition updates
        let micTask = Task { [weak self] in
            for await update in micStream {
                await self?.handleMicUpdate(update)
            }
        }
        processingTasks.append(micTask)

        // Process system recognition updates
        let sysTask = Task { [weak self] in
            for await update in sysStream {
                await self?.handleSystemUpdate(update)
            }
        }
        processingTasks.append(sysTask)
    }

    func stop() async {
        // Stop recognition first — this finishes the AsyncStreams,
        // allowing the listener tasks to drain any buffered results and exit.
        await micAsr.stopRecognition()
        await systemAsr.stopRecognition()

        // Wait for listener tasks to finish (they exit when streams end).
        // Fallback: cancel after a short deadline to avoid hanging.
        for task in processingTasks {
            let timeout = Task {
                try? await Task.sleep(for: .milliseconds(500))
                task.cancel()
            }
            _ = await task.value
            timeout.cancel()
        }
        processingTasks = []

        await diarization.stopStreaming()

        // Process any remaining buffered audio for speaker labels
        await processRemainingDiarizationBuffer()
        await processRemainingMicDiarizationBuffer()

        LogManager.shared.log("Transcription stopped (\(segments.count) segments)", category: .transcription)
        isProcessing = false
    }

    // MARK: - Audio Input (called from audio threads)

    /// Feed a microphone audio buffer into the pipeline.
    /// Called from the audio capture callback — must not cross actor boundaries.
    nonisolated func feedMicAudio(_ buffer: AVAudioPCMBuffer, at timestamp: TimeInterval) {
        micAsr.feedAudio(buffer)

        // Convert to float samples for mic diarization (used when system audio is silent)
        do {
            let samples = try formatConverter.floatSamples(from: buffer)
            Task { @MainActor [weak self] in
                self?.accumulateMicDiarizationSamples(samples, at: timestamp)
            }
        } catch {
            // Conversion failed — skip this buffer
        }
    }

    /// Feed a system audio buffer into the pipeline.
    nonisolated func feedSystemAudio(_ buffer: AVAudioPCMBuffer, at timestamp: TimeInterval) {
        systemAsr.feedAudio(buffer)

        // Convert to float samples for diarization
        do {
            let samples = try formatConverter.floatSamples(from: buffer)
            Task { @MainActor [weak self] in
                self?.accumulateDiarizationSamples(samples, at: timestamp)
            }
        } catch {
            // Conversion failed — skip this buffer
        }
    }

    // MARK: - Speech Recognition Handlers

    private static let leadingJunkCharacters: CharacterSet = {
        var cs = CharacterSet.whitespacesAndNewlines
        cs.formUnion(.punctuationCharacters)
        cs.formUnion(.symbols)
        return cs
    }()

    /// Strip leading whitespace, punctuation, and symbols from text.
    /// Returns nil if the result is empty.
    private func cleanedText(_ raw: String) -> String? {
        let cleaned = raw
            .drop(while: { $0.unicodeScalars.allSatisfy(Self.leadingJunkCharacters.contains) })
        let result = String(cleaned)
        return result.isEmpty ? nil : result
    }

    private func handleMicUpdate(_ update: FluidAsrService.TranscriptUpdate) {
        guard let text = cleanedText(update.text) else {
            // Empty after cleaning — finalize existing draft instead of discarding it
            if update.isFinal, let draftID = currentMicDraftID,
               let idx = segments.firstIndex(where: { $0.id == draftID }) {
                segments[idx].isFinal = true
                currentMicDraftID = nil
                LogManager.shared.log("Mic draft promoted to final: \(segments[idx].text.prefix(80))", category: .transcription)
            }
            return
        }

        // Remove previous draft (will be replaced with updated text below)
        if let draftID = currentMicDraftID {
            segmentConfidence.removeValue(forKey: draftID)
            segments.removeAll { $0.id == draftID }
        }

        if update.isFinal {
            currentMicDraftID = nil

            // Try to merge with the most recent final segment from the same speaker
            if let lastIdx = segments.lastIndex(where: { $0.speaker == .me && $0.isFinal }),
               update.timestamp - segments[lastIdx].endTime <= segmentMergeWindow {
                segments[lastIdx].text += " " + text
                segments[lastIdx].endTime = update.timestamp
                // Average confidence on merge
                let existing = segmentConfidence[segments[lastIdx].id] ?? 1.0
                segmentConfidence[segments[lastIdx].id] = (existing + update.confidence) / 2.0
                LogManager.shared.log("Mic segment merged: \(segments[lastIdx].text.prefix(80))", category: .transcription)
            } else {
                let segment = TranscriptSegment(
                    speaker: .me,
                    text: text,
                    startTime: update.timestamp,
                    endTime: update.timestamp,
                    isFinal: true
                )
                segmentConfidence[segment.id] = update.confidence
                segments.append(segment)
                LogManager.shared.log("Mic segment finalized: \(text.prefix(80))", category: .transcription)
            }
        } else {
            let segment = TranscriptSegment(
                speaker: .me,
                text: text,
                startTime: update.timestamp,
                endTime: update.timestamp,
                isFinal: false
            )
            segmentConfidence[segment.id] = update.confidence
            currentMicDraftID = segment.id
            segments.append(segment)
        }
    }

    private func handleSystemUpdate(_ update: FluidAsrService.TranscriptUpdate) {
        guard let text = cleanedText(update.text) else {
            // Empty after cleaning — finalize existing draft instead of discarding it
            if update.isFinal, let draftID = currentSystemDraftID,
               let idx = segments.firstIndex(where: { $0.id == draftID }) {
                segments[idx].isFinal = true
                currentSystemDraftID = nil
                LogManager.shared.log("System draft promoted to final: \(segments[idx].text.prefix(80))", category: .transcription)
            }
            return
        }

        hasSystemSpeech = true

        // Remove previous draft (will be replaced with updated text below)
        if let draftID = currentSystemDraftID {
            segmentConfidence.removeValue(forKey: draftID)
            segments.removeAll { $0.id == draftID }
        }

        let defaultSpeaker = Speaker.other("Other")

        if update.isFinal {
            currentSystemDraftID = nil

            // Try to merge with the most recent final segment from a system speaker
            // (any speaker that isn't .me — system segments get relabeled by diarization later)
            if let lastIdx = segments.lastIndex(where: { $0.speaker != .me && $0.isFinal }),
               update.timestamp - segments[lastIdx].endTime <= segmentMergeWindow {
                segments[lastIdx].text += " " + text
                segments[lastIdx].endTime = update.timestamp
                let existing = segmentConfidence[segments[lastIdx].id] ?? 1.0
                segmentConfidence[segments[lastIdx].id] = (existing + update.confidence) / 2.0
                LogManager.shared.log("System segment merged: \(segments[lastIdx].text.prefix(80))", category: .transcription)
            } else {
                let segment = TranscriptSegment(
                    speaker: defaultSpeaker,
                    text: text,
                    startTime: update.timestamp,
                    endTime: update.timestamp,
                    isFinal: true
                )
                segmentConfidence[segment.id] = update.confidence
                segments.append(segment)
                LogManager.shared.log("System segment finalized: \(text.prefix(80))", category: .transcription)
            }
        } else {
            let segment = TranscriptSegment(
                speaker: defaultSpeaker,
                text: text,
                startTime: update.timestamp,
                endTime: update.timestamp,
                isFinal: false
            )
            segmentConfidence[segment.id] = update.confidence
            currentSystemDraftID = segment.id
            segments.append(segment)
        }
    }

    // MARK: - Diarization

    private func accumulateDiarizationSamples(_ samples: [Float], at timestamp: TimeInterval) {
        if systemAudioBuffer.isEmpty {
            systemBufferStartTime = timestamp
        }
        systemAudioBuffer.append(contentsOf: samples)

        let samplesNeeded = Int(diarizationChunkDuration * 16000)
        if systemAudioBuffer.count >= samplesNeeded {
            let chunk = Array(systemAudioBuffer.prefix(samplesNeeded))
            let startTime = systemBufferStartTime
            systemAudioBuffer.removeFirst(samplesNeeded)
            systemBufferStartTime += diarizationChunkDuration

            Task {
                await processDiarizationChunk(chunk, startTime: startTime)
            }
        }
    }

    private func processDiarizationChunk(_ samples: [Float], startTime: TimeInterval) async {
        do {
            let diarizedSegments = try await diarization.processSamples(
                samples,
                atTime: startTime
            )

            for diarized in diarizedSegments {
                for i in segments.indices {
                    let seg = segments[i]
                    if seg.speaker == .other("Other")
                        && seg.isFinal
                        && seg.startTime >= diarized.startTime - 1.0
                        && seg.startTime <= diarized.endTime + 1.0
                    {
                        segments[i].speaker = diarized.speaker
                    }
                }
            }
        } catch {
            LogManager.shared.log("Diarization error: \(error.localizedDescription)", category: .transcription, level: .warning)
        }
    }

    private func processRemainingDiarizationBuffer() async {
        guard systemAudioBuffer.count >= 48_000 else { return }
        let chunk = systemAudioBuffer
        let startTime = systemBufferStartTime
        systemAudioBuffer = []
        await processDiarizationChunk(chunk, startTime: startTime)
    }

    // MARK: - Mic Diarization (fallback when system audio is silent)

    private func accumulateMicDiarizationSamples(_ samples: [Float], at timestamp: TimeInterval) {
        if micAudioBuffer.isEmpty {
            micBufferStartTime = timestamp
        }
        micAudioBuffer.append(contentsOf: samples)

        let samplesNeeded = Int(diarizationChunkDuration * 16000)
        if micAudioBuffer.count >= samplesNeeded {
            let chunk = Array(micAudioBuffer.prefix(samplesNeeded))
            let startTime = micBufferStartTime
            micAudioBuffer.removeFirst(samplesNeeded)
            micBufferStartTime += diarizationChunkDuration

            Task {
                await processMicDiarizationChunk(chunk, startTime: startTime)
            }
        }
    }

    private func processMicDiarizationChunk(_ samples: [Float], startTime: TimeInterval) async {
        // Only relabel mic segments when system audio has produced no speech.
        // If system audio is working, mic segments stay as "Me".
        guard !hasSystemSpeech else { return }

        do {
            let diarizedSegments = try await diarization.processSamples(
                samples,
                atTime: startTime
            )

            for diarized in diarizedSegments {
                for i in segments.indices {
                    let seg = segments[i]
                    if seg.speaker == .me
                        && seg.isFinal
                        && seg.startTime >= diarized.startTime - 1.0
                        && seg.startTime <= diarized.endTime + 1.0
                    {
                        segments[i].speaker = diarized.speaker
                    }
                }
            }
        } catch {
            LogManager.shared.log("Mic diarization error: \(error.localizedDescription)", category: .transcription, level: .warning)
        }
    }

    private func processRemainingMicDiarizationBuffer() async {
        guard !hasSystemSpeech, micAudioBuffer.count >= 48_000 else { return }
        let chunk = micAudioBuffer
        let startTime = micBufferStartTime
        micAudioBuffer = []
        await processMicDiarizationChunk(chunk, startTime: startTime)
    }
}
