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

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let audioFile else {
            throw AudioFileWriterError.notStarted
        }
        try audioFile.write(from: buffer)
    }

    /// Close the current chunk (finalizing AAC metadata so it's playable) and
    /// open the next chunk. Called periodically from the main recording loop to
    /// bound audio loss on crash.
    func checkpoint() throws {
        guard let startedFormat else {
            // Nothing has been written yet — nothing to checkpoint.
            return
        }
        // Close current chunk: nil'ing the reference finalizes the AAC container.
        audioFile = nil
        chunkIndex += 1
        try openChunk(inputFormat: startedFormat)
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
        // Speech-tier AAC at the input's native rate/channels. Writing at a
        // different rate (e.g. 16 kHz) from the PCM input (48 kHz) causes
        // AVAudioFile to produce unreadable chunks for some input formats —
        // decode fails at re-transcription time. Matching the input keeps
        // the encode stable; the bitrate drop (128 → 32 kbps) alone gives
        // ~4x disk savings for speech content without risking write corruption.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000,
        ]

        audioFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
        chunkURLsInternal.append(url)
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

    var errorDescription: String? {
        "Audio file writer not started. Call start() first."
    }
}
