import Foundation
@preconcurrency import Sparkle

/// Comprehensive logging shim around Sparkle. Every interesting lifecycle
/// callback is forwarded to LogManager under the `.update` category so a stuck
/// or failed auto-update leaves a useful trail in the Activity Log AND in
/// `~/Library/Application Support/GreyEminence/system.log` (which the user
/// can paste back to us).
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {

    /// Set by the app once `RecordingViewModel` is wired up. Defaults to
    /// `false` so updates behave normally during the brief window between
    /// app init (when this delegate is constructed) and view-model bind.
    @MainActor var isRecordingActive: () -> Bool = { false }

    // MARK: - Helpers

    nonisolated private static func log(_ message: String, level: LogEntry.Level = .info, detail: String? = nil) {
        LogManager.send(message, category: .update, level: level, detail: detail)
    }

    /// Every gate event hops to the main actor: Sparkle calls back on any
    /// thread and the gate is main-actor state.
    nonisolated private static func gate(_ event: @escaping @MainActor (StartupUpdateGate) -> Void) {
        Task { @MainActor in
            event(StartupUpdateGate.shared)
        }
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
        #if DEBUG
        // A Debug build lives in DerivedData and is whatever the developer
        // last compiled. Letting Sparkle "update" it installs the published
        // release over the working copy and silently reverts uncommitted
        // work — observed 2026-08-06, where an overnight scheduled check
        // replaced a dev build mid-field-test and the app went on logging
        // as though the changes had never been made.
        Self.log("updaterMayCheckForUpdates -> false (Debug build)")
        Self.gate { $0.checkSkipped() }
        return false
        #else
        // No "Checking…" flash here: at launch the status bar already shows
        // the gate's own "Checking for updates…" spinner, and a flash would
        // replace it with a completed-looking line while the fetch is still
        // in flight.
        Self.log("updaterMayCheckForUpdates -> true")
        return true
        #endif
    }

    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Self.log("Scheduled next update check in \(Int(delay))s")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let count = appcast.items.count
        let latest = appcast.items.first.map { Self.describe($0) } ?? "<none>"
        Self.log("Appcast loaded (items=\(count)) — latest: \(latest)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.log("Found valid update — \(Self.describe(item))")
        Self.announce("Update available: \(item.displayVersionString)")
        Self.gate { $0.updateFound() }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Self.log("No update available")
        Self.announce("Up to date")
        Self.gate { $0.noUpdateFound() }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Self.log("Download finished — \(Self.describe(item))")
    }

    nonisolated func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        Self.log("Will extract update — \(Self.describe(item))")
    }

    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        Self.log("Extracted update — \(Self.describe(item))")
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.log("Will install update — \(Self.describe(item))")
    }

    nonisolated func updater(_ updater: SPUUpdater, didStartInstallingUpdate item: SUAppcastItem) {
        Self.log("Started installing update — \(Self.describe(item))")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Self.log("Updater aborted — \(Self.describe(error))", level: .error)
        Self.gate { $0.installFailed() }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .install:
            Self.log("User chose to install — \(Self.describe(updateItem))")
            Self.gate { $0.userChoseInstall() }
        case .skip:
            Self.log("User skipped update — \(Self.describe(updateItem))")
            Self.gate { $0.userDeclinedUpdate() }
        case .dismiss:
            Self.log("User dismissed update — \(Self.describe(updateItem))")
            Self.gate { $0.userDeclinedUpdate() }
        @unknown default:
            Self.log("User made an unknown update choice (\(choice.rawValue))", level: .warning)
            Self.gate { $0.userDeclinedUpdate() }
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.log("Failed to download update — \(Self.describe(item)) || \(Self.describe(error))", level: .error)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            Self.log("Update cycle finished with error (check=\(updateCheck.rawValue)) — \(Self.describe(error))", level: .error)
            Self.gate { $0.checkFailed() }
        } else {
            Self.log("Update cycle finished cleanly (check=\(updateCheck.rawValue))")
        }
    }

    // MARK: - SPUStandardUserDriverDelegate

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInState state: SPUUserUpdateState) -> Bool {
        if isRecordingActive() {
            Self.log("UserDriver: deferring scheduled update — recording in progress | \(Self.describe(update))")
            Self.gate { $0.updateDeferred() }
            return false
        }
        Self.log("UserDriver: showing scheduled update — \(Self.describe(update)) | userInitiated=\(state.userInitiated)")
        return true
    }

    func standardUserDriverWillShowModalAlert() {
        Self.log("UserDriver: will show modal alert")
    }

    func standardUserDriverDidShowModalAlert() {
        Self.log("UserDriver: did show modal alert")
    }

    /// Surface an update-check phase in the footer bar.
    ///
    /// Sparkle's delegate callbacks are nonisolated and can arrive on any
    /// thread, so this hops to the main actor.
    nonisolated private static func announce(_ label: String) {
        Task { @MainActor in
            TransientActivityCoordinator.shared.flash(label)
        }
    }
}
