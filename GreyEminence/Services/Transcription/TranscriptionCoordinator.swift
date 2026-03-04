import AVFoundation

/// Orchestrates audio capture, speech recognition, and speaker diarization
/// into a unified timeline of transcript segments.
@Observable
@MainActor
final class TranscriptionCoordinator {
    var segments: [TranscriptSegment] = []
    var isProcessing = false
    var dictationDisabled = false

    private let formatConverter = AudioFormatConverter()
    private let micRecognition = SpeechRecognitionService(source: "mic")
    private let systemRecognition = SpeechRecognitionService(source: "sys")
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

    // MARK: - Lifecycle

    func start() async throws {
        // Clean up any lingering state from a previous run
        micRecognition.stopRecognition()
        systemRecognition.stopRecognition()

        isProcessing = true
        dictationDisabled = false
        segments = []
        systemAudioBuffer = []
        micAudioBuffer = []
        hasSystemSpeech = false

        // Wire up dictation-disabled detection
        micRecognition.onDictationDisabled = { @Sendable [weak self] in
            Task { @MainActor in
                self?.dictationDisabled = true
            }
        }

        // Request speech recognition authorization
        let authorized = await micRecognition.requestAuthorization()
        guard authorized else {
            LogManager.shared.log("Speech recognition authorization denied", category: .transcription, level: .error)
            throw TranscriptionError.speechRecognitionDenied
        }
        LogManager.shared.log("Speech recognition authorized", category: .transcription)

        // Start speech recognition streams
        LogManager.shared.log("Starting speech recognition streams", category: .transcription)
        let micStream = try micRecognition.startRecognition()
        let sysStream = try systemRecognition.startRecognition()
        LogManager.shared.log("Mic and system recognition streams active", category: .transcription)

        // Prepare diarization (downloads models if needed)
        do {
            try await diarization.prepare()
            try await diarization.startStreaming()
            LogManager.shared.log("Diarization ready", category: .transcription)
        } catch {
            LogManager.shared.log("Diarization setup failed (non-fatal): \(error.localizedDescription)", category: .transcription, level: .warning)
        }

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
        micRecognition.stopRecognition()
        systemRecognition.stopRecognition()

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
        micRecognition.appendAudio(buffer)

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
        systemRecognition.appendAudio(buffer)

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

    private func handleMicUpdate(_ update: SpeechRecognitionService.TranscriptUpdate) {
        let textEmpty = update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Empty final result — finalize existing draft instead of discarding it
        if textEmpty {
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
            segments.removeAll { $0.id == draftID }
        }

        let segment = TranscriptSegment(
            speaker: .me,
            text: update.text,
            startTime: update.timestamp,
            endTime: update.timestamp,
            isFinal: update.isFinal
        )

        if update.isFinal {
            currentMicDraftID = nil
            LogManager.shared.log("Mic segment finalized: \(update.text.prefix(80))", category: .transcription)
        } else {
            currentMicDraftID = segment.id
        }

        segments.append(segment)
    }

    private func handleSystemUpdate(_ update: SpeechRecognitionService.TranscriptUpdate) {
        let textEmpty = update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !textEmpty {
            hasSystemSpeech = true
        }

        // Empty final result — finalize existing draft instead of discarding it
        if textEmpty {
            if update.isFinal, let draftID = currentSystemDraftID,
               let idx = segments.firstIndex(where: { $0.id == draftID }) {
                segments[idx].isFinal = true
                currentSystemDraftID = nil
                LogManager.shared.log("System draft promoted to final: \(segments[idx].text.prefix(80))", category: .transcription)
            }
            return
        }

        // Remove previous draft (will be replaced with updated text below)
        if let draftID = currentSystemDraftID {
            segments.removeAll { $0.id == draftID }
        }

        let segment = TranscriptSegment(
            speaker: .other("Other"),
            text: update.text,
            startTime: update.timestamp,
            endTime: update.timestamp,
            isFinal: update.isFinal
        )

        if update.isFinal {
            currentSystemDraftID = nil
            LogManager.shared.log("System segment finalized: \(update.text.prefix(80))", category: .transcription)
        } else {
            currentSystemDraftID = segment.id
        }

        segments.append(segment)
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

enum TranscriptionError: Error, LocalizedError {
    case speechRecognitionDenied

    var errorDescription: String? {
        "Speech recognition permission is required for live transcription"
    }
}
