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
    }

    let source: AudioSource

    private struct MutableState {
        var manager: StreamingAsrManager?
        var continuation: AsyncStream<TranscriptUpdate>.Continuation?
        var startTime: TimeInterval = 0
        var hasLoggedFirstBuffer = false
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
    func startRecognition(models: AsrModels) async throws -> AsyncStream<TranscriptUpdate> {
        let mgr = StreamingAsrManager(config: .default)
        let now = ProcessInfo.processInfo.systemUptime

        state.withLock { s in
            s.manager = mgr
            s.startTime = now
            s.hasLoggedFirstBuffer = false
        }

        let stream = AsyncStream<TranscriptUpdate> { [state] continuation in
            state.withLock { s in
                s.continuation = continuation
            }
            continuation.onTermination = { @Sendable _ in }
        }

        try await mgr.start(models: models, source: source)
        LogManager.send("[\(sourceLabel)] Streaming ASR started", category: .transcription)

        let capturedStartTime = now
        let label = sourceLabel
        listeningTask = Task { [weak self, state] in
            for await update in await mgr.transcriptionUpdates {
                guard self != nil, !Task.isCancelled else { break }
                let elapsed = ProcessInfo.processInfo.systemUptime - capturedStartTime
                let transcriptUpdate = TranscriptUpdate(
                    text: update.text,
                    isFinal: update.isConfirmed,
                    timestamp: elapsed
                )
                let cont = state.withLock { $0.continuation }
                cont?.yield(transcriptUpdate)
            }
            LogManager.send("[\(label)] Transcription stream ended", category: .transcription)
        }

        return stream
    }

    /// Feed audio buffer into the ASR engine.
    /// Thread-safe — can be called from any thread (audio callback thread).
    /// FluidAudio handles resampling to 16kHz mono internally.
    func feedAudio(_ buffer: AVAudioPCMBuffer) {
        let (mgr, logged) = state.withLock { s -> (StreamingAsrManager?, Bool) in
            let alreadyLogged = s.hasLoggedFirstBuffer
            s.hasLoggedFirstBuffer = true
            return (s.manager, alreadyLogged)
        }
        if !logged {
            let fmt = buffer.format
            LogManager.send(
                "[\(sourceLabel)] First ASR buffer: \(Int(fmt.sampleRate))Hz, \(fmt.channelCount)ch, \(buffer.frameLength) frames",
                category: .transcription
            )
        }
        guard let mgr else { return }
        Task {
            await mgr.streamAudio(buffer)
        }
    }

    /// Stop recognition, finalize any remaining text, and clean up.
    func stopRecognition() async {
        let (mgr, cont) = state.withLock { s -> (StreamingAsrManager?, AsyncStream<TranscriptUpdate>.Continuation?) in
            let m = s.manager
            let c = s.continuation
            s.manager = nil
            s.continuation = nil
            return (m, c)
        }

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
