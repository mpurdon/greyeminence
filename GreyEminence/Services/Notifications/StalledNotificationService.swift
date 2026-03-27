import UserNotifications
import SwiftData

/// Schedules a daily macOS notification summarizing stalled action items.
@MainActor
final class StalledNotificationService {
    static let shared = StalledNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let notificationID = "com.greyeminence.stalled-summary"

    private init() {}

    /// Request notification authorization. Call once on app launch.
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    /// Schedule (or reschedule) the daily stalled-items notification.
    /// Pass `count: 0` to cancel the notification.
    func scheduleDailySummary(stalledCount: Int) {
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        guard stalledCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Stalled Action Items"
        content.body = stalledCount == 1
            ? "1 action item has been stalled for too long."
            : "\(stalledCount) action items have been stalled for too long."
        content.sound = .default

        // Fire at 9 AM daily
        var components = DateComponents()
        components.hour = 9
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)

        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    /// Refresh the daily notification based on current stalled items in the model context.
    func refresh(in modelContext: ModelContext) {
        let threshold = UserDefaults.standard.integer(forKey: "stalledThresholdDays")
        let effectiveThreshold = threshold > 0 ? threshold : 7
        let stalled = CommitmentTrackingService().stalledCommitments(
            in: modelContext,
            threshold: effectiveThreshold
        )
        scheduleDailySummary(stalledCount: stalled.count)
    }
}
