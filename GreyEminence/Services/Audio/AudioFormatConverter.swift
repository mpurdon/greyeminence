import AVFoundation

final class AudioFormatConverter: @unchecked Sendable {
    static nonisolated(unsafe) let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private let targetFormat: AVAudioFormat

    init(targetFormat: AVAudioFormat? = nil) {
        self.targetFormat = targetFormat ?? Self.whisperFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let sourceFormat = buffer.format

        // Already in target format
        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount
            && sourceFormat.commonFormat == targetFormat.commonFormat {
            return buffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioConversionError.converterCreationFailed
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw AudioConversionError.bufferCreationFailed
        }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            throw AudioConversionError.conversionFailed(error.localizedDescription)
        }

        return outputBuffer
    }

    /// Extract Float32 samples from a buffer, converting if needed.
    func floatSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let converted = try convert(buffer)
        guard let channelData = converted.floatChannelData else {
            throw AudioConversionError.noChannelData
        }
        let frameCount = Int(converted.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }
}

enum AudioConversionError: Error, LocalizedError {
    case converterCreationFailed
    case bufferCreationFailed
    case conversionFailed(String)
    case noChannelData

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed: "Failed to create audio converter"
        case .bufferCreationFailed: "Failed to create output buffer"
        case .conversionFailed(let msg): "Audio conversion failed: \(msg)"
        case .noChannelData: "No channel data in buffer"
        }
    }
}
