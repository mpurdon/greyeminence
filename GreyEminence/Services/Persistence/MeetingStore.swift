import Foundation
import SwiftData

@Observable
@MainActor
final class MeetingStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func createMeeting(title: String = "New Meeting") -> Meeting {
        let meeting = Meeting(title: title)
        modelContext.insert(meeting)
        try? modelContext.save()
        return meeting
    }

    func deleteMeeting(_ meeting: Meeting) {
        modelContext.delete(meeting)
        try? modelContext.save()
    }

    func save() {
        try? modelContext.save()
    }

    func addSegment(
        to meeting: Meeting,
        speaker: Speaker,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isFinal: Bool
    ) -> TranscriptSegment {
        let segment = TranscriptSegment(
            speaker: speaker,
            text: text,
            startTime: startTime,
            endTime: endTime,
            isFinal: isFinal
        )
        segment.meeting = meeting
        meeting.segments.append(segment)
        try? modelContext.save()
        return segment
    }

    func addActionItem(to meeting: Meeting, text: String, assignee: String? = nil) -> ActionItem {
        let item = ActionItem(text: text, assignee: assignee)
        item.meeting = meeting
        meeting.actionItems.append(item)
        try? modelContext.save()
        return item
    }

    func toggleActionItem(_ item: ActionItem) {
        item.isCompleted.toggle()
        try? modelContext.save()
    }

    func addInsight(
        to meeting: Meeting,
        summary: String,
        followUpQuestions: [String],
        topics: [String]
    ) -> MeetingInsight {
        let insight = MeetingInsight(
            summary: summary,
            followUpQuestions: followUpQuestions,
            topics: topics
        )
        insight.meeting = meeting
        meeting.insights.append(insight)
        try? modelContext.save()
        return insight
    }
}
