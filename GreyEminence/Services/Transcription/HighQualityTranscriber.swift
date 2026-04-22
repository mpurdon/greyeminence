import Foundation
import AVFoundation
@preconcurrency import WhisperKit

/// Offline, high-accuracy transcription using WhisperKit large-v3. Intentionally
/// uses a separate framework from the live FluidAudio pipeline so the two never
/// share state or ANE resources implicitly — the live transcription keeps
/// running undisturbed if the user starts a new recording while an older one
/// is still being re-transcribed in the background.
actor HighQualityTranscriber {
    struct Segment: Sendable {
        let source: Source
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    enum Source: Sendable {
        case mic
        case system
    }

    /// Same model used both times we transcribe — cached after first download.
    private static let modelName = "openai_whisper-large-v3"

    private var whisper: WhisperKit?

    private func loadWhisperKit() async throws -> WhisperKit {
        if let whisper { return whisper }
        LogManager.send("WhisperKit: loading \(Self.modelName) (first load ~1.5GB download)", category: .transcription)
        let config = WhisperKitConfig(model: Self.modelName, verbose: false)
        let kit = try await WhisperKit(config)
        whisper = kit
        LogManager.send("WhisperKit: model loaded", category: .transcription)
        return kit
    }

    /// Transcribe all chunks for a meeting. Returns merged mic + system segments
    /// sorted by startTime. Caller is responsible for swapping these into the
    /// meeting's `segments` relationship on the main actor.
    func transcribe(micChunks: [URL], systemChunks: [URL]) async throws -> [Segment] {
        let kit = try await loadWhisperKit()

        var segments: [Segment] = []
        try await runChunks(micChunks, source: .mic, kit: kit, into: &segments)
        try await runChunks(systemChunks, source: .system, kit: kit, into: &segments)

        segments.sort { $0.startTime < $1.startTime }
        return segments
    }

    private func runChunks(
        _ chunks: [URL],
        source: Source,
        kit: WhisperKit,
        into segments: inout [Segment]
    ) async throws {
        var accumulatedOffset: TimeInterval = 0
        for chunk in chunks {
            let samples = try Self.decodeTo16kFloatMono(url: chunk)
            guard !samples.isEmpty else { continue }
            let results = try await kit.transcribe(audioArray: samples)
            let chunkDuration = TimeInterval(samples.count) / 16000.0
            for r in results {
                for seg in r.segments {
                    let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    segments.append(Segment(
                        source: source,
                        text: text,
                        startTime: accumulatedOffset + TimeInterval(seg.start),
                        endTime: accumulatedOffset + TimeInterval(seg.end)
                    ))
                }
            }
            accumulatedOffset += chunkDuration
            if Task.isCancelled { throw CancellationError() }
        }
    }

    /// Decode an AAC/m4a chunk to 16 kHz mono Float32 samples, which is what
    /// WhisperKit expects for `transcribe(audioArray:)`.
    nonisolated private static func decodeTo16kFloatMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return [] }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }

        let srcCapacity: AVAudioFrameCount = 4096
        guard let srcBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: srcCapacity
        ) else { return [] }

        var output: [Float] = []
        output.reserveCapacity(Int(file.length / Int64(file.processingFormat.sampleRate) * 16000))

        var eof = false
        while !eof {
            try file.read(into: srcBuffer)
            if srcBuffer.frameLength == 0 { break }

            let outCapacity = AVAudioFrameCount(
                Double(srcBuffer.frameLength) * (16000.0 / file.processingFormat.sampleRate) + 1024
            )
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { break }

            var error: NSError?
            var supplied = false
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return srcBuffer
            }

            if let error { throw error }
            if status == .error { break }

            if let channelData = outBuffer.floatChannelData?.pointee {
                let count = Int(outBuffer.frameLength)
                let buf = UnsafeBufferPointer(start: channelData, count: count)
                output.append(contentsOf: buf)
            }

            if srcBuffer.frameLength < srcCapacity { eof = true }
        }

        return output
    }
}
