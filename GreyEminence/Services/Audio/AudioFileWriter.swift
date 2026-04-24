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
        try Self.preflightEncoder(for: inputFormat)
        startedFormat = inputFormat
        // If we're resuming an interrupted recording, the base URL and/or
        // its part siblings may already exist on disk from the prior session.
        // Writing into the base URL via AVAudioFile(forWriting:) would truncate
        // those files and lose audio — so before opening anything, scan for
        // existing chunks and bump `chunkIndex` past the highest one found.
        chunkIndex = Self.nextChunkIndex(base: baseURL)
        // Previously-existing chunks are preserved but not tracked as ours;
        // callers can enumerate them with `Self.existingChunkURLs(base:)`.
        try openChunk(inputFormat: inputFormat)
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
            try audioFile.write(from: buffer)
            consecutiveWriteFailures = 0
        } catch {
            consecutiveWriteFailures += 1
            totalWriteFailures += 1
            lastWriteError = error.localizedDescription
            throw error
        }
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
            AVNumberOfChannelsKey: inputFormat.channelCount,
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
