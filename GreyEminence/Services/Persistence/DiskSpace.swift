import Foundation

/// Free space on the volume the app's data lives on, and what to say about it.
///
/// The app's Caches — including the 2.5 GB Neural Engine specialisation of
/// Whisper large-v3 — are purgeable, and macOS purges them well before the
/// disk is actually full. On 2026-09-14, at 4.6 GB free of 926 GB, the cache
/// was wiped and every re-transcription spent 12 minutes recompiling the
/// model before its first chunk, looking frozen. The old 500 MB / 1 GB
/// checks were tuned to "a write is about to fail", far too late for that.
enum DiskSpace {
    /// Below this, warn: caches are at risk and a long recording is not
    /// guaranteed to fit.
    static let lowWatermark: Int64 = 10_000_000_000
    /// Below this, re-processing does not start at all.
    static let criticalWatermark: Int64 = 1_000_000_000

    nonisolated static func freeBytes() -> Int64? {
        let values = try? StorageManager.shared.recordingsURL
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The warning for the current free space, or nil when there is enough.
    nonisolated static func currentWarning() -> String? {
        warning(freeBytes: freeBytes())
    }

    /// The user-facing warning for `freeBytes`, or nil when there is nothing
    /// to say. Pure so the threshold and wording are tested.
    static func warning(freeBytes: Int64?) -> String? {
        guard let freeBytes, freeBytes < lowWatermark else { return nil }
        return "Low disk space — \(describe(freeBytes)) free. macOS purges the app's caches under pressure, which makes the next re-transcription recompile Whisper for the Neural Engine (10+ minutes), and a long recording may not fit. Free up space."
    }

    static func describe(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
