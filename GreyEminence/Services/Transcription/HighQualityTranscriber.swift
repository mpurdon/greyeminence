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
        /// Whisper's own certainty, 0–1: the average token probability. High
        /// values do not mean correct — a fluent mis-hearing scores well —
        /// but low values reliably mark garbled audio worth a listen.
        var confidence: Float = 1
        /// RMS of the audio under this segment, from the 16 kHz mono samples
        /// Whisper decoded. On the mic track it separates the user's own
        /// voice from the far side heard through the speakers, which a good
        /// microphone picks up clearly but much more quietly.
        var level: Float = 0
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
    typealias CheckpointCallback = @Sendable (ReProcessingCheckpoint) -> Void

    /// Apple's distilled large-v3 turbo variant (Sept 2024 release).
    /// Substantially faster on Apple Silicon ANE than the non-turbo model,
    /// with transcription quality very close to full large-v3. The full
    /// non-turbo model occasionally fails with CoreML "Unable to compute
    /// the asynchronous prediction" errors on lower-memory machines. Note
    /// the name uses underscores around "turbo" — HuggingFace repo
    /// `argmaxinc/whisperkit-coreml` uses that convention.
    static let modelName = "openai_whisper-large-v3-v20240930_turbo"
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
    /// Chunks the primary decoder refused and the fallback rescued, reported
    /// once per run rather than once per chunk.
    private static let recoveryLock = NSLock()
    nonisolated(unsafe) private static var recoveredChunks = 0

    // MARK: - Prompt and confidence

    /// Whisper reads the prompt as preceding context, so it is worth about
    /// a paragraph of the right nouns. Beyond this the model's own window
    /// (224 tokens) truncates it anyway.
    static let maxPromptTokens = 180

    /// The prompt handed to Whisper before every chunk: the meeting's title,
    /// who was on it, the user's custom vocabulary, and the topics a prior
    /// analysis found. Names and jargon are what the model mishears most,
    /// and a prompt that contains them biases decoding toward them. Written
    /// as prose because Whisper was trained on transcripts, not lists.
    static func promptText(
        title: String,
        participants: [String],
        vocabulary: [String],
        topics: [String]
    ) -> String {
        func clean(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        var sentences: [String] = []
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty { sentences.append("Meeting: \(cleanTitle).") }
        let people = clean(participants)
        if !people.isEmpty { sentences.append("With \(people.prefix(12).joined(separator: ", ")).") }
        let terms = clean(vocabulary)
        if !terms.isEmpty { sentences.append("Terms: \(terms.prefix(40).joined(separator: ", ")).") }
        let subjects = clean(topics)
        if !subjects.isEmpty { sentences.append("Topics: \(subjects.prefix(20).joined(separator: ", ")).") }
        let text = sentences.joined(separator: " ")
        return text.count > 900 ? String(text.prefix(900)) : text
    }

    /// Prompting is OFF until it is proven safe. Measured 2026-09-09 on
    /// WhisperKit 0.9 with `promptTokens` set: two 111-minute meetings came
    /// back as 13 and 19 segments at ~9x realtime, against ~1,800 segments
    /// at ~3x for a prompt-less run the same day — the decoder emits
    /// end-of-text almost immediately once a prompt is prefilled (WhisperKit's
    /// own TODO in `TextDecoder.prepareDecoderInputs` notes the prefill cache
    /// breaks with prompt tokens). The prompt text is still built and logged
    /// so the experiment can be re-run offline; it must not reach the decoder
    /// again without a harness that compares word counts against the
    /// prompt-less run on the same audio.
    static let promptingEnabled = false

    /// Default decoding, plus the prompt when one was given and prompting is
    /// enabled. Every other option stays at WhisperKit's default.
    nonisolated static func decodingOptions(promptText: String?, tokenizer: (any WhisperTokenizer)?) -> DecodingOptions {
        var options = DecodingOptions()
        guard promptingEnabled else { return options }
        if let promptText, !promptText.isEmpty, let tokenizer {
            let tokens = tokenizer.encode(text: " " + promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = Array(tokens.suffix(maxPromptTokens))
                options.usePrefillPrompt = true
            }
        }
        return options
    }

    /// Whether a re-transcription is too thin to replace what the meeting
    /// already has. The live transcript is the floor: a pass that returns a
    /// small fraction of its words did not hear the meeting, whatever the
    /// reason, and swapping it in destroys the only transcript there is.
    /// Short or empty originals are exempt — there is nothing to protect.
    nonisolated static func isImplausiblyThin(newWords: Int, existingWords: Int) -> Bool {
        guard existingWords >= 200 else { return false }
        return Double(newWords) < Double(existingWords) * 0.25
    }

    /// Average token probability from Whisper's average log-probability.
    /// -0.3 (typical clean speech) → 0.74; -1.0 (garbled) → 0.37.
    nonisolated static func confidence(fromAvgLogprob avgLogprob: Float) -> Float {
        guard avgLogprob.isFinite else { return 1 }
        return min(1, max(0, exp(avgLogprob)))
    }

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
    ///
    /// `resumeFrom`: if present, chunks whose filename appears in the
    /// checkpoint's completed lists are skipped, and the checkpoint's
    /// accumulated offset + prior segments are carried forward. `onCheckpoint`
    /// fires after every completed chunk so the caller can persist progress
    /// — that's what makes a yielded / crashed job resumable.
    func transcribe(
        micChunks: [URL],
        systemChunks: [URL],
        resumeFrom: ReProcessingCheckpoint? = nil,
        promptText: String? = nil,
        onProgress: ProgressCallback? = nil,
        onCheckpoint: CheckpointCallback? = nil
    ) async throws -> [Segment] {
        let kit = try await loadWhisperKit()
        let options = Self.decodingOptions(promptText: promptText, tokenizer: kit.tokenizer)
        if let promptText, options.promptTokens?.isEmpty == false {
            LogManager.send("WhisperKit prompt (\(options.promptTokens?.count ?? 0) tokens): \(promptText.prefix(200))", category: .transcription)
        }
        var progress = TranscriptionProgress(checkpoint: resumeFrom)

        let totalChunks = micChunks.count + systemChunks.count
        onProgress?(Progress(chunksDone: progress.completedCount, chunksTotal: totalChunks))
        if progress.completedCount > 0 {
            LogManager.send("Resuming re-transcription: \(progress.completedCount)/\(totalChunks) chunks already done, \(progress.segments.count) prior segments", category: .transcription)
        }

        try await runChunks(
            micChunks,
            source: .mic,
            kit: kit,
            options: options,
            progress: &progress,
            totalChunks: totalChunks,
            onProgress: onProgress,
            onCheckpoint: onCheckpoint
        )
        try await runChunks(
            systemChunks,
            source: .system,
            kit: kit,
            options: options,
            progress: &progress,
            totalChunks: totalChunks,
            onProgress: onProgress,
            onCheckpoint: onCheckpoint
        )

        // Final flush so any chunks accumulated since the last debounced
        // emission are durable in the sidecar.
        onCheckpoint?(progress.makeCheckpoint())

        let recovered = Self.takeRecoveredCount()
        if recovered > 0 {
            LogManager.send(
                "Decoded \(recovered) of \(totalChunks) chunk(s) via the AVAssetReader fallback — audio recovered in full",
                category: .transcription
            )
        }

        progress.segments.sort { $0.startTime < $1.startTime }
        return progress.segments
    }

    /// Mutable transcription state. Bundled (rather than separate locals)
    /// so it can travel as a single `inout` — capturing the locals AND
    /// passing them as inout to a function that invokes a closure mid-loop
    /// trips Swift exclusivity at runtime.
    private struct TranscriptionProgress {
        private var completedMicChunkNames: [String]
        private var completedSystemChunkNames: [String]
        private var accumulatedMicOffset: TimeInterval
        private var accumulatedSystemOffset: TimeInterval
        var segments: [Segment]

        init(checkpoint: ReProcessingCheckpoint?) {
            self.completedMicChunkNames = checkpoint?.completedMicChunkNames ?? []
            self.completedSystemChunkNames = checkpoint?.completedSystemChunkNames ?? []
            self.accumulatedMicOffset = checkpoint?.accumulatedMicOffset ?? 0
            self.accumulatedSystemOffset = checkpoint?.accumulatedSystemOffset ?? 0
            self.segments = (checkpoint?.segments ?? []).map { $0.toSegment() }
        }

        var completedCount: Int {
            completedMicChunkNames.count + completedSystemChunkNames.count
        }

        func alreadyDone(for source: Source) -> Set<String> {
            switch source {
            case .mic: Set(completedMicChunkNames)
            case .system: Set(completedSystemChunkNames)
            }
        }

        func currentOffset(for source: Source) -> TimeInterval {
            switch source {
            case .mic: accumulatedMicOffset
            case .system: accumulatedSystemOffset
            }
        }

        mutating func markComplete(name: String, addOffset: TimeInterval, source: Source) {
            switch source {
            case .mic:
                accumulatedMicOffset += addOffset
                completedMicChunkNames.append(name)
            case .system:
                accumulatedSystemOffset += addOffset
                completedSystemChunkNames.append(name)
            }
        }

        /// Mean duration of the chunks handled so far on a track, used to
        /// estimate one that couldn't be read at all.
        func averageChunkDuration(for source: Source) -> TimeInterval {
            let (offset, count): (TimeInterval, Int) = switch source {
            case .mic: (accumulatedMicOffset, completedMicChunkNames.count)
            case .system: (accumulatedSystemOffset, completedSystemChunkNames.count)
            }
            return HighQualityTranscriber.averageChunkDuration(elapsed: offset, completed: count)
        }

        func makeCheckpoint() -> ReProcessingCheckpoint {
            ReProcessingCheckpoint(
                completedMicChunkNames: completedMicChunkNames,
                completedSystemChunkNames: completedSystemChunkNames,
                accumulatedMicOffset: accumulatedMicOffset,
                accumulatedSystemOffset: accumulatedSystemOffset,
                segments: segments.map(ReProcessingCheckpoint.PersistedSegment.init)
            )
        }
    }

    /// How long a chunk that wouldn't decode was, so the timeline can skip
    /// over it correctly.
    ///
    /// The container header usually survives whatever broke the audio, so it
    /// can be read without decoding a sample. When even that fails, the
    /// average of the chunks already processed is a far better guess than a
    /// constant — chunk length varies by device and by track.
    /// Mean chunk length so far, used to stand in for a chunk that can't be
    /// measured at all.
    ///
    /// Shared with the diarization pass: the two walk the same files and their
    /// timelines are required to agree, so the estimate they fall back on has
    /// to be the same formula rather than two that merely resemble each other.
    nonisolated static func averageChunkDuration(elapsed: TimeInterval, completed: Int) -> TimeInterval {
        guard completed > 0, elapsed > 0 else { return 10 }
        return elapsed / Double(completed)
    }

    nonisolated static func assumedDuration(of url: URL, fallback: TimeInterval) -> TimeInterval {
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            let duration = Double(file.length) / file.processingFormat.sampleRate
            if duration > 0, duration.isFinite { return duration }
        }
        return fallback
    }

    nonisolated private static func takeRecoveredCount() -> Int {
        recoveryLock.lock()
        defer { recoveredChunks = 0; recoveryLock.unlock() }
        return recoveredChunks
    }

    /// Persist a checkpoint roughly every N completed chunks. JSON-encoding
    /// the full segments-so-far on every chunk would be O(N²) over a long
    /// re-process; this caps re-work after a crash to ~N chunks (~2.5 min
    /// at 30 s/chunk) while keeping the per-chunk hot path cheap. The end
    /// of each `runChunks` call also force-flushes, so the bound is tight.
    private static let checkpointEveryNChunks = 5

    private func runChunks(
        _ chunks: [URL],
        source: Source,
        kit: WhisperKit,
        options: DecodingOptions,
        progress: inout TranscriptionProgress,
        totalChunks: Int,
        onProgress: ProgressCallback?,
        onCheckpoint: CheckpointCallback?
    ) async throws {
        let alreadyDone = progress.alreadyDone(for: source)
        var sinceLastCheckpoint = 0

        for (chunkIdx, chunk) in chunks.enumerated() {
            if alreadyDone.contains(chunk.lastPathComponent) { continue }
            let samples: [Float]
            do {
                samples = try Self.decodeTo16kFloatMono(url: chunk)
            } catch {
                // The audio in this chunk is lost, but the clock must not be.
                // Advancing by zero shifts every later segment on this track
                // earlier by the chunk's real duration, and the error
                // accumulates: with 27 failures across a call, the second half
                // of the far side lands before the first half of it finished,
                // and the tail of the meeting ends up with no remote speech at
                // all — every line attributed to the microphone.
                let assumed = Self.assumedDuration(of: chunk, fallback: progress.averageChunkDuration(for: source))
                LogManager.send(
                    "Skipping chunk \(chunkIdx) (\(source)) — decode failed, holding \(String(format: "%.1f", assumed))s of timeline: \(error.localizedDescription)",
                    category: .transcription,
                    level: .warning
                )
                progress.markComplete(name: chunk.lastPathComponent, addOffset: assumed, source: source)
                emitProgress(&sinceLastCheckpoint, progress: progress, total: totalChunks, onProgress: onProgress, onCheckpoint: onCheckpoint)
                continue
            }

            let chunkDuration = TimeInterval(samples.count) / 16000.0
            if samples.count < Self.minChunkSamples {
                LogManager.send("Skipping chunk \(chunkIdx) (\(source), \(samples.count) samples, \(String(format: "%.2f", chunkDuration))s) — below minimum length", category: .transcription, level: .info)
                progress.markComplete(name: chunk.lastPathComponent, addOffset: chunkDuration, source: source)
                emitProgress(&sinceLastCheckpoint, progress: progress, total: totalChunks, onProgress: onProgress, onCheckpoint: onCheckpoint)
                continue
            }

            let rms = Self.rms(samples)
            if rms < Self.silenceRMSThreshold {
                LogManager.send("Skipping chunk \(chunkIdx) (\(source)) — silence (RMS \(String(format: "%.5f", rms)))", category: .transcription, level: .info)
                progress.markComplete(name: chunk.lastPathComponent, addOffset: chunkDuration, source: source)
                emitProgress(&sinceLastCheckpoint, progress: progress, total: totalChunks, onProgress: onProgress, onCheckpoint: onCheckpoint)
                continue
            }

            // Slice into sub-chunks so cancel can break out within ~15 s
            // instead of waiting for the whole 30+ s chunk to finish.
            let chunkBaseOffset = progress.currentOffset(for: source)
            let subChunks = stride(from: 0, to: samples.count, by: Self.maxSamplesPerInference)
            for subStart in subChunks {
                if Task.isCancelled { throw CancellationError() }
                let subEnd = min(subStart + Self.maxSamplesPerInference, samples.count)
                let subSamples = Array(samples[subStart..<subEnd])
                guard subSamples.count >= Self.minChunkSamples else { continue }
                let subOffset = TimeInterval(subStart) / 16000.0
                do {
                    let results = try await kit.transcribe(audioArray: subSamples, decodeOptions: options)
                    for r in results {
                        for seg in r.segments {
                            let text = Self.cleanWhisperText(seg.text)
                            guard !text.isEmpty else { continue }
                            if Self.silenceHallucinations.contains(text.lowercased()) {
                                continue
                            }
                            progress.segments.append(Segment(
                                source: source,
                                text: text,
                                startTime: chunkBaseOffset + subOffset + TimeInterval(seg.start),
                                endTime: chunkBaseOffset + subOffset + TimeInterval(seg.end),
                                confidence: Self.confidence(fromAvgLogprob: seg.avgLogprob),
                                level: Self.level(of: subSamples, from: seg.start, to: seg.end)
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

            progress.markComplete(name: chunk.lastPathComponent, addOffset: chunkDuration, source: source)
            emitProgress(&sinceLastCheckpoint, progress: progress, total: totalChunks, onProgress: onProgress, onCheckpoint: onCheckpoint)
            if Task.isCancelled {
                // Whatever finished since the last debounced checkpoint is
                // real work; a yield to a live recording must not discard
                // it, or the resumed job starts over (2026-09-11, ~9 min).
                if sinceLastCheckpoint > 0 {
                    onCheckpoint?(progress.makeCheckpoint())
                    sinceLastCheckpoint = 0
                }
                throw CancellationError()
            }
        }

        // Force a final checkpoint for this source so the cross-source boundary
        // and the post-loop tail are durable even if the debounce hasn't ticked.
        if sinceLastCheckpoint > 0 {
            onCheckpoint?(progress.makeCheckpoint())
        }
    }

    private func emitProgress(_ sinceLastCheckpoint: inout Int, progress: TranscriptionProgress, total: Int, onProgress: ProgressCallback?, onCheckpoint: CheckpointCallback?) {
        onProgress?(Progress(chunksDone: progress.completedCount, chunksTotal: total))
        sinceLastCheckpoint += 1
        if sinceLastCheckpoint >= Self.checkpointEveryNChunks {
            onCheckpoint?(progress.makeCheckpoint())
            sinceLastCheckpoint = 0
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

    /// RMS of the samples between two segment times (seconds into `samples`,
    /// which are 16 kHz). Bounds are clamped: Whisper's segment times can
    /// overshoot the audio it was given by a frame or two.
    nonisolated static func level(of samples: [Float], from start: Float, to end: Float) -> Float {
        let lower = max(0, Int(start * 16000))
        let upper = min(samples.count, Int(end * 16000))
        guard upper > lower else { return 0 }
        return rms(Array(samples[lower..<upper]))
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
    /// Shared with the diarization pass, which has to walk the same chunk
    /// files on the same timeline.
    nonisolated static func decodeTo16kFloatMono(url: URL) throws -> [Float] {
        do {
            return try decodeViaAVAudioFile(url: url)
        } catch {
            if let recovered = try? decodeViaAssetReader(url: url), !recovered.isEmpty {
                // Counted, not logged. AVAudioFile refuses a sizeable minority
                // of chunks — measured at 9 in 60 on a real recording — and
                // the fallback recovers every one of them in full, so this is
                // a slower path rather than a fault. Logging each occurrence
                // wrote 3,874 identical lines in a day and buried everything
                // else; the per-run total says the same thing.
                recoveryLock.lock()
                recoveredChunks += 1
                recoveryLock.unlock()
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
