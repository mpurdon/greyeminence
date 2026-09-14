import AVFoundation

/// Writes audio buffers to disk in small chunks for crash resilience.
///
/// AVAudioFile doesn't expose an fsync primitive and only finalizes the AAC
/// container metadata when the file is closed. If the app crashes mid-recording,
/// the live file is unplayable. Chunking solves this: the writer periodically
/// closes the current file (finalizing it) and opens a new one, so on crash
/// the user only loses audio written since the last checkpoint.
///
/// Chunk naming derives from the original URL:
///   mic.m4a          → chunk 0
///   mic.part001.m4a  → chunk 1
///   mic.part002.m4a  → chunk 2
///   …
///
/// Backward compatible: if `checkpoint` is never called, only `mic.m4a` is
/// written and behavior matches the pre-chunking version.
actor AudioFileWriter {
    private var audioFile: AVAudioFile?
    private let baseURL: URL
    private let fileFormat: AVAudioFormat
    private var chunkIndex: Int = 0
    private var chunkURLsInternal: [URL] = []
    /// Cached format used to start the first chunk. Needed so `checkpoint` can
    /// open the next chunk without the caller re-specifying the format.
    private var startedFormat: AVAudioFormat?
    /// Set when buffers cannot go straight to the file: the device's own
    /// format was refused by the encoder, or the capture moved to another
    /// microphone mid-recording and the new device speaks a different
    /// format. Either way the file stays in the format it was opened with.
    private var converter: AVAudioConverter?
    /// The format buffers currently arrive in. A buffer in any other format
    /// re-derives `converter`; see `adoptInputFormat`.
    private var acceptedInputFormat: AVAudioFormat?
    /// Reused across writes; see `convertIfNeeded`.
    private var conversionBuffer: AVAudioPCMBuffer?
    /// Rolling count of write failures. Callers use this to detect a persistent
    /// problem (e.g. full disk, encoder-format mismatch) and stop recording
    /// before filling the log with silent-failure noise.
    private(set) var consecutiveWriteFailures: Int = 0
    private(set) var totalWriteFailures: Int = 0
    private(set) var lastWriteError: String?

    init(outputURL: URL, format: AVAudioFormat? = nil) {
        self.baseURL = outputURL
        // Default: AAC in .m4a container
        self.fileFormat = format ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!
    }

    func start(inputFormat: AVAudioFormat) throws {
        // The device format is preferred — writing buffers straight through
        // avoids a conversion per buffer. But an aggregate device can present
        // something the AAC encoder refuses, and refusing to record at all is
        // a far worse outcome than resampling: the recording is unrepeatable,
        // and without audio there is no re-transcription and no diarization.
        var writeFormat = inputFormat
        do {
            try Self.preflightEncoder(for: inputFormat)
            converter = nil
        } catch {
            let fallback = Self.fallbackFormat(for: inputFormat)
            do {
                try Self.preflightEncoder(for: fallback)
            } catch {
                throw AudioFileWriterError.encoderPreflightFailed(
                    "\(Self.describe(inputFormat)) and fallback \(Self.describe(fallback)) both rejected: \(error.localizedDescription)"
                )
            }
            guard let made = AVAudioConverter(from: inputFormat, to: fallback) else {
                throw AudioFileWriterError.encoderPreflightFailed(
                    "\(Self.describe(inputFormat)) rejected and no converter to \(Self.describe(fallback))"
                )
            }
            converter = made
            writeFormat = fallback
            LogManager.send(
                "Audio encoder rejected \(Self.describe(inputFormat)) — recording via \(Self.describe(fallback)) instead",
                category: .audio,
                level: .warning
            )
        }
        startedFormat = writeFormat
        acceptedInputFormat = inputFormat
        // If we're resuming an interrupted recording, the base URL and/or
        // its part siblings may already exist on disk from the prior session.
        // Writing into the base URL via AVAudioFile(forWriting:) would truncate
        // those files and lose audio — so before opening anything, scan for
        // existing chunks and bump `chunkIndex` past the highest one found.
        chunkIndex = Self.nextChunkIndex(base: baseURL)
        // Previously-existing chunks are preserved but not tracked as ours;
        // callers can enumerate them with `Self.existingChunkURLs(base:)`.
        //
        // `writeFormat`, not `inputFormat`: when a converter is in play the
        // buffers reaching the file are in the fallback format, and opening
        // the file against the device format would mismatch every write.
        try openChunk(inputFormat: writeFormat)
    }

    /// Verify the encoder accepts `inputFormat` by writing a throwaway silent
    /// buffer to a temp file, closing it, then re-opening it for read. Throws
    /// `AudioFileWriterError.encoderPreflightFailed` on any step so recording
    /// startup can surface the real encoder error before the user commits an
    /// hour of audio to settings that silently reject every buffer.
    nonisolated static func preflightEncoder(for inputFormat: AVAudioFormat) throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ge-preflight-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            let file = try AVAudioFile(
                forWriting: tmpURL,
                settings: encoderSettings(for: inputFormat),
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            guard let probe = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1024) else {
                throw AudioFileWriterError.encoderPreflightFailed("buffer alloc failed")
            }
            probe.frameLength = 1024
            try file.write(from: probe)
        } catch let err as AudioFileWriterError {
            throw err
        } catch {
            throw AudioFileWriterError.encoderPreflightFailed(error.localizedDescription)
        }

        do {
            _ = try AVAudioFile(forReading: tmpURL)
        } catch {
            throw AudioFileWriterError.encoderPreflightFailed("probe file unreadable: \(error.localizedDescription)")
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let audioFile else {
            throw AudioFileWriterError.notStarted
        }
        do {
            if let accepted = acceptedInputFormat, buffer.format != accepted {
                try adoptInputFormat(buffer.format)
            }
            try audioFile.write(from: try convertIfNeeded(buffer))
            consecutiveWriteFailures = 0
        } catch {
            consecutiveWriteFailures += 1
            totalWriteFailures += 1
            lastWriteError = error.localizedDescription
            throw error
        }
    }

    /// The capture switched microphones under us — Teams moved from the
    /// built-in mic to the Yeti, or the Yeti was unplugged — and buffers now
    /// arrive in a different format. AVAudioFile refuses a buffer that does
    /// not match the file, so from here on they are converted into the format
    /// the chunk was opened with. One file, one format, no gap.
    private func adoptInputFormat(_ format: AVAudioFormat) throws {
        guard let target = startedFormat else { throw AudioFileWriterError.notStarted }
        if format == target {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: format, to: target) else {
                throw AudioFileWriterError.encoderPreflightFailed(
                    "no converter from \(Self.describe(format)) to \(Self.describe(target))"
                )
            }
            made.channelMap = Self.channelMap(from: format.channelCount, to: target.channelCount)
            converter = made
        }
        LogManager.send(
            "Audio now arriving as \(Self.describe(format)) (was \(Self.describe(acceptedInputFormat ?? format))) — writing on as \(Self.describe(target))",
            category: .audio
        )
        acceptedInputFormat = format
    }

    /// Output channel → input channel. A mono microphone replacing a stereo
    /// one fills both file channels rather than leaving the right side
    /// silent; extra input channels beyond the file's are dropped.
    nonisolated static func channelMap(from input: AVAudioChannelCount, to output: AVAudioChannelCount) -> [NSNumber] {
        (0..<Int(output)).map { NSNumber(value: min($0, Int(input) - 1)) }
    }

    /// Resample into the format the encoder accepted, when the device's own
    /// format was refused or has changed since the file was opened.
    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter, let target = startedFormat else { return buffer }

        let ratio = target.sampleRate / buffer.format.sampleRate
        // Round up and add a frame: a short output buffer silently truncates
        // audio, and the slack costs nothing.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        // Kept between calls. Buffers arrive continuously for the length of
        // the recording, and allocating one per buffer on the audio path is
        // avoidable churn; it only grows when a larger input turns up.
        if conversionBuffer == nil || conversionBuffer!.frameCapacity < capacity {
            conversionBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        }
        guard let output = conversionBuffer else {
            throw AudioFileWriterError.encoderPreflightFailed("conversion buffer alloc failed")
        }
        output.frameLength = 0

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            // One buffer in, then tell the converter the input is exhausted;
            // returning the same buffer twice duplicates audio.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return output
    }

    /// A format the AAC encoder is known to accept: mono, a standard rate,
    /// non-interleaved float.
    nonisolated static func fallbackFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        // Keep the device rate when it's one AAC actually supports, so speech
        // isn't resampled for no reason; otherwise take the nearest standard.
        //
        // Starts at 16 kHz rather than 8: the encoder refuses AAC-LC below
        // that at these bitrates, and a fallback the encoder also rejects is
        // no fallback at all. 16 kHz is also what transcription resamples to,
        // so nothing downstream loses anything.
        let supported: [Double] = [16000, 22050, 24000, 32000, 44100, 48000]
        let rate = supported.contains(inputFormat.sampleRate)
            ? inputFormat.sampleRate
            : supported.min(by: { abs($0 - inputFormat.sampleRate) < abs($1 - inputFormat.sampleRate) }) ?? 48000
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ) ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    }

    nonisolated static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz, \(format.channelCount)ch, \(format.isInterleaved ? "interleaved" : "planar")"
    }

    /// Close the current chunk (finalizing AAC metadata so it's playable) and
    /// open the next chunk. Called periodically from the main recording loop
    /// to bound audio loss on crash. If opening the new chunk fails, the
    /// current chunk is kept open so writes continue — better to have one
    /// big chunk than to lose audio entirely until the next successful
    /// checkpoint attempt.
    func checkpoint() throws {
        guard let startedFormat else {
            // Nothing has been written yet — nothing to checkpoint.
            return
        }
        let nextIndex = chunkIndex + 1
        let nextURL = Self.chunkURL(base: baseURL, index: nextIndex)
        let newFile = try AVAudioFile(
            forWriting: nextURL,
            settings: Self.encoderSettings(for: startedFormat),
            commonFormat: startedFormat.commonFormat,
            interleaved: startedFormat.isInterleaved
        )
        // Swap only after successful open — the previous file finalizes on
        // dealloc once its last reference drops.
        audioFile = newFile
        chunkIndex = nextIndex
        chunkURLsInternal.append(nextURL)
    }

    func stop() {
        audioFile = nil
    }

    var isWriting: Bool {
        audioFile != nil
    }

    /// All chunk URLs written so far, in order. Useful for recovery / export.
    var chunkURLs: [URL] {
        chunkURLsInternal
    }

    // MARK: - Private

    private func openChunk(inputFormat: AVAudioFormat) throws {
        let url = Self.chunkURL(base: baseURL, index: chunkIndex)
        // Creating the folder belongs here, at the moment of writing. Deriving
        // it from the audio URL instead meant every read that merely asked
        // "is there audio for this meeting" created an empty directory.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: Self.encoderSettings(for: inputFormat),
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        chunkURLsInternal.append(url)
    }

    /// Speech-tier AAC. AAC-LC has floors both per-channel and per-sample-
    /// rate — the encoder silently rejects settings below them. For sample
    /// rates AAC encodes natively (≤48 kHz), we keep the input rate. For
    /// rates above that (some Bluetooth/pro audio kit runs at 96 kHz), we
    /// clamp to 48 kHz because AVAudioFile's AAC path rejects 88/96 kHz in
    /// practice — a resample is far better than refusing to record.
    /// Bitrate scales with channels × rate factor so we stay above the
    /// encoder floor for 1–2 channels at 16–48 kHz.
    nonisolated static func encoderSettings(for inputFormat: AVAudioFormat) -> [String: Any] {
        let channels = max(Int(inputFormat.channelCount), 1)
        let outputRate = min(inputFormat.sampleRate, 48000)
        let rateMultiplier = max(2, Int(ceil(outputRate / 24000.0)))
        let bitrate = 16000 * channels * rateMultiplier
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputRate,
            AVNumberOfChannelsKey: min(channels, 2),
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: bitrate,
        ]
    }

    /// Derive the URL for a given chunk index from the base URL.
    /// Chunk 0 uses the base URL as-is; chunks >0 insert `.partNNN` before the extension.
    static func chunkURL(base: URL, index: Int) -> URL {
        guard index > 0 else { return base }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let parent = base.deletingLastPathComponent()
        let chunkName = String(format: "%@.part%03d", stem, index)
        return parent
            .appendingPathComponent(chunkName)
            .appendingPathExtension(ext)
    }

    /// Enumerate all existing chunks for the given base URL, sorted by index.
    /// Used by resume to validate or play back prior sessions' audio.
    nonisolated static func existingChunkURLs(base: URL) -> [URL] {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: base.path) {
            urls.append(base)
        }
        // Walk siblings named `<stem>.partNNN.<ext>`. Stop at the first gap so
        // we don't include unrelated `.part999.m4a` files that might be lying
        // around from testing.
        var i = 1
        while true {
            let url = chunkURL(base: base, index: i)
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            urls.append(url)
            i += 1
        }
        return urls
    }

    /// Returns the chunk index that new audio should be written to, given any
    /// existing chunks on disk for this base URL. If nothing exists, returns 0.
    /// If there are N existing chunks (indices 0..<N), returns N — so we write
    /// to a fresh file and never truncate prior session audio on resume.
    nonisolated static func nextChunkIndex(base: URL) -> Int {
        let existing = existingChunkURLs(base: base)
        return existing.count
    }
}

enum AudioFileWriterError: Error, LocalizedError {
    case notStarted
    case encoderPreflightFailed(String)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "Audio file writer not started. Call start() first."
        case .encoderPreflightFailed(let reason):
            return "Audio encoder preflight failed: \(reason)"
        }
    }
}
