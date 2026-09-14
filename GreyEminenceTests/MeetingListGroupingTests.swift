import XCTest
import SwiftData
@testable import Grey_Eminence

/// Month sections are ordered by date, not by header text. Sorting the labels
/// as strings put "June 2026" above "July 2026" ('n' > 'l'), which pushed a
/// whole month of meetings below an older section where they read as missing.
@MainActor
final class MeetingListGroupingTests: XCTestCase {

    /// Built per test rather than in `setUp` — the context is MainActor-bound
    /// and `setUpWithError` is not.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// Fixed reference point so bucketing never depends on the wall clock or
    /// on the runner's time zone.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func makeMeeting(
        _ date: Date,
        title: String = "Meeting",
        in context: ModelContext
    ) -> Meeting {
        let meeting = Meeting(title: title)
        meeting.date = date
        context.insert(meeting)
        return meeting
    }

    private func sections(_ meetings: [Meeting], now: Date) -> [String] {
        MeetingListView.groupSections(for: meetings, now: now, calendar: calendar)
            .map(\.0)
    }

    func testJulySortsAboveJune() throws {
        let context = try makeContext()
        let now = date(2026, 8, 3)
        let meetings = [
            makeMeeting(date(2026, 6, 16), in: context),
            makeMeeting(date(2026, 7, 17), in: context),
        ]

        XCTAssertEqual(sections(meetings, now: now), ["July 2026", "June 2026"])
    }

    /// The same defect in the other direction: "January" beats "February"
    /// alphabetically, so a string sort inverted them too.
    func testFebruarySortsAboveJanuary() throws {
        let context = try makeContext()
        let now = date(2026, 4, 10)
        let meetings = [
            makeMeeting(date(2026, 1, 5), in: context),
            makeMeeting(date(2026, 2, 5), in: context),
        ]

        XCTAssertEqual(sections(meetings, now: now), ["February 2026", "January 2026"])
    }

    func testRelativeSectionsPrecedeMonthSections() throws {
        let context = try makeContext()
        let now = date(2026, 8, 3)
        let meetings = [
            makeMeeting(date(2026, 6, 16), in: context),
            makeMeeting(date(2026, 7, 17), in: context),
            makeMeeting(date(2026, 8, 3), in: context),
            makeMeeting(date(2026, 8, 2), in: context),
        ]

        XCTAssertEqual(
            sections(meetings, now: now),
            ["Today", "Yesterday", "July 2026", "June 2026"]
        )
    }

    func testMonthSectionsOrderAcrossYearBoundary() throws {
        let context = try makeContext()
        let now = date(2026, 3, 1)
        let meetings = [
            makeMeeting(date(2025, 12, 10), in: context),
            makeMeeting(date(2026, 1, 10), in: context),
        ]

        XCTAssertEqual(sections(meetings, now: now), ["January 2026", "December 2025"])
    }

    func testMeetingsStayWithinTheirSection() throws {
        let context = try makeContext()
        let now = date(2026, 8, 3)
        let june = makeMeeting(date(2026, 6, 16), title: "June call", in: context)
        let july = makeMeeting(date(2026, 7, 17), title: "July call", in: context)

        let grouped = MeetingListView.groupSections(
            for: [june, july], now: now, calendar: calendar
        )

        XCTAssertEqual(grouped.first?.1.map(\.title), ["July call"])
        XCTAssertEqual(grouped.last?.1.map(\.title), ["June call"])
    }

    // MARK: - Pinned

    func testPinnedMeetingsLeadInTheirOwnSectionAndLeaveTheirDateBucket() throws {
        let context = try makeContext()
        let now = date(2026, 9, 14)
        let today = makeMeeting(now, title: "today", in: context)
        let pinnedOld = makeMeeting(date(2026, 6, 2), title: "old but pinned", in: context)
        pinnedOld.isPinned = true
        let pinnedToday = makeMeeting(now, title: "today, pinned", in: context)
        pinnedToday.isPinned = true

        let sections = MeetingListView.groupSections(for: [today, pinnedOld, pinnedToday], now: now, calendar: calendar)

        XCTAssertEqual(sections.first?.0, MeetingListView.pinnedSectionTitle)
        XCTAssertEqual(sections.first?.1.map(\.title), ["today, pinned", "old but pinned"], "newest pinned first")
        XCTAssertEqual(sections.dropFirst().first?.0, "Today")
        XCTAssertEqual(sections.dropFirst().first?.1.map(\.title), ["today"], "a pinned meeting is not listed twice")
        XCTAssertFalse(sections.contains { $0.0 == "June 2026" }, "its month section is not created for it")
    }

    func testNoPinnedSectionWhenNothingIsPinned() throws {
        let context = try makeContext()
        let now = date(2026, 9, 14)
        let sections = MeetingListView.groupSections(for: [makeMeeting(now, in: context)], now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.0), ["Today"])
    }

    // MARK: - Pin prompt

    func testPinPromptAsksOnceAndNeverForInterviews() {
        XCTAssertTrue(MeetingPinPrompt.shouldAsk(isInterview: false, hasSeen: false))
        XCTAssertFalse(MeetingPinPrompt.shouldAsk(isInterview: false, hasSeen: true))
        XCTAssertFalse(MeetingPinPrompt.shouldAsk(isInterview: true, hasSeen: false))
    }
}
