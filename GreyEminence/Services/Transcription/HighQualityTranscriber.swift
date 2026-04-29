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

    struct Progress: Sendable, Equatable {
        var chunksDone: Int
        var chunksTotal: Int
        var fraction: Double {
            chunksTotal > 0 ? Double(chunksDone) / Double(chunksTotal) : 0
        }
    }

    typealias ProgressCallback = @Sendable (Progress) -> Void

    /// Apple's distilled large-v3 turbo variant (Sept 2024 release).
    /// Substantially faster on Apple Silicon ANE than the non-turbo model,
    /// with transcription quality very close to full large-v3. The full
    /// non-turbo model occasionally fails with CoreML "Unable to compute
    /// the asynchronous prediction" errors on lower-memory machines. Note
    /// the name uses underscores around "turbo" — HuggingFace repo
    /// `argmaxinc/whisperkit-coreml` uses that convention.
    private static let modelName = "openai_whisper-large-v3-v20240930_turbo"
    private static let minChunkSamples = 1600 // 0.1s at 16 kHz
    /// Maximum samples fed to a single `kit.transcribe` call. WhisperKit's
    /// transcribe call isn't cancellable mid-flight, so worst-case cancel
    /// latency equals the duration of one sub-chunk. 15 s × 16 kHz keeps
    /// model context decent (large-v3 internally windows at 30 s) while
    /// bounding cancel response time.
    private static let maxSamplesPerInference = 15 * 16000

    /// RMS below this level is treated as silence and the chunk is skipped
    /// entirely. Whisper hallucinates stock phrases ("Thank you.", "you",
    /// "Thanks for watching.") when fed silence — skipping the chunk is
    /// both faster and more accurate than letting the model confabulate.
    /// -50 dBFS catches room tone and quiet ventilation; real speech is
    /// typically -30 to -15 dBFS.
    private static let silenceRMSThreshold: Float = 0.003 // ≈ -50 dBFS

    /// Known Whisper silence-hallucination phrases (normalized). If a chunk's
    /// only output matches one of these, we drop it. Belt-and-suspenders for
    /// the silence-RMS gate — catches cases where there's just enough noise
    /// to pass the gate but still no real speech.
    private static let silenceHallucinations: Set<String> = [
        "thank you",
        "thank you.",
        "thanks for watching",
        "thanks for watching.",
        "thanks for watching!",
        "you",
        "you.",
        "bye",
        "bye.",
        "bye!",
        "[music]",
        "♪",
        "♪♪",
        ".",
        "..",
        "...",
    ]

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
    func transcribe(
        micChunks: [URL],
        systemChunks: [URL],
        onProgress: ProgressCallback? = nil
    ) async throws -> [Segment] {
        let kit = try await loadWhisperKit()
        let totalChunks = micChunks.count + systemChunks.count
        var chunksDone = 0
        onProgress?(Progress(chunksDone: 0, chunksTotal: totalChunks))

        var segments: [Segment] = []
        try await runChunks(micChunks, source: .mic, kit: kit, into: &segments, chunksDone: &chunksDone, totalChunks: totalChunks, onProgress: onProgress)
        try await runChunks(systemChunks, source: .system, kit: kit, into: &segments, chunksDone: &chunksDone, totalChunks: totalChunks, onProgress: onProgress)

        segments.sort { $0.startTime < $1.startTime }
        return segments
    }

    private func runChunks(
        _ chunks: [URL],
        source: Source,
        kit: WhisperKit,
        into segments: inout [Segment],
        chunksDone: inout Int,
        totalChunks: Int,
        onProgress: ProgressCallback?
    ) async throws {
        var accumulatedOffset: TimeInterval = 0
        for (chunkIdx, chunk) in chunks.enumerated() {
            let samples: [Float]
            do {
                samples = try Self.decodeTo16kFloatMono(url: chunk)
            } catch {
                LogManager.send("Skipping chunk \(chunkIdx) (\(source)) — decode failed: \(error.localizedDescription)", category: .transcription, level: .warning)
                chunksDone += 1
                onProgress?(Progress(chunksDone: chunksDone, chunksTotal: totalChunks))
                continue
            }

            let chunkDuration = TimeInterval(samples.count) / 16000.0
            if samples.count < Self.minChunkSamples {
                LogManager.send("Skipping chunk \(chunkIdx) (\(source), \(samples.count) samples, \(String(format: "%.2f", chunkDuration))s) — below minimum length", category: .transcription, level: .info)
                accumulatedOffset += chunkDuration
                chunksDone += 1
                onProgress?(Progress(chunksDone: chunksDone, chunksTotal: totalChunks))
                continue
            }

            let rms = Self.rms(samples)
            if rms < Self.silenceRMSThreshold {
                LogManager.send("Skipping chunk \(chunkIdx) (\(source)) — silence (RMS \(String(format: "%.5f", rms)))", category: .transcription, level: .info)
                accumulatedOffset += chunkDuration
                chunksDone += 1
                onProgress?(Progress(chunksDone: chunksDone, chunksTotal: totalChunks))
                continue
            }

            // Slice into sub-chunks so cancel can break out within ~15 s
            // instead of waiting for the whole 30+ s chunk to finish.
            let subChunks = stride(from: 0, to: samples.count, by: Self.maxSamplesPerInference)
            for subStart in subChunks {
                if Task.isCancelled { throw CancellationError() }
                let subEnd = min(subStart + Self.maxSamplesPerInference, samples.count)
                let subSamples = Array(samples[subStart..<subEnd])
                guard subSamples.count >= Self.minChunkSamples else { continue }
                let subOffset = TimeInterval(subStart) / 16000.0
                do {
                    let results = try await kit.transcribe(audioArray: subSamples)
                    for r in results {
                        for seg in r.segments {
                            let text = Self.cleanWhisperText(seg.text)
                            guard !text.isEmpty else { continue }
                            if Self.silenceHallucinations.contains(text.lowercased()) {
                                continue
                            }
                            segments.append(Segment(
                                source: source,
                                text: text,
                                startTime: accumulatedOffset + subOffset + TimeInterval(seg.start),
                                endTime: accumulatedOffset + subOffset + TimeInterval(seg.end)
                            ))
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    LogManager.send(
                        "Sub-chunk inference failed (chunk \(chunkIdx) \(source) @ \(Int(subOffset))s, \(subSamples.count) samples) — continuing: \(error.localizedDescription)",
                        category: .transcription,
                        level: .warning
                    )
                }
            }

            accumulatedOffset += chunkDuration
            chunksDone += 1
            onProgress?(Progress(chunksDone: chunksDone, chunksTotal: totalChunks))
            if Task.isCancelled { throw CancellationError() }
        }
    }

    /// Strip Whisper's special tokens (`<|startoftranscript|>`, `<|en|>`,
    /// `<|transcribe|>`, `<|endoftext|>`, and inline timestamps like `<|7.06|>`)
    /// that can leak into segment text verbatim.
    nonisolated private static let specialTokenRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"<\|[^|]*\|>"#)
    }()

    nonisolated private static func cleanWhisperText(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let stripped = specialTokenRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    /// Decode an AAC/m4a chunk to 16 kHz mono Float32 samples, which is what
    /// WhisperKit expects for `transcribe(audioArray:)`. Tries AVAudioFile
    /// first; falls back to AVAssetReader for slightly malformed containers
    /// that AVAudioFile refuses to open.
    nonisolated private static func decodeTo16kFloatMono(url: URL) throws -> [Float] {
        do {
            return try decodeViaAVAudioFile(url: url)
        } catch {
            if let recovered = try? decodeViaAssetReader(url: url), !recovered.isEmpty {
                LogManager.send("Recovered chunk via AVAssetReader after AVAudioFile failure: \(url.lastPathComponent)", category: .transcription, level: .info)
                return recovered
            }
            throw error
        }
    }

    nonisolated private static func decodeViaAVAudioFile(url: URL) throws -> [Float] {
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

    /// Fallback decoder using AVAssetReader. Handles malformed AAC containers
    /// that AVAudioFile refuses to open. Always returns 16 kHz mono Float32
    /// regardless of source format.
    nonisolated private static func decodeViaAssetReader(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)

        let tracks = asset.tracks(withMediaType: .audio)
        guard let track = tracks.first else { return [] }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(trackOutput)
        guard reader.startReading() else {
            if let err = reader.error { throw err }
            return []
        }

        var output: [Float] = []
        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            if status == kCMBlockBufferNoErr, let dataPointer {
                let count = length / MemoryLayout<Float>.size
                dataPointer.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
                    let buf = UnsafeBufferPointer(start: floatPtr, count: count)
                    output.append(contentsOf: buf)
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }
        if reader.status == .failed, let err = reader.error { throw err }
        return output
    }
}
