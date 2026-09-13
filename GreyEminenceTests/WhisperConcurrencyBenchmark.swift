@preconcurrency import WhisperKit
import XCTest
@testable import Grey_Eminence

/// Does transcribing the mic and system tracks on two WhisperKit instances
/// at once beat one instance doing them in turn? The Neural Engine is a
/// shared resource and tends to serialise, so this is measured, not assumed.
///
/// Skipped unless `GE_WHISPER_BENCH` names a recording directory — it loads
/// two 1.5 GB models and runs real inference for a minute or two.
final class WhisperConcurrencyBenchmark: XCTestCase {

    /// Static, so `async let` can send it: a local closure captures the
    /// test instance and fails region-based isolation checking.
    nonisolated static func run(_ kit: WhisperKit, _ chunks: [[Float]]) async throws -> Int {
        var words = 0
        for samples in chunks {
            let results = try await kit.transcribe(audioArray: samples)
            words += results.flatMap(\.segments).reduce(0) { $0 + $1.text.split(separator: " ").count }
        }
        return words
    }

    func testSequentialVersusConcurrent() async throws {
        guard let dir = ProcessInfo.processInfo.environment["GE_WHISPER_BENCH"] else {
            throw XCTSkip("set GE_WHISPER_BENCH=<recording dir> to run")
        }
        let base = URL(fileURLWithPath: dir)
        let count = Int(ProcessInfo.processInfo.environment["GE_WHISPER_BENCH_CHUNKS"] ?? "12") ?? 12
        let micChunks = Array(AudioFileWriter.existingChunkURLs(base: base.appendingPathComponent("mic.m4a")).prefix(count))
        let sysChunks = Array(AudioFileWriter.existingChunkURLs(base: base.appendingPathComponent("system.m4a")).prefix(count))
        XCTAssertEqual(micChunks.count, count); XCTAssertEqual(sysChunks.count, count)

        let mic = try micChunks.map { try HighQualityTranscriber.decodeTo16kFloatMono(url: $0) }
        let sys = try sysChunks.map { try HighQualityTranscriber.decodeTo16kFloatMono(url: $0) }
        let audioSeconds = (mic + sys).reduce(0) { $0 + Double($1.count) / 16000 }

        // The test host is not the sandboxed app, so its default model
        // folder is empty; use the app's downloaded copy rather than
        // fetching 1.5 GB twice.
        let appModels = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.greyeminence.app/Data/Documents/huggingface")
        let modelFolder = appModels.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(HighQualityTranscriber.modelName)")
        let config = WhisperKitConfig(model: HighQualityTranscriber.modelName, modelFolder: modelFolder.path, verbose: false)
        let a = try await WhisperKit(config)
        let b = try await WhisperKit(config)
        // Warm both so model load and first-inference compilation are not measured.
        _ = try await a.transcribe(audioArray: mic[0])
        _ = try await b.transcribe(audioArray: sys[0])

        let t0 = Date()
        let seqWords = try await Self.run(a, mic) + Self.run(a, sys)
        let sequential = Date().timeIntervalSince(t0)

        let t1 = Date()
        async let micWords = Self.run(a, mic)
        async let sysWords = Self.run(b, sys)
        let concWords = try await micWords + sysWords
        let concurrent = Date().timeIntervalSince(t1)

        let line = String(
            format: "WHISPER BENCH: %.0fs of audio | sequential %.1fs (%.1fx) | concurrent %.1fs (%.1fx) | speedup %.2fx | words %d vs %d",
            audioSeconds, sequential, audioSeconds / sequential, concurrent, audioSeconds / concurrent, sequential / concurrent, seqWords, concWords
        )
        print(line)
        try? line.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whisper-bench.txt"), atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(concWords, 0)
    }
}
