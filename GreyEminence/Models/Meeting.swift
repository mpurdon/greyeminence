import Foundation
import SwiftData

enum MeetingStatus: String, Codable, Sendable {
    case recording
    case paused
    case completed
}

@Model
final class Meeting {
    var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var status: MeetingStatus
    var audioFilePath: String?
    var systemAudioFilePath: String?
    var isExportedToObsidian: Bool
    var isAnalyzing: Bool = false
    var analysisError: String?
    var createdAt: Date

    // Calendar integration
    var calendarEventID: String?
    var calendarEventTitle: String?

    // Recurring meeting tracking
    var seriesID: UUID?
    var seriesTitle: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    @Relationship(deleteRule: .cascade, inverse: \ActionItem.meeting)
    var actionItems: [ActionItem]

    @Relationship(deleteRule: .cascade, inverse: \MeetingInsight.meeting)
    var insights: [MeetingInsight]

    @Relationship(deleteRule: .nullify)
    var attendees: [Contact] = []

    init(
        title: String = "New Meeting",
        date: Date = .now,
        duration: TimeInterval = 0,
        status: MeetingStatus = .recording
    ) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.duration = duration
        self.status = status
        self.isExportedToObsidian = false
        self.isAnalyzing = false
        self.createdAt = .now
        self.segments = []
        self.actionItems = []
        self.insights = []
        self.attendees = []
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var pendingActionCount: Int {
        actionItems.filter { !$0.isCompleted }.count
    }

    var latestInsight: MeetingInsight? {
        insights.sorted { $0.createdAt > $1.createdAt }.first
    }
}
