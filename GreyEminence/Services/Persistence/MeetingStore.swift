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
        PersistenceGate.save(modelContext, site: "MeetingStore.createMeeting")
        return meeting
    }

    func deleteMeeting(_ meeting: Meeting) {
        MeetingDeletion.delete(meeting, in: modelContext)
    }

    func save() {
        PersistenceGate.save(modelContext, site: "MeetingStore.save")
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
        PersistenceGate.save(modelContext, site: "MeetingStore.addSegment", meetingID: meeting.id)
        return segment
    }

    func addActionItem(to meeting: Meeting, text: String, assignee: String? = nil) -> ActionItem {
        let item = ActionItem(text: text, assignee: assignee)
        item.meeting = meeting
        meeting.actionItems.append(item)
        PersistenceGate.save(modelContext, site: "MeetingStore.addActionItem", meetingID: meeting.id)
        return item
    }

    func toggleActionItem(_ item: ActionItem) {
        item.isCompleted.toggle()
        PersistenceGate.save(modelContext, site: "MeetingStore.toggleActionItem", meetingID: item.meeting?.id)
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
        PersistenceGate.save(modelContext, site: "MeetingStore.addInsight", meetingID: meeting.id)
        return insight
    }
}
