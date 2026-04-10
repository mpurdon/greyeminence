import Foundation
import SwiftData

/// Rolling backup of the SwiftData store file. Runs once on app launch and
/// copies the `.store` file (plus `-wal` and `-shm` sidecars) to
/// `AppSupport/GreyEminence/backups/YYYY-MM-DD.store`. Prunes backups older
/// than `retentionDays` so the backup directory doesn't grow unbounded.
///
/// This is not a substitute for SwiftData schema migrations — it's insurance
/// against a corrupted store. If a schema change bricks the store on a user's
/// machine, they can fall back to yesterday's backup with no work on our part.
///
/// Safety notes:
///  - SQLite WAL mode (which SwiftData uses by default) allows concurrent
///    reads while the container has the store open, so copying the live store
///    is safe. We copy the `-wal` and `-shm` sidecars too so the backup can
///    replay any pending transactions.
///  - Idempotent: if today's backup already exists, we skip. Determined purely
///    by filename, so the user can delete a bad backup to force re-creation.
enum StoreBackupService {
    /// How many days of daily backups to keep.
    static let retentionDays: Int = 7

    /// Backup directory: `AppSupport/GreyEminence/backups/`.
    static var backupDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("GreyEminence", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
    }

    /// Create today's backup if it doesn't already exist, then prune old ones.
    /// Call once on app launch, after the `ModelContainer` is created.
    static func runIfNeeded(for container: ModelContainer) {
        guard let storeURL = container.configurations.first?.url else {
            LogManager.send("Store backup skipped: no configuration URL", category: .general, level: .warning)
            return
        }
        runIfNeeded(storeURL: storeURL)
    }

    /// Lower-level entry point — takes a raw store URL. Used by the container
    /// variant above and exposed for testing.
    static func runIfNeeded(storeURL: URL) {
        let backupDir = backupDirectory
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            LogManager.send("Store backup dir creation failed: \(error.localizedDescription)", category: .general, level: .error)
            return
        }

        let dateString = todayString()
        let destination = backupDir.appendingPathComponent("\(dateString).store")

        if FileManager.default.fileExists(atPath: destination.path) {
            // Already backed up today. Still run pruning in case the
            // retention setting shrank.
            prune(in: backupDir)
            return
        }

        // Copy the main store file + its sidecars. All three are needed for
        // a consistent restore — the -wal file holds uncommitted pages.
        do {
            try copyIfExists(from: storeURL, to: destination)
            try copyIfExists(
                from: storeURL.appendingPathExtension("wal"),
                to: destination.appendingPathExtension("wal")
            )
            try copyIfExists(
                from: storeURL.appendingPathExtension("shm"),
                to: destination.appendingPathExtension("shm")
            )
            LogManager.send("Store backup created: \(destination.lastPathComponent)", category: .general)
        } catch {
            LogManager.send("Store backup failed: \(error.localizedDescription)", category: .general, level: .error)
            // If the partial backup left a damaged file behind, try to clean
            // it up so we retry cleanly next launch.
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("wal"))
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("shm"))
        }

        prune(in: backupDir)
    }

    // MARK: - Private

    private static func copyIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        // In case of a stale sibling from a partial prior run, remove first.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Delete backup files whose stem date is older than `retentionDays`.
    /// Non-matching files are left alone so the user can drop extra artifacts
    /// in the backup directory without us touching them.
    private static func prune(in directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: .now) ?? .now
        let formatter = Self.dateFormatter

        var removed = 0
        for url in contents {
            // Recognize names like "2026-04-09.store", "2026-04-09.store-wal", "2026-04-09.store-shm".
            let name = url.lastPathComponent
            guard let dateStem = name.split(separator: ".").first.map(String.init),
                  let fileDate = formatter.date(from: dateStem) else {
                continue
            }
            if fileDate < cutoff {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch {
                    LogManager.send("Store backup prune failed for \(name): \(error.localizedDescription)", category: .general, level: .warning)
                }
            }
        }
        if removed > 0 {
            LogManager.send("Store backup pruned \(removed) old file(s)", category: .general)
        }
    }

    private static func todayString() -> String {
        dateFormatter.string(from: .now)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
