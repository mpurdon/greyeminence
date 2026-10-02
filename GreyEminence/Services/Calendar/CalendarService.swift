import EventKit
import SwiftData

@Observable
@MainActor
final class CalendarService {
    enum AuthorizationState {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var authorizationState: AuthorizationState = .notDetermined

    private nonisolated(unsafe) let store = EKEventStore()
    /// Microsoft Graph provider — only fetches when the user has connected an
    /// account and enabled it. Best-effort: failures never block EventKit results.
    private let graph = GraphCalendarProvider()

    // Short-lived cache so the two fetches that fire at record-start
    // (matchCalendarAtStart + the toolbar menu's onAppear) and rapid menu
    // re-opens share one network round-trip instead of each hitting Graph.
    private struct EventsCache { let minutes: TimeInterval; let events: [CalendarEvent]; let at: Date }
    private var eventsCache: EventsCache?
    private var inFlightFetch: Task<[CalendarEvent], Never>?
    private var inFlightMinutes: TimeInterval?
    private let eventsCacheTTL: TimeInterval = 30

    init() {
        // Seed from the system's current authorization so MenuBar /
        // auto-detection startRecording paths (which don't go through the
        // RecordingView .task that calls requestAccess) don't silently fall
        // into "not authorized" when the user already granted access in a
        // prior session.
        authorizationState = Self.systemAuthorizationState()
    }

    private static func systemAuthorizationState() -> AuthorizationState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: .authorized
        case .denied, .restricted, .writeOnly: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    func requestAccess() async {
        LogManager.shared.log("Calendar: requesting full access", category: .general)
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationState = granted ? .authorized : .denied
            LogManager.shared.log(
                "Calendar: access \(granted ? "granted" : "denied by user/system")",
                category: .general,
                level: granted ? .info : .warning
            )
            if granted {
                // Pull the latest from each account (Exchange/Office365 sync lazily)
                // and log what EventKit can actually see, so a missing work/Teams
                // calendar is diagnosable from the Activity Log.
                store.refreshSourcesIfNecessary()
                logAvailableCalendars()
            }
        } catch {
            authorizationState = .denied
            // Most common cause of a thrown error here: missing
            // NSCalendarsFullAccessUsageDescription in Info.plist — the system
            // refuses to even prompt without it.
            LogManager.shared.log(
                "Calendar: access request failed — \(error.localizedDescription) (check NSCalendarsFullAccessUsageDescription in Info.plist)",
                category: .general,
                level: .warning
            )
        }
    }

    /// All calendar events within ±`minutes` of now, merged from every enabled
    /// source (local EventKit + Microsoft Graph) and sorted by proximity to now.
    /// Served from a short cache; pass `force: true` (e.g. the toolbar's Refresh
    /// button) to bypass it. Concurrent callers coalesce onto one fetch.
    func eventsInWindow(minutes: TimeInterval = 60, force: Bool = false) async -> [CalendarEvent] {
        if !force {
            if let cache = eventsCache, cache.minutes == minutes,
               Date.now.timeIntervalSince(cache.at) < eventsCacheTTL {
                return cache.events
            }
            if let inFlightFetch, inFlightMinutes == minutes {
                return await inFlightFetch.value
            }
        }

        let task = Task { [weak self] () -> [CalendarEvent] in
            guard let self else { return [] }
            return await self.fetchEventsInWindow(around: Date.now, minutes: minutes)
        }
        inFlightFetch = task
        inFlightMinutes = minutes
        let result = await task.value
        // Leave a forced refresh that replaced us in charge of its own cleanup.
        if inFlightFetch == task {
            inFlightFetch = nil
            inFlightMinutes = nil
        }
        eventsCache = EventsCache(minutes: minutes, events: result, at: Date.now)
        return result
    }

    /// Events near a specific date — used to link a *past* meeting to its
    /// calendar event after the fact. Not cached (the cache is for the "now"
    /// window the recording flow polls).
    func eventsAround(date: Date, minutes: TimeInterval = 90) async -> [CalendarEvent] {
        await fetchEventsInWindow(around: date, minutes: minutes)
    }

