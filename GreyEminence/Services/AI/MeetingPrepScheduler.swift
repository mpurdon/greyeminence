import Foundation
import SwiftData

/// Front-runs related-context prep for today's meetings so it's ready before
/// you open the recording screen, then refreshes each one shortly before it
/// starts — a meeting held in between (often one *to prepare for* this one)
/// is exactly the context that's newest and most useful.
///
/// Also the single owner of every related-prep build: the recording screen
/// asks here rather than building its own, so concurrent asks for one event
/// share a search + summary, and a re-pick or record start can't cancel one
/// mid-flight.
@MainActor
final class MeetingPrepScheduler {
    static let shared = MeetingPrepScheduler()

    static let tickInterval: Duration = .seconds(5 * 60)
    /// How often to re-read today's calendar: invites move and land all day.
    static let calendarRefreshInterval: TimeInterval = 30 * 60
    /// The pre-call refresh fires this far ahead of the start.
    static let preCallLead: TimeInterval = 15 * 60
    /// A prep younger than this isn't worth redoing before the call.
    static let refreshMinAge: TimeInterval = 30 * 60

    struct Entry: Codable {
        let title: String
        let startDate: Date
        var generatedAt: Date
        /// nil: searched, nothing substantive.
        var prep: RelatedPrep?
        var refreshedBeforeCall: Bool
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<RelatedPrep?, Never>] = [:]
    private var loop: Task<Void, Never>?
    private var todaysEvents: [CalendarEvent] = []
    private var eventsFetchedAt: Date?
    private weak var recordingViewModel: RecordingViewModel?
    private var modelContext: ModelContext?

    private var cacheURL: URL {
        StorageManager.shared.appSupportURL.appendingPathComponent("MeetingPrepCache.json")
    }

    /// Occurrence identity. The start time is part of it so a series whose
    /// provider reuses an identifier across occurrences still gets one entry
    /// per day.
    nonisolated static func key(for event: CalendarEvent) -> String {
        "\(event.id)@\(Int(event.startDate.timeIntervalSince1970))"
    }

    /// Worth front-running: a real meeting with other people and a title that
    /// names a subject. Skips all-day entries (holidays, birthdays) and
    /// solo blocks ("Focus time", "Lunch").
    nonisolated static func isPreppable(_ event: CalendarEvent) -> Bool {
        event.endDate.timeIntervalSince(event.startDate) < 20 * 3600
            && !event.attendees.isEmpty
            && !MeetingPrepRelated.keywords(fromTitle: event.title ?? "").isEmpty
    }

    func start(recordingViewModel: RecordingViewModel, modelContext: ModelContext) {
        guard loop == nil else { return }
        self.recordingViewModel = recordingViewModel
        self.modelContext = modelContext
        load()
        loop = Task { [weak self] in
            // Let launch settle: the embedding backfill starts at ~5s.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// What's already known for `event`, without searching.
    func cachedStatus(for event: CalendarEvent) -> RelatedPrepStatus? {
        guard let entry = entries[Self.key(for: event)] else { return nil }
        return entry.prep.map { .ready($0) } ?? .none
    }

    /// Cached, in-flight, or freshly built related context for `event`.
    func related(for event: CalendarEvent, excludingMeetingID: UUID?) async -> RelatedPrepStatus {
        if let cached = cachedStatus(for: event) { return cached }
        let prep = await build(event, excludingMeetingID: excludingMeetingID, refreshedBeforeCall: false)
        return prep.map { .ready($0) } ?? .none
    }

    // MARK: - Building

    private func build(_ event: CalendarEvent, excludingMeetingID: UUID? = nil, refreshedBeforeCall: Bool) async -> RelatedPrep? {
        let key = Self.key(for: event)
        if let running = inFlight[key] { return await running.value }
        guard let title = event.title, let modelContext else { return nil }

        var excluded = MeetingPrepService.seriesMeetingIDs(for: event, in: modelContext)
        if let excludingMeetingID { excluded.insert(excludingMeetingID) }
        let start = event.startDate
        // Unstructured on purpose: a caller that stops waiting doesn't stop
        // the build, so the next ask gets the result instead of starting over.
        let task = Task { await MeetingPrepRelated.build(title: title, meetingStart: start, excludingMeetingIDs: excluded) }
        inFlight[key] = task
        let prep = await task.value
        inFlight[key] = nil

        entries[key] = Entry(
            title: title,
            startDate: start,
            generatedAt: .now,
            prep: prep,
            refreshedBeforeCall: refreshedBeforeCall
        )
        save()
        recordingViewModel?.relatedPrepUpdated(key: key, status: prep.map { .ready($0) } ?? .none)
        return prep
    }

    // MARK: - Schedule

    private func tick() async {
        guard UserDefaults.standard.bool(forKey: "calendarIntegration"),
              let calendarService = recordingViewModel?.calendarService,
              calendarService.authorizationState == .authorized else { return }

        let now = Date.now
        if let fetchedAt = eventsFetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.calendarRefreshInterval,
           Calendar.current.isDate(fetchedAt, inSameDayAs: now) {
            // Today's list is fresh enough.
        } else {
            let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
            let minutes = endOfDay.timeIntervalSince(now) / 60
            let fetched = await calendarService.eventsAround(date: now, minutes: minutes)
            let upcoming = fetched.filter { Calendar.current.isDate($0.startDate, inSameDayAs: now) && $0.startDate > now }
            todaysEvents = upcoming.filter(Self.isPreppable).sorted { $0.startDate < $1.startDate }
            eventsFetchedAt = now
            LogManager.send(
                "Prep: \(upcoming.count) meeting(s) left today, \(todaysEvents.count) worth prepping (others are all-day, solo, or generically titled)",
                category: .general
            )
        }

        for event in todaysEvents where event.startDate > Date.now {
            let key = Self.key(for: event)
            guard let entry = entries[key] else {
                LogManager.send("Prep: front-running “\(event.title ?? "")” at \(event.displayTime)", category: .general)
                _ = await build(event, refreshedBeforeCall: false)
                continue
            }
            guard !entry.refreshedBeforeCall,
                  event.startDate.timeIntervalSince(.now) <= Self.preCallLead else { continue }
            if Date.now.timeIntervalSince(entry.generatedAt) < Self.refreshMinAge {
                entries[key]?.refreshedBeforeCall = true
                save()
                continue
            }
            LogManager.send("Prep: refreshing “\(event.title ?? "")” before its \(event.displayTime) start", category: .general)
            _ = await build(event, refreshedBeforeCall: true)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            // A cache: rebuilding costs one search and a Haiku call per meeting.
            LogManager.send("Prep: cache unreadable, starting fresh — \(error.localizedDescription)", category: .general, level: .warning)
            entries = [:]
        }
        prune()
    }

    private func save() {
        prune()
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            LogManager.send("Prep: couldn't save cache — \(error.localizedDescription)", category: .general, level: .warning)
        }
    }

    /// Yesterday's meetings are done; nothing reads their prep again.
    private func prune() {
        let cutoff = Calendar.current.startOfDay(for: .now).addingTimeInterval(-86_400)
        entries = entries.filter { $0.value.startDate >= cutoff }
    }
}
