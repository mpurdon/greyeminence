import Foundation
import SwiftData

struct MeetingPrepContext: Sendable {
    let unresolvedItems: [PrepActionItem]
    let previousTopics: [String]
    let followUps: [String]
    let attendeeNames: [String]

    var isEmpty: Bool {
        unresolvedItems.isEmpty && previousTopics.isEmpty && followUps.isEmpty
    }
}

struct PrepActionItem: Sendable, Identifiable {
    let id: UUID
    let text: String
    let assignee: String?
    let meetingTitle: String
    let meetingDate: Date
    let daysSinceCreated: Int
}

@MainActor
final class MeetingPrepService {
    /// Gather prep context for an upcoming meeting based on attendees and series.
    func gatherPrepContext(
        attendees: [Contact],
        seriesID: UUID?,
        in context: ModelContext
    ) -> MeetingPrepContext {
        var relatedMeetings: Set<UUID> = []
        var unresolvedItems: [PrepActionItem] = []
        var previousTopics: [String] = []
        var followUps: [String] = []

        // Find meetings with overlapping attendees
        for contact in attendees {
            for meeting in contact.meetings {
                relatedMeetings.insert(meeting.id)
            }
        }

        // Include meetings from the same series
        if let seriesID {
            let descriptor = FetchDescriptor<Meeting>(
                predicate: #Predicate<Meeting> { m in
                    m.seriesID == seriesID
                }
            )
            if let seriesMeetings = try? context.fetch(descriptor) {
                for meeting in seriesMeetings {
                    relatedMeetings.insert(meeting.id)
                }
            }
        }

        // Gather unresolved action items from related meetings
        let now = Date.now
        let allMeetingDescriptor = FetchDescriptor<Meeting>()
        let allMeetings = (try? context.fetch(allMeetingDescriptor)) ?? []

        for meeting in allMeetings where relatedMeetings.contains(meeting.id) {
            // Unresolved action items
            for item in meeting.actionItems where !item.isCompleted {
                let days = Calendar.current.dateComponents([.day], from: item.createdAt, to: now).day ?? 0
                unresolvedItems.append(PrepActionItem(
                    id: item.id,
                    text: item.text,
                    assignee: item.displayAssignee,
                    meetingTitle: meeting.title,
                    meetingDate: meeting.date,
                    daysSinceCreated: days
                ))
            }

            // Topics and follow-ups from insights
            for insight in meeting.insights {
                previousTopics.append(contentsOf: insight.topics)
                followUps.append(contentsOf: insight.followUpQuestions)
            }
        }

        // Deduplicate
        let uniqueTopics = Array(Set(previousTopics)).sorted()
        let uniqueFollowUps = Array(Set(followUps))

        return MeetingPrepContext(
            unresolvedItems: unresolvedItems.sorted { $0.daysSinceCreated > $1.daysSinceCreated },
            previousTopics: uniqueTopics,
            followUps: uniqueFollowUps,
            attendeeNames: attendees.map(\.name)
        )
    }
}