    private func fetchEventsInWindow(around date: Date, minutes: TimeInterval) async -> [CalendarEvent] {
        var merged = eventKitEventsInWindow(around: date, minutes: minutes)

        // Graph is best-effort and self-gates (returns [] unless connected+enabled),
        // so a network/token failure can never drop the local results.
        let graphEvents = await graph.eventsInWindow(minutes: minutes, around: date)
        if !graphEvents.isEmpty {
            merged = deduplicate(local: merged, remote: graphEvents)
        }

        // Dropped here rather than in the picker, so a called-off meeting can
        // also never be auto-linked to a recording or fed to meeting prep.
        // After deduplication: a cancellation that reached only one of the two
        // stores still removes the pair, because the surviving copy is matched
        // and dropped on its own merits.
        return merged
            .filter { !$0.isCancelled }
            .sorted {
                abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date))
            }
    }

    /// Drop Graph events that are the same meeting as a local one (the account
    /// is in both stores). Matches on normalized title AND both start and end
    /// minute — requiring the full time span to agree avoids merging two
    /// genuinely different meetings that merely share a title and start minute.
    /// Local (EventKit) wins.
    private func deduplicate(local: [CalendarEvent], remote: [CalendarEvent]) -> [CalendarEvent] {
        func key(_ e: CalendarEvent) -> String {
            let title = (e.title ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let startMinute = Int(e.startDate.timeIntervalSince1970 / 60)
            let endMinute = Int(e.endDate.timeIntervalSince1970 / 60)
            return "\(title)@\(startMinute)-\(endMinute)"
        }
        let localKeys = Set(local.map(key))
        return local + remote.filter { !localKeys.contains(key($0)) }
    }

    /// EventKit query mapped to the neutral model. Synchronous (no network).
    private func eventKitEventsInWindow(around date: Date, minutes: TimeInterval) -> [CalendarEvent] {
        guard authorizationState == .authorized else {
            // .info, not .warning — for users who deliberately denied calendar
            // access this is steady-state, not an anomaly. Repeated toolbar
            // mounts shouldn't spam the warnings channel.
            LogManager.shared.log(
                "Calendar: eventKit fetch(\(Int(minutes))m) skipped — authorization state is \(authorizationState)",
                category: .general
            )
            return []
        }
        // Refresh Exchange/CalDAV sources before querying — a long-lived store
        // can otherwise serve stale data (or miss a recently-added account).
        store.refreshSourcesIfNecessary()

        let selected = selectedEventKitCalendars()
        guard !selected.isEmpty else { return [] }

        let start = date.addingTimeInterval(-minutes * 60)
        let end = date.addingTimeInterval(minutes * 60)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        // All-day events (vacations, holidays, birthdays) aren't meetings — exclude them.
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map(Self.mapToCalendarEvent)
        LogManager.shared.log(
            "Calendar: EventKit found \(events.count) event(s) within ±\(Int(minutes))m across \(selected.count) calendar(s)",
            category: .general
        )
        // When nothing turned up, surface which calendars EventKit knows about —
        // a missing Teams/Outlook calendar here means the account isn't synced
        // to macOS (vs. an empty window), which is the usual cause.
        if events.isEmpty {
            logAvailableCalendars()
        }
        return events
    }

    /// The EventKit calendars to query: all of them minus the ones the user
    /// excluded in Settings. Empty when there are no calendars at all or every
    /// calendar is excluded — both logged for diagnostics.
    private func selectedEventKitCalendars() -> [EKCalendar] {
        let all = store.calendars(for: .event)
        guard !all.isEmpty else {
            logAvailableCalendars()
            return []
        }
        let disabled = CalendarSelection.disabledIDs()
        let selected = all.filter { !disabled.contains($0.calendarIdentifier) }
        if selected.isEmpty {
            LogManager.shared.log(
                "Calendar: all \(all.count) local calendar(s) are excluded in Settings → Calendar",
                category: .general
            )
        }
        return selected
    }

    private static func mapToCalendarEvent(_ event: EKEvent) -> CalendarEvent {
        let linkID = event.calendarItemIdentifier
        return CalendarEvent(
            id: event.eventIdentifier ?? linkID,
            linkIdentifier: linkID,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate ?? event.startDate,
            attendees: attendeeNames(for: event),
            // A moved or edited occurrence is detached from its series and
            // can report no rules of its own — it's still part of the series.
            isRecurring: event.hasRecurrenceRules || event.isDetached,
            isCancelled: event.status == .canceled
                || CalendarEvent.titleIndicatesCancellation(event.title),
            source: .eventKit
        )
    }

    /// Extract attendees (with emails) from an EventKit event. Rooms and
    /// equipment aren't people — they never become contacts.
    private static func attendeeNames(for event: EKEvent) -> [EventAttendee] {
        guard let attendees = event.attendees else { return [] }
        return attendees.compactMap { participant in
            switch participant.participantType {
            case .room, .resource: return nil
            default: break
            }
            // EKParticipant carries the address as a mailto: URL.
            let email = participant.url.absoluteString.components(separatedBy: ":").last
                .flatMap { $0.contains("@") ? $0 : nil }
            return EventAttendee.resolve(
                name: participant.name,
                email: email,
                isCurrentUser: participant.isCurrentUser
            )
        }
    }

    /// Log every event calendar EventKit can see, with its account/source type.
    /// The key diagnostic for "my Teams calendar isn't showing": if the work
    /// account isn't listed, it isn't synced into macOS at all.
    private func logAvailableCalendars() {
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else {
            LogManager.shared.log(
                "Calendar: EventKit sees 0 event calendars — no calendar accounts are synced to macOS. Add your work/Exchange (Teams/Outlook) account in System Settings → Internet Accounts and enable Calendars, or connect Microsoft 365 in Settings → Calendar.",
                category: .general,
                level: .warning
            )
            return
        }
        let summary = calendars
            .map { "\"\($0.title)\" [\(Self.describe($0.source))]" }
            .joined(separator: ", ")
        LogManager.shared.log(
            "Calendar: EventKit sees \(calendars.count) calendar(s): \(summary)",
            category: .general
        )
    }

    /// Titles of the local calendars EventKit can see, for display in Settings.
    func localCalendarNames() -> [String] {
        store.calendars(for: .event).map(\.title)
    }

    /// Every calendar available for matching, across local + connected sources.
    /// Used by Settings to let the user choose which calendars to look in.
    func availableCalendars() async -> [CalendarChoice] {
        var choices = store.calendars(for: .event).map {
            CalendarChoice(
                id: $0.calendarIdentifier,
                title: $0.title,
                account: $0.source?.title ?? "Local",
                source: .eventKit
            )
        }
        choices += await graph.availableCalendars()
        return choices
    }

    private static func describe(_ source: EKSource?) -> String {
        guard let source else { return "unknown" }
        let type: String
        switch source.sourceType {
        case .local: type = "local"
        case .exchange: type = "exchange"
        case .calDAV: type = "calDAV"
        case .mobileMe: type = "iCloud"
        case .subscribed: type = "subscribed"
        case .birthdays: type = "birthdays"
        @unknown default: type = "other"
        }
        return "\(source.title) · \(type)"
    }

    /// Match event attendees to existing Contact records.
    /// Email is the strongest key; then exact name/email/alias; then first name.
    func matchContacts(attendees: [EventAttendee], existing: [Contact]) -> [(attendee: EventAttendee, contact: Contact?)] {
        attendees.map { attendee in
            if let email = attendee.email,
               let byEmail = existing.first(where: { $0.email?.lowercased() == email }) {
                return (attendee, byEmail)
            }

            let lowered = attendee.name.lowercased()
            let exact = existing.first { contact in
                contact.name.lowercased() == lowered ||
                contact.email?.lowercased() == lowered ||
                contact.speakerAliases.contains(where: { $0.lowercased() == lowered })
            }
            if let exact { return (attendee, exact) }

            // Fallback: first-name match (handles "Bob" matching "Bob Smith")
            let fn = firstName(from: lowered)
            guard fn.count >= 3 else { return (attendee, nil) }
            let firstNameMatch = existing.first { contact in
                firstName(from: contact.name.lowercased()) == fn
            }
            return (attendee, firstNameMatch)
        }
    }

    private func firstName(from fullName: String) -> String {
        fullName.components(separatedBy: " ").first ?? fullName
    }

    /// Prior recorded meetings that are occurrences of the same recurring series
    /// as `event`, newest first, capped at `limit`. The single source of truth
    /// for "which past meetings belong to this event's series" (used by meeting
    /// prep) — keyed on the recurrence id, same join `matchToSeries` uses to
    /// build a series. Empty for a one-off event (no recurrence key). The sort +
    /// limit run in SQLite so a long series doesn't hydrate every occurrence.
    nonisolated static func priorOccurrences(
        of event: CalendarEvent,
        limit: Int,
        excludingMeetingID: UUID? = nil,
        in context: ModelContext
    ) -> [Meeting] {
        guard let recurrenceID = event.recurrenceID else { return [] }
        var descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate<Meeting> { $0.calendarEventID == recurrenceID },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        // One spare, so dropping the excluded meeting still leaves `limit`.
        descriptor.fetchLimit = limit + (excludingMeetingID == nil ? 0 : 1)
        let found = (try? context.fetch(descriptor)) ?? []
        return Array(found.filter { $0.id != excludingMeetingID }.prefix(limit))
    }

    /// Find existing meetings with the same recurring event ID and assign a shared series.
    func matchToSeries(
        event: CalendarEvent,
        meeting: Meeting,
        in context: ModelContext
    ) {
        guard let recurrenceID = event.recurrenceID else { return }

        // Look for existing meetings with this specific recurrence ID
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate<Meeting> { m in
                m.calendarEventID == recurrenceID
            }
        )
        guard let seriesMeetings = try? context.fetch(descriptor) else { return }

        if let existingSeries = seriesMeetings.first(where: { $0.seriesID != nil }) {
            // Join existing series
            meeting.seriesID = existingSeries.seriesID
            meeting.seriesTitle = existingSeries.seriesTitle ?? event.title
        } else if !seriesMeetings.isEmpty {
            // Create new series from these meetings
            let seriesID = UUID()
            let seriesTitle = event.title ?? "Recurring Meeting"
            meeting.seriesID = seriesID
            meeting.seriesTitle = seriesTitle
            for existing in seriesMeetings {
                existing.seriesID = seriesID
                existing.seriesTitle = seriesTitle
            }
        }
    }

    /// Apply a calendar event to a meeting: record the link, add matched
    /// attendees, and join any recurring series. `setTitle` controls whether the
    /// meeting title adopts the event name — true at record-start, **false** when
    /// linking a past meeting after the fact (we don't want to clobber the
    /// already-generated title; only the attendees should change).
    @discardableResult
    func linkEvent(
        _ event: CalendarEvent,
        to meeting: Meeting,
        in context: ModelContext,
        setTitle: Bool
    ) -> (added: Int, alreadyPresent: Int) {
        if setTitle {
            meeting.title = event.title ?? meeting.title
        }
        meeting.calendarEventID = event.linkIdentifier
        meeting.calendarEventTitle = event.title

        let contacts = (try? context.fetch(FetchDescriptor<Contact>())) ?? []
        let matched = matchContacts(attendees: event.attendees, existing: contacts)
        var added = 0
        var alreadyPresent = 0
        var created = 0
        // Dedupe within this event: the same unmatched person appearing twice
        // must not produce two Contact rows.
        var createdByKey: [String: Contact] = [:]
        for (attendee, match) in matched {
            // An invite must not resurrect an inactive contact (someone who
            // left). We still recognize the match here — so we don't create a
            // duplicate for them — but skip re-adding them to the meeting.
            if let match, match.isArchived { continue }
            var contact = match
            if contact == nil {
                // The invite gives us a full identity — create the contact so
                // future matching (and speaker linking) knows this person.
                // Never create a record for the user themself.
                guard !attendee.isCurrentUser else { continue }
                let key = attendee.email ?? attendee.name.lowercased()
                if let existing = createdByKey[key] {
                    contact = existing
                } else {
                    let new = Contact(name: attendee.name, email: attendee.email)
                    context.insert(new)
                    createdByKey[key] = new
                    created += 1
                    contact = new
                }
            }
            guard let contact else { continue }
            if meeting.attendees.contains(where: { $0.id == contact.id }) {
                alreadyPresent += 1
            } else {
                meeting.attendees.append(contact)
                added += 1
            }
        }

        matchToSeries(event: event, meeting: meeting, in: context)
        LogManager.shared.log(
            "Calendar event linked (\(setTitle ? "title+attendees" : "attendees only")): \"\(event.title ?? "untitled")\" — \(added) added (\(created) new contact\(created == 1 ? "" : "s")), \(alreadyPresent) already present",
            category: .general
        )
        return (added, alreadyPresent)
    }
}
