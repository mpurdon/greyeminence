import XCTest
@preconcurrency import AVFoundation
@testable import Grey_Eminence

/// Real-AVAudioFile tests for the encoder settings matrix. These are the
/// regression guard for the v0.9.45 incident, where 32 kbps stereo at 48 kHz
/// was below AAC-LC's per-channel floor and every chunk produced by the
/// encoder was corrupt. Any combination tested here must: (a) preflight
/// without throwing, (b) produce a file that AVAudioFile can re-open for
/// reading.
final class AudioFileWriterEncoderTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFileWriterEncoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func makeFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )
        return try XCTUnwrap(format, "Could not build PCM float32 format at \(sampleRate)Hz × \(channels)ch")
    }

    // MARK: - Preflight

    func test_preflight_mono_44100_passes() throws {
        let fmt = try makeFormat(sampleRate: 44100, channels: 1)
        XCTAssertNoThrow(try AudioFileWriter.preflightEncoder(for: fmt))
    }

    func test_preflight_mono_48000_passes() throws {
        let fmt = try makeFormat(sampleRate: 48000, channels: 1)
        XCTAssertNoThrow(try AudioFileWriter.preflightEncoder(for: fmt))
    }

    func test_preflight_stereo_44100_passes() throws {
        let fmt = try makeFormat(sampleRate: 44100, channels: 2)
        XCTAssertNoThrow(try AudioFileWriter.preflightEncoder(for: fmt))
    }

    func test_preflight_stereo_48000_passes() throws {
        // This is the exact case that broke in v0.9.45–0.9.47.
        let fmt = try makeFormat(sampleRate: 48000, channels: 2)
        XCTAssertNoThrow(try AudioFileWriter.preflightEncoder(for: fmt))
    }

    func test_preflight_stereo_96000_passes() throws {
        let fmt = try makeFormat(sampleRate: 96000, channels: 2)
        XCTAssertNoThrow(try AudioFileWriter.preflightEncoder(for: fmt))
    }

    // MARK: - End-to-end: write, checkpoint, verify readable

    func test_write_and_reopen_stereo_48000() async throws {
        let base = tempDir.appendingPathComponent("sys.m4a")
        let writer = AudioFileWriter(outputURL: base)
        let fmt = try makeFormat(sampleRate: 48000, channels: 2)

        try await writer.start(inputFormat: fmt)

        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16000),
            "Could not allocate probe buffer"
        )
        buffer.frameLength = 16000
        try await writer.write(buffer)

        try await writer.checkpoint()
        try await writer.write(buffer)
        await writer.stop()

        let chunks = AudioFileWriter.existingChunkURLs(base: base)
        XCTAssertEqual(chunks.count, 2, "Expected two chunks after one checkpoint")
        for chunk in chunks {
            let readable = try AVAudioFile(forReading: chunk)
            XCTAssertGreaterThan(readable.length, 0, "Chunk \(chunk.lastPathComponent) has zero length — encoder rejected the settings")
        }
    }

    func test_write_and_reopen_mono_44100() async throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        let writer = AudioFileWriter(outputURL: base)
        let fmt = try makeFormat(sampleRate: 44100, channels: 1)

        try await writer.start(inputFormat: fmt)

        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8000),
            "Could not allocate probe buffer"
        )
        buffer.frameLength = 8000
        try await writer.write(buffer)
        await writer.stop()

        let chunks = AudioFileWriter.existingChunkURLs(base: base)
        XCTAssertEqual(chunks.count, 1)
        let readable = try AVAudioFile(forReading: try XCTUnwrap(chunks.first))
        XCTAssertGreaterThan(readable.length, 0)
    }

    // MARK: - Format change mid-recording

    /// The capture moved to another microphone (Teams from the built-in mic
    /// to the Yeti) and buffers now arrive stereo into a file opened mono.
    /// They are converted, not refused — a refused buffer is lost audio.
    func test_bufferInANewFormat_isConvertedIntoTheOpenFile() async throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        let writer = AudioFileWriter(outputURL: base)
        let mono = try makeFormat(sampleRate: 48000, channels: 1)
        try await writer.start(inputFormat: mono)

        let first = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4800))
        first.frameLength = 4800
        try await writer.write(first)

        let stereo = try makeFormat(sampleRate: 48000, channels: 2)
        let second = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4800))
        second.frameLength = 4800
        try await writer.write(second)

        // And back again, as when the Yeti is unplugged.
        try await writer.write(first)
        await writer.stop()

        let failures = await writer.totalWriteFailures
        XCTAssertEqual(failures, 0)
        let readable = try AVAudioFile(forReading: base)
        XCTAssertEqual(readable.fileFormat.channelCount, 1, "the file keeps the format it was opened with")
        XCTAssertGreaterThan(readable.length, 12000, "all three buffers landed — two alone would be 9600 frames; AAC trims the tail packet")
    }

    func test_aSampleRateChange_isResampledIntoTheOpenFile() async throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        let writer = AudioFileWriter(outputURL: base)
        let fmt48 = try makeFormat(sampleRate: 48000, channels: 1)
        try await writer.start(inputFormat: fmt48)

        let fmt44 = try makeFormat(sampleRate: 44100, channels: 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt44, frameCapacity: 4410))
        buffer.frameLength = 4410
        try await writer.write(buffer)
        await writer.stop()

        let readable = try AVAudioFile(forReading: base)
        XCTAssertEqual(readable.fileFormat.sampleRate, 48000)
        XCTAssertGreaterThan(readable.length, 0)
    }

    func test_channelMap_duplicatesMonoIntoStereo_andDropsExtraChannels() {
        XCTAssertEqual(AudioFileWriter.channelMap(from: 1, to: 2), [0, 0])
        XCTAssertEqual(AudioFileWriter.channelMap(from: 2, to: 1), [0])
        XCTAssertEqual(AudioFileWriter.channelMap(from: 2, to: 2), [0, 1])
    }
}
