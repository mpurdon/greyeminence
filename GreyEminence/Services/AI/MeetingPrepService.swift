import Foundation
import SwiftData

struct MeetingPrepContext: Sendable {
    /// Why this card exists — drives both the UI and whether we have real
    /// history to feed the AI prompt. Cases carry data, not rendered copy; the
    /// view owns the wording.
    enum Provenance: Sendable, Equatable {
        /// Prior recorded occurrences of this exact meeting were found.
        case history(count: Int, mostRecent: Date?)
        /// A recurring meeting we've never recorded before — no history yet.
        case firstOccurrence(title: String)
        /// A one-off meeting: there is no "previous occurrence" to prep from.
        case notApplicable
    }

    let provenance: Provenance
    let unresolvedItems: [PrepActionItem]
    let previousTopics: [String]
    let followUps: [String]
    /// What other meetings say about this one's subject — filled in
    /// asynchronously, beside (never mixed into) the series sections.
    /// See `MeetingPrepRelated`.
    var related: RelatedPrepStatus = .notRequested

    /// Whether there is carried-over content from prior occurrences. Gates both
    /// the populated UI sections and the AI prompt injection.
    var hasContent: Bool {
        !unresolvedItems.isEmpty || !previousTopics.isEmpty || !followUps.isEmpty
    }

    /// Whether the card should appear at all. Recurring meetings always show
    /// *something* (real prep, or a stated "no history yet"); a one-off shows
    /// only once related context has turned up.
    var shouldDisplay: Bool {
        switch provenance {
        case .notApplicable: return related.prep != nil
        case .firstOccurrence, .history: return true
        }
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
    /// How many recent prior occurrences to base prep on — the user cares mainly
    /// about the previous meeting, with one more for continuity.
    static let recentMeetingLimit = 2

    /// Gather prep context for the meeting the user is about to record, drawn
    /// **only** from prior recorded occurrences of this same recurring meeting.
    ///
    /// Deliberately NOT attendee-based: sharing attendees with unrelated meetings
    /// is not a meeting relationship, and pulling their action items/topics in
    /// produces nonsense (e.g. a "Client Data" meeting showing "US Politics"
    /// topics from an unrelated chat with the same two people). When there's no
    /// recorded history of *this* meeting, we say so rather than inventing prep.
    ///
    /// `excludingMeetingID` is the recording in progress: at record start it
    /// is linked to the event *before* prep is rebuilt, and must not count as
    /// its own "last time".
    func gatherPrepContext(
        for event: CalendarEvent,
        excludingMeetingID: UUID? = nil,
        in context: ModelContext
    ) -> MeetingPrepContext {
        func empty(_ provenance: MeetingPrepContext.Provenance) -> MeetingPrepContext {
            MeetingPrepContext(provenance: provenance, unresolvedItems: [], previousTopics: [], followUps: [])
        }

        // Prep is anchored to the recurring series. A one-off has no prior
        // occurrence to prep from.
        guard event.recurrenceID != nil else {
            return empty(.notApplicable)
        }

        // Prior recorded occurrences of this same series (newest first, bounded).
        let recent = CalendarService.priorOccurrences(
            of: event,
            limit: Self.recentMeetingLimit,
            excludingMeetingID: excludingMeetingID,
            in: context
        )
        guard !recent.isEmpty else {
            return empty(.firstOccurrence(title: event.title ?? "this meeting"))
        }

        var unresolvedItems: [PrepActionItem] = []
        var previousTopics: [String] = []
        var followUps: [String] = []
        let now = Date.now
        for meeting in recent {
            // Unresolved means neither done nor deliberately dropped. A
            // "won't do" item is a decision already taken; surfacing it again
            // next time is exactly the nag the status exists to stop.
            for item in meeting.actionItems where !item.isCompleted && !item.isDismissed {
                let days = Calendar.current.dateComponents([.day], from: item.createdAt, to: now).day ?? 0
                unresolvedItems.append(PrepActionItem(
                    id: item.id,
                    text: item.text,
                    assignee: Self.cleanAssignee(item.displayAssignee),
                    meetingTitle: meeting.title,
                    meetingDate: meeting.date,
                    daysSinceCreated: days
                ))
            }
            for insight in meeting.insights {
                previousTopics.append(contentsOf: insight.topics)
                followUps.append(contentsOf: insight.followUpQuestions)
            }
        }

        return MeetingPrepContext(
            provenance: .history(count: recent.count, mostRecent: recent.first?.date),
            // Newest occurrence first — the previous meeting is the priority.
            unresolvedItems: unresolvedItems.sorted { $0.meetingDate > $1.meetingDate },
            previousTopics: Self.dedupePreservingOrder(previousTopics),
            followUps: Self.dedupePreservingOrder(followUps)
        )
    }

    /// Every recorded occurrence of `event`'s series. Related context skips
    /// them — what the series itself left open is the series prep's job.
    static func seriesMeetingIDs(for event: CalendarEvent, in context: ModelContext) -> Set<UUID> {
        guard let recurrenceID = event.recurrenceID else { return [] }
        var descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.calendarEventID == recurrenceID })
        descriptor.propertiesToFetch = [\.id]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.id))
    }

    // MARK: - Pure helpers (unit-tested without SwiftData)

    /// Suppress diarization placeholders ("Speaker 2", "Unknown", "Me") that
    /// aren't real owners — showing them as an assignee is noise.
    nonisolated static func cleanAssignee(_ assignee: String?) -> String? {
        guard let trimmed = assignee?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower == "me" || lower == "unknown" || lower.hasPrefix("speaker ") { return nil }
        return trimmed
    }

    /// Deduplicate keeping first-seen order (stable, unlike `Set`).
    nonisolated static func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where seen.insert(item).inserted { out.append(item) }
        return out
    }
}
