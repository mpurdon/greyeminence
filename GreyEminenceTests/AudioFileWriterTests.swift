import XCTest
@testable import Grey_Eminence

/// Tests for the pure and file-system parts of `AudioFileWriter`.
/// Covers chunk URL derivation and resume-from-next-index logic without
/// exercising real AVAudioFile writes.
final class AudioFileWriterTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - chunkURL

    func test_chunkURL_zeroIndex_returnsBaseURLUnchanged() {
        let base = URL(fileURLWithPath: "/tmp/mic.m4a")
        XCTAssertEqual(AudioFileWriter.chunkURL(base: base, index: 0), base)
    }

    func test_chunkURL_positiveIndex_insertsPartBeforeExtension() {
        let base = URL(fileURLWithPath: "/tmp/mic.m4a")
        XCTAssertEqual(
            AudioFileWriter.chunkURL(base: base, index: 1).lastPathComponent,
            "mic.part001.m4a"
        )
        XCTAssertEqual(
            AudioFileWriter.chunkURL(base: base, index: 42).lastPathComponent,
            "mic.part042.m4a"
        )
    }

    func test_chunkURL_threeDigitPadding_holdsBeyondNinetyNine() {
        let base = URL(fileURLWithPath: "/tmp/audio.m4a")
        XCTAssertEqual(
            AudioFileWriter.chunkURL(base: base, index: 100).lastPathComponent,
            "audio.part100.m4a"
        )
    }

    func test_chunkURL_preservesParentDirectory() {
        let base = URL(fileURLWithPath: "/Users/test/Recordings/abc-123/mic.m4a")
        let chunk = AudioFileWriter.chunkURL(base: base, index: 2)
        XCTAssertEqual(chunk.deletingLastPathComponent().path, base.deletingLastPathComponent().path)
    }

    // MARK: - existingChunkURLs

    func test_existingChunkURLs_noFiles_returnsEmpty() {
        let base = tempDir.appendingPathComponent("mic.m4a")
        XCTAssertEqual(AudioFileWriter.existingChunkURLs(base: base), [])
    }

    func test_existingChunkURLs_onlyBase_returnsSingle() throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        try Data().write(to: base)
        let result = AudioFileWriter.existingChunkURLs(base: base)
        XCTAssertEqual(result, [base])
    }

    func test_existingChunkURLs_baseAndSeveralParts_returnsSortedByIndex() throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        let part1 = tempDir.appendingPathComponent("mic.part001.m4a")
        let part2 = tempDir.appendingPathComponent("mic.part002.m4a")
        let part3 = tempDir.appendingPathComponent("mic.part003.m4a")
        // Write in reverse order to confirm sort comes from index, not mtime.
        try Data().write(to: part3)
        try Data().write(to: part2)
        try Data().write(to: part1)
        try Data().write(to: base)

        let result = AudioFileWriter.existingChunkURLs(base: base)
        XCTAssertEqual(result, [base, part1, part2, part3])
    }

    func test_existingChunkURLs_stopsAtFirstGap() throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        let part1 = tempDir.appendingPathComponent("mic.part001.m4a")
        // Deliberately skip part002 — a gap from a cleanup shouldn't make us
        // enumerate unrelated high-index files (e.g. stale test data).
        let part3 = tempDir.appendingPathComponent("mic.part003.m4a")
        try Data().write(to: base)
        try Data().write(to: part1)
        try Data().write(to: part3)

        let result = AudioFileWriter.existingChunkURLs(base: base)
        XCTAssertEqual(result, [base, part1])
    }

    // MARK: - nextChunkIndex

    func test_nextChunkIndex_noFiles_returnsZero() {
        let base = tempDir.appendingPathComponent("mic.m4a")
        XCTAssertEqual(AudioFileWriter.nextChunkIndex(base: base), 0)
    }

    func test_nextChunkIndex_onlyBase_returnsOne() throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        try Data().write(to: base)
        XCTAssertEqual(AudioFileWriter.nextChunkIndex(base: base), 1)
    }

    func test_nextChunkIndex_baseAndTwoParts_returnsThree() throws {
        let base = tempDir.appendingPathComponent("mic.m4a")
        let part1 = tempDir.appendingPathComponent("mic.part001.m4a")
        let part2 = tempDir.appendingPathComponent("mic.part002.m4a")
        try Data().write(to: base)
        try Data().write(to: part1)
        try Data().write(to: part2)
        XCTAssertEqual(AudioFileWriter.nextChunkIndex(base: base), 3)
    }
}
