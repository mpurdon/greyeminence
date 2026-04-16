import Foundation
@preconcurrency import Sparkle

/// Comprehensive logging shim around Sparkle. Every interesting lifecycle
/// callback is forwarded to LogManager under the `.update` category so a stuck
/// or failed auto-update leaves a useful trail in the Activity Log AND in
/// `~/Library/Application Support/GreyEminence/system.log` (which the user
/// can paste back to us).
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {

    // MARK: - Helpers

    nonisolated private static func log(_ message: String, level: LogEntry.Level = .info, detail: String? = nil) {
        LogManager.send(message, category: .update, level: level, detail: detail)
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts: [String] = []
        parts.append("domain=\(ns.domain)")
        parts.append("code=\(ns.code)")
        parts.append("desc=\(ns.localizedDescription)")
        if let reason = ns.localizedFailureReason {
            parts.append("reason=\(reason)")
        }
        if let suggestion = ns.localizedRecoverySuggestion {
            parts.append("recovery=\(suggestion)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=[domain=\(underlying.domain) code=\(underlying.code) desc=\(underlying.localizedDescription)]")
        }
        if !ns.userInfo.isEmpty {
            let keys = ns.userInfo.keys.sorted()
            parts.append("userInfoKeys=\(keys.joined(separator: ","))")
        }
        return parts.joined(separator: " | ")
    }

    nonisolated private static func describe(_ item: SUAppcastItem) -> String {
        var parts: [String] = []
        parts.append("version=\(item.versionString)")
        parts.append("display=\(item.displayVersionString)")
        if let url = item.fileURL {
            parts.append("url=\(url.absoluteString)")
        }
        parts.append("contentLength=\(item.contentLength)")
        if let minSys = item.minimumSystemVersion {
            parts.append("minSys=\(minSys)")
        }
        if item.isCriticalUpdate {
            parts.append("critical=true")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.log("Feed URL requested by updater")
        return nil  // let Sparkle use the Info.plist value
    }

    nonisolated func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool {
        Self.log("updaterMayCheckForUpdates -> true")
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Self.log("Scheduled next update check in \(Int(delay))s")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let count = appcast.items.count
        let latest = appcast.items.first.map { Self.describe($0) } ?? "<none>"
        Self.log("Appcast loaded (items=\(count))", detail: "latest: \(latest)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.log("Found valid update", detail: Self.describe(item))
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Self.log("No update available")
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Self.log("Download finished", detail: Self.describe(item))
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        Self.log("Will extract update", detail: Self.describe(item))
    }

    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        Self.log("Extracted update", detail: Self.describe(item))
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.log("Will install update", detail: Self.describe(item))
    }

    nonisolated func updater(_ updater: SPUUpdater, didStartInstallingUpdate item: SUAppcastItem) {
        Self.log("Started installing update", detail: Self.describe(item))
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Self.log("Updater aborted", level: .error, detail: Self.describe(error))
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.log("Failed to download update", level: .error, detail: "\(Self.describe(item)) || \(Self.describe(error))")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            Self.log("Update cycle finished with error (check=\(updateCheck.rawValue))", level: .error, detail: Self.describe(error))
        } else {
            Self.log("Update cycle finished cleanly (check=\(updateCheck.rawValue))")
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInState state: SPUUserUpdateState) -> Bool {
        Self.log("UserDriver: showing scheduled update", detail: "\(Self.describe(update)) | userInitiated=\(state.userInitiated)")
        return true
    }

    func standardUserDriverWillShowModalAlert() {
        Self.log("UserDriver: will show modal alert")
    }

    func standardUserDriverDidShowModalAlert() {
        Self.log("UserDriver: did show modal alert")
    }
}
