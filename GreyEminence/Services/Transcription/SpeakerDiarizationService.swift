import Foundation
import AVFoundation
import FluidAudio

actor SpeakerDiarizationService {
    enum State: Sendable {
        case uninitialized
        case downloading
        case ready
        case processing
        case error(String)
    }

    private(set) var state: State = .uninitialized

    private var diarizer: DiarizerManager?
    private var audioStream: AudioStream?
    private var audioConverter: AudioConverter?
    private var speakerMap: [String: Speaker] = [:]
    private var nextSpeakerIndex = 1

    private let config: DiarizerConfig

    init(config: DiarizerConfig = .default) {
        self.config = config
    }

    // MARK: - Lifecycle

    func prepare() async throws {
        state = .downloading
        LogManager.send("Preparing diarization models", category: .transcription)
        let models = try await DiarizerModels.downloadIfNeeded(
            to: nil,
            configuration: nil
        )
        let manager = DiarizerManager(config: config)
        manager.initialize(models: models)
        self.diarizer = manager
        self.audioConverter = AudioConverter()
        state = .ready
        LogManager.send("Diarization models ready", category: .transcription)
    }

    func startStreaming() throws {
        guard diarizer != nil else {
            throw DiarizationError.notInitialized
        }

        audioStream = try AudioStream(
            chunkDuration: 10.0,
            chunkSkip: 5.0,
            streamStartTime: 0.0,
            chunkingStrategy: .useFixedSkip,
            sampleRate: 16_000
        )

        speakerMap = [:]
        nextSpeakerIndex = 1
        state = .processing
        LogManager.send("Diarization streaming started", category: .transcription)
    }

    func stopStreaming() {
        audioStream = nil
        state = .ready
        LogManager.send("Diarization streaming stopped", category: .transcription)
    }

    /// Process an audio buffer and return diarization segments with resolved speaker identities.
    func processBuffer(_ buffer: AVAudioPCMBuffer) throws -> [DiarizedSegment] {
        guard let diarizer, let converter = audioConverter else {
            throw DiarizationError.notInitialized
        }

        let samples = try converter.resampleBuffer(buffer)
        guard samples.count >= 48_000 else { return [] } // need ~3s minimum

        let result = try diarizer.performCompleteDiarization(
            samples,
            sampleRate: 16000
        )

        return result.segments.map { segment in
            let speaker = resolvedSpeaker(for: segment.speakerId)
            return DiarizedSegment(
                speaker: speaker,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds),
                confidence: segment.qualityScore
            )
        }
    }

    /// Process raw Float32 samples at 16kHz and return diarized segments.
    func processSamples(_ samples: [Float], atTime startTime: TimeInterval = 0) throws -> [DiarizedSegment] {
        guard let diarizer else {
            throw DiarizationError.notInitialized
        }

        guard samples.count >= 48_000 else { return [] }

        let result = try diarizer.performCompleteDiarization(
            samples,
            sampleRate: 16000,
            atTime: startTime
        )

        return result.segments.map { segment in
            let speaker = resolvedSpeaker(for: segment.speakerId)
            return DiarizedSegment(
                speaker: speaker,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds),
                confidence: segment.qualityScore
            )
        }
    }

    /// Feed audio into the streaming pipeline and get results when a chunk is complete.
    func feedAudio(_ buffer: AVAudioPCMBuffer) throws {
        try audioStream?.write(from: buffer)
    }

    // MARK: - Speaker Resolution

    /// Map internal FluidAudio speaker IDs to stable Speaker enum values.
    private func resolvedSpeaker(for fluidSpeakerId: String) -> Speaker {
        if let existing = speakerMap[fluidSpeakerId] {
            return existing
        }
        let speaker = Speaker.other("Speaker \(nextSpeakerIndex)")
        speakerMap[fluidSpeakerId] = speaker
        nextSpeakerIndex += 1
        return speaker
    }

    /// Mark a specific FluidAudio speaker ID as "Me" (from mic channel correlation).
    func identifyAsMeSpeaker(_ fluidSpeakerId: String) {
        speakerMap[fluidSpeakerId] = .me
    }

    func reset() {
        speakerMap = [:]
        nextSpeakerIndex = 1
    }

    var isReady: Bool {
        if case .ready = state { return true }
        if case .processing = state { return true }
        return false
    }
}

// MARK: - Types

struct DiarizedSegment: Sendable {
    let speaker: Speaker
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float
}

enum DiarizationError: Error, LocalizedError {
    case notInitialized
    case modelDownloadFailed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "Diarization service not initialized. Call prepare() first."
        case .modelDownloadFailed(let reason):
            "Failed to download diarization models: \(reason)"
        case .processingFailed(let reason):
            "Diarization processing failed: \(reason)"
        }
    }
}
