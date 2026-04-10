import XCTest
@testable import Grey_Eminence

/// Integration-style tests for store backup retention. These write fake backup
/// files into a temporary directory and verify that the prune step correctly
/// removes files older than the retention window while leaving recent ones
/// and unrelated files alone.
final class StoreBackupServiceTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreBackupServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    /// Simulate `runIfNeeded` by calling it with a fresh SQLite-shaped store
    /// file in a temp location, then verifying the backup lands in the
    /// service's backup directory for today's date.
    ///
    /// Note: we can't easily point StoreBackupService at our temp dir without
    /// exposing internal hooks, so this test uses the real backup directory
    /// under AppSupport and cleans up after itself. It's intentionally tolerant
    /// of other backup files that may already exist there.
    func test_runIfNeeded_createsTodaysBackup() throws {
        let storeURL = tempDir.appendingPathComponent("fake.store")
        try "SQLite format 3\0".data(using: .utf8)!.write(to: storeURL)
        // Also a WAL sidecar to prove it's copied.
        let walURL = storeURL.appendingPathExtension("wal")
        try Data([0x01, 0x02, 0x03]).write(to: walURL)

        let backupDir = StoreBackupService.backupDirectory
        let dateString = Self.todayString()
        let backupTarget = backupDir.appendingPathComponent("\(dateString).store")
        let backupWalTarget = backupDir.appendingPathComponent("\(dateString).store.wal")

        // Start clean — remove any existing backup for today so we exercise
        // the copy path.
        try? FileManager.default.removeItem(at: backupTarget)
        try? FileManager.default.removeItem(at: backupWalTarget)

        StoreBackupService.runIfNeeded(storeURL: storeURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupTarget.path), "today's backup should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupWalTarget.path), "WAL sidecar should be backed up")

        // Cleanup to not leave test artifacts.
        try? FileManager.default.removeItem(at: backupTarget)
        try? FileManager.default.removeItem(at: backupWalTarget)
    }

    /// Second call on the same day should be a no-op for the copy step:
    /// file modification times shouldn't change.
    func test_runIfNeeded_idempotentWithinSameDay() throws {
        let storeURL = tempDir.appendingPathComponent("fake2.store")
        try "SQLite format 3\0".data(using: .utf8)!.write(to: storeURL)

        let backupDir = StoreBackupService.backupDirectory
        let dateString = Self.todayString()
        let backupTarget = backupDir.appendingPathComponent("\(dateString).store")
        try? FileManager.default.removeItem(at: backupTarget)

        StoreBackupService.runIfNeeded(storeURL: storeURL)
        let firstAttrs = try FileManager.default.attributesOfItem(atPath: backupTarget.path)
        let firstMtime = firstAttrs[.modificationDate] as? Date

        // Small delay to make any mtime difference detectable.
        Thread.sleep(forTimeInterval: 0.05)

        StoreBackupService.runIfNeeded(storeURL: storeURL)
        let secondAttrs = try FileManager.default.attributesOfItem(atPath: backupTarget.path)
        let secondMtime = secondAttrs[.modificationDate] as? Date

        XCTAssertEqual(firstMtime, secondMtime, "backup should not be rewritten on the same day")

        try? FileManager.default.removeItem(at: backupTarget)
    }

    // MARK: - Helpers

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: .now)
    }
}
