import AVFoundation

actor AudioFileWriter {
    private var audioFile: AVAudioFile?
    private let outputURL: URL
    private let fileFormat: AVAudioFormat

    init(outputURL: URL, format: AVAudioFormat? = nil) {
        self.outputURL = outputURL
        // Default: AAC in .m4a container
        self.fileFormat = format ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        )!
    }

    func start(inputFormat: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000,
        ]

        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let audioFile else {
            throw AudioFileWriterError.notStarted
        }
        try audioFile.write(from: buffer)
    }

    func stop() {
        audioFile = nil
    }

    var isWriting: Bool {
        audioFile != nil
    }
}

enum AudioFileWriterError: Error, LocalizedError {
    case notStarted

    var errorDescription: String? {
        "Audio file writer not started. Call start() first."
    }
}
