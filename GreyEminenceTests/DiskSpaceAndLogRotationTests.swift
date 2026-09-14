import XCTest
@testable import Grey_Eminence

/// The disk-pressure warning and system.log rotation. Both are pure
/// file-system or threshold logic; nothing here touches the live store.
final class DiskSpaceAndLogRotationTests: XCTestCase {

    // MARK: - Disk space

    func testNoWarningWithPlentyOfSpaceOrWhenUnknown() {
        XCTAssertNil(DiskSpace.warning(freeBytes: 47_000_000_000))
        XCTAssertNil(DiskSpace.warning(freeBytes: DiskSpace.lowWatermark))
        XCTAssertNil(DiskSpace.warning(freeBytes: nil), "can't tell — don't nag")
    }

    /// 4.6 GB free is where macOS purged the Neural Engine cache on
    /// 2026-09-14; the old 500 MB threshold never said a word.
    func testWarnsBelowTenGigabytes() throws {
        let warning = try XCTUnwrap(DiskSpace.warning(freeBytes: 4_600_000_000))
        XCTAssertTrue(warning.contains("4.6 GB free"), warning)
        XCTAssertTrue(warning.contains("Neural Engine"), "says why it matters, not just that it is low")
    }

    func testDescribeUsesGigabytesThenMegabytes() {
        XCTAssertEqual(DiskSpace.describe(47_300_000_000), "47.3 GB")
        XCTAssertEqual(DiskSpace.describe(512_000_000), "512 MB")
    }

    // MARK: - Log rotation

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    func testRotatedURLKeepsStemAndExtension() {
        let url = URL(fileURLWithPath: "/x/system.log")
        XCTAssertEqual(LogManager.rotatedURL(url, generation: 2).lastPathComponent, "system.2.log")
    }

    func testSmallLogIsLeftAlone() throws {
        let log = tempDir.appendingPathComponent("system.log")
        try write("short", to: log)
        XCTAssertFalse(LogManager.rotateIfNeeded(log, maxBytes: 100, generations: 3))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "short")
    }

    func testMissingLogIsNotAnError() {
        XCTAssertFalse(LogManager.rotateIfNeeded(tempDir.appendingPathComponent("nope.log"), maxBytes: 1))
    }

    func testOversizedLogShiftsDownAndTheOldestGenerationIsDropped() throws {
        let log = tempDir.appendingPathComponent("system.log")
        let g1 = LogManager.rotatedURL(log, generation: 1)
        let g2 = LogManager.rotatedURL(log, generation: 2)
        try write("gen1", to: g1)
        try write("gen2-oldest", to: g2)
        try write(String(repeating: "x", count: 200), to: log)

        XCTAssertTrue(LogManager.rotateIfNeeded(log, maxBytes: 100, generations: 2))

        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the live file moved; the next line recreates it")
        XCTAssertEqual(try String(contentsOf: g1, encoding: .utf8).count, 200, "live log became generation 1")
        XCTAssertEqual(try String(contentsOf: g2, encoding: .utf8), "gen1", "generation 1 became 2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: LogManager.rotatedURL(log, generation: 3).path), "nothing beyond the last generation")
    }
}
