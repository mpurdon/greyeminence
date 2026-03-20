@preconcurrency import AVFoundation
import FluidAudio
import os

/// Wraps FluidAudio's StreamingAsrManager for live streaming transcription.
/// Uses Parakeet TDT model via CoreML on Apple Neural Engine — no session limits,
/// no dictation permission required, handles audio resampling internally.
final class FluidAsrService: @unchecked Sendable {
    struct TranscriptUpdate: Sendable {
        let text: String
        let isFinal: Bool
        let timestamp: TimeInterval
        let confidence: Float
    }

    let source: AudioSource

    private struct MutableState {
        var manager: StreamingAsrManager?
        var continuation: AsyncStream<TranscriptUpdate>.Continuation?
        var startTime: TimeInterval = 0
        var hasLoggedFirstBuffer = false
        var bufferCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: MutableState())
    private var listeningTask: Task<Void, Never>?

    init(source: AudioSource) {
        self.source = source
    }

    private var sourceLabel: String {
        source == .microphone ? "mic" : "sys"
    }

    /// Start streaming recognition with pre-loaded models.
    /// Returns an AsyncStream of transcript updates (confirmed + volatile).
    func startRecognition(models: AsrModels, vocabularyContext: CustomVocabularyContext? = nil) async throws -> AsyncStream<TranscriptUpdate> {
        let mgr = StreamingAsrManager(config: .streaming)
        let now = ProcessInfo.processInfo.systemUptime

        let stream = AsyncStream<TranscriptUpdate> { [state] continuation in
            state.withLock { s in
                s.continuation = continuation
            }
            continuation.onTermination = { @Sendable _ in }
        }

        // IMPORTANT: Subscribe to transcriptionUpdates BEFORE calling start().
        // This ensures updateContinuation is set inside the manager before
        // the recognizerTask processes any audio windows.
        let mgrUpdates = await mgr.transcriptionUpdates

        let capturedStartTime = now
        let label = sourceLabel
        listeningTask = Task { [weak self, state] in
            LogManager.send("[\(label)] Listening task started, consuming transcriptionUpdates", category: .transcription)
            var updateCount = 0
            for await update in mgrUpdates {
                guard self != nil, !Task.isCancelled else { break }
                updateCount += 1
                let elapsed = ProcessInfo.processInfo.systemUptime - capturedStartTime
                let transcriptUpdate = TranscriptUpdate(
                    text: update.text,
                    isFinal: update.isConfirmed,
                    timestamp: elapsed,
                    confidence: update.confidence
                )
                LogManager.send(
                    "[\(label)] ASR update #\(updateCount) (confirmed=\(update.isConfirmed), conf=\(String(format: "%.2f", update.confidence))): \(update.text.prefix(80))",
                    category: .transcription
                )
                let cont = state.withLock { $0.continuation }
                cont?.yield(transcriptUpdate)
            }
            LogManager.send("[\(label)] Transcription stream ended after \(updateCount) updates", category: .transcription)
        }

        // Configure vocabulary boosting if provided
        if let vocabularyContext {
            do {
                let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                try await mgr.configureVocabularyBoosting(
                    vocabulary: vocabularyContext,
                    ctcModels: ctcModels
                )
                LogManager.send("[\(sourceLabel)] Vocabulary boosting configured (\(vocabularyContext.terms.count) terms)", category: .transcription)
            } catch {
                LogManager.send("[\(sourceLabel)] Vocabulary boosting setup failed (non-fatal): \(error.localizedDescription)", category: .transcription, level: .warning)
            }
        }

        // Now start the ASR engine — recognizerTask will find updateContinuation already set
        try await mgr.start(models: models, source: source)
        LogManager.send("[\(sourceLabel)] Streaming ASR started", category: .transcription)

        // Set manager AFTER start() so feedAudio doesn't send buffers before the engine is ready
        state.withLock { s in
            s.manager = mgr
            s.startTime = now
            s.hasLoggedFirstBuffer = false
            s.bufferCount = 0
        }

        return stream
    }

    /// Feed audio buffer into the ASR engine.
    /// Thread-safe — can be called from any thread (audio callback thread).
    /// FluidAudio handles resampling to 16kHz mono internally.
    func feedAudio(_ buffer: AVAudioPCMBuffer) {
        let (mgr, logged, count) = state.withLock { s -> (StreamingAsrManager?, Bool, Int) in
            let alreadyLogged = s.hasLoggedFirstBuffer
            s.hasLoggedFirstBuffer = true
            s.bufferCount += 1
            return (s.manager, alreadyLogged, s.bufferCount)
        }
        if !logged {
            let fmt = buffer.format
            LogManager.send(
                "[\(sourceLabel)] First ASR buffer: \(Int(fmt.sampleRate))Hz, \(fmt.channelCount)ch, \(buffer.frameLength) frames",
                category: .transcription
            )
        }
        if count > 0 && count % 500 == 0 {
            LogManager.send("[\(sourceLabel)] Fed \(count) buffers to ASR", category: .transcription)
        }
        guard let mgr else { return }
        Task {
            await mgr.streamAudio(buffer)
        }
    }

    /// Stop recognition, finalize any remaining text, and clean up.
    func stopRecognition() async {
        let (mgr, cont, bufferCount) = state.withLock { s -> (StreamingAsrManager?, AsyncStream<TranscriptUpdate>.Continuation?, Int) in
            let m = s.manager
            let c = s.continuation
            let count = s.bufferCount
            s.manager = nil
            s.continuation = nil
            return (m, c, count)
        }

        LogManager.send("[\(sourceLabel)] Stopping ASR (fed \(bufferCount) buffers total)", category: .transcription)

        listeningTask?.cancel()
        listeningTask = nil

        if let mgr {
            _ = try? await mgr.finish()
            await mgr.cancel()
            LogManager.send("[\(sourceLabel)] Streaming ASR stopped", category: .transcription)
        }
        cont?.finish()
    }
}
