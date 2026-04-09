import Foundation
import SwiftData

/// Central point for persisting changes through a `ModelContext`. Replaces the
/// pervasive `try? modelContext.save()` pattern, which silently swallows failures
/// and masks data loss.
///
/// The rules applied here:
///  1. Every save is logged — successes with the save site, failures with the
///     underlying error and call site.
///  2. Save failures are counted. Three consecutive failures in a critical path
///     flip `PersistenceGate.isFaulted`, which UI can observe to show a banner
///     and stop further writes that would compound the problem.
///  3. Callers can opt into `critical: true` for active-recording paths, which
///     logs at `.error` level and increments the fault counter. Non-critical saves
///     (e.g. marking an action item complete) log at `.warning` and never fault.
///  4. Saves always return success/failure so callers in critical paths can react
///     (e.g. pause recording, show an alert) instead of blindly continuing.
enum PersistenceGate {
    /// Flipped to `true` after three consecutive critical save failures.
    /// Observed by recording paths so they can pause rather than keep appending
    /// to a context that can't flush.
    nonisolated(unsafe) private static var consecutiveCriticalFailures: Int = 0
    nonisolated(unsafe) static private(set) var isFaulted: Bool = false

    /// Most recent failure description, for UI surfacing.
    nonisolated(unsafe) static private(set) var lastFailureMessage: String?

    private static let faultThreshold = 3

    /// Save the given context. Logs success/failure.
    /// - Returns: `true` on success, `false` on failure (never throws).
    @discardableResult
    static func save(
        _ context: ModelContext,
        site: String,
        critical: Bool = false,
        meetingID: UUID? = nil,
        file: String = #fileID,
        line: Int = #line
    ) -> Bool {
        do {
            try context.save()
            if critical && consecutiveCriticalFailures > 0 {
                LogManager.send(
                    "Persistence recovered at \(site) after \(consecutiveCriticalFailures) failure(s)",
                    category: .general,
                    level: .info,
                    meetingID: meetingID
                )
            }
            if critical {
                consecutiveCriticalFailures = 0
                isFaulted = false
                lastFailureMessage = nil
            }
            return true
        } catch {
            let level: LogEntry.Level = critical ? .error : .warning
            let message = "Persistence save failed at \(site) (\(file):\(line)): \(error.localizedDescription)"
            LogManager.send(message, category: .general, level: level, meetingID: meetingID)
            lastFailureMessage = error.localizedDescription
            if critical {
                consecutiveCriticalFailures += 1
                if consecutiveCriticalFailures >= faultThreshold {
                    isFaulted = true
                    LogManager.send(
                        "Persistence faulted after \(consecutiveCriticalFailures) consecutive failures — recording paths should pause",
                        category: .general,
                        level: .error,
                        meetingID: meetingID
                    )
                }
            }
            return false
        }
    }

    /// Reset fault state. Call after the user acknowledges a persistence error or
    /// after a successful recovery.
    static func clearFault() {
        consecutiveCriticalFailures = 0
        isFaulted = false
        lastFailureMessage = nil
    }
}
