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
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000,
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
}

enum AudioFileWriterError: Error, LocalizedError {
    case notStarted

    var errorDescription: String? {
        "Audio file writer not started. Call start() first."
    }
}
