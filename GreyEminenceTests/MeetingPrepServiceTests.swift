import SwiftData
import XCTest
@testable import Grey_Eminence

/// Pure, offline tests for the prep helpers — provenance summary wording,
/// assignee cleaning, and order-preserving dedupe. No SwiftData involved.
final class MeetingPrepServiceTests: XCTestCase {

    // MARK: - History summary

    func testHistorySummarySingleOccurrence() {
        // No date → stable, no locale-dependent string to assert.
        XCTAssertEqual(
            MeetingPrepView.historySummary(count: 1, mostRecent: nil),
            "From the last time you recorded this meeting"
        )
    }

    func testHistorySummaryMultipleOccurrences() {
        XCTAssertEqual(
            MeetingPrepView.historySummary(count: 2, mostRecent: nil),
            "From your last 2 recordings of this meeting"
        )
        XCTAssertEqual(
            MeetingPrepView.historySummary(count: 3, mostRecent: nil),
            "From your last 3 recordings of this meeting"
        )
    }

    func testHistorySummarySingleOccurrenceIncludesDateWhenPresent() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = MeetingPrepView.historySummary(count: 1, mostRecent: date)
        XCTAssertTrue(summary.hasPrefix("From the last time you recorded this meeting · "))
        XCTAssertTrue(summary.count > "From the last time you recorded this meeting · ".count)
    }

    // MARK: - Assignee cleaning (the "Speaker 2" leak)

    func testCleanAssigneeStripsDiarizationPlaceholders() {
        XCTAssertNil(MeetingPrepService.cleanAssignee("Speaker 2"))
        XCTAssertNil(MeetingPrepService.cleanAssignee("speaker 10"))
        XCTAssertNil(MeetingPrepService.cleanAssignee("Unknown"))
        XCTAssertNil(MeetingPrepService.cleanAssignee("Me"))
        XCTAssertNil(MeetingPrepService.cleanAssignee("   "))
        XCTAssertNil(MeetingPrepService.cleanAssignee(nil))
    }

    func testCleanAssigneeKeepsRealNames() {
        XCTAssertEqual(MeetingPrepService.cleanAssignee("Haley"), "Haley")
        XCTAssertEqual(MeetingPrepService.cleanAssignee("  Stephen Smith "), "Stephen Smith")
        // "Speaker" as part of a real title shouldn't be stripped (only the
        // "Speaker N" diarization prefix is).
        XCTAssertEqual(MeetingPrepService.cleanAssignee("Speakerphone Vendor"), "Speakerphone Vendor")
    }

    // MARK: - Order-preserving dedupe

    func testDedupePreservingOrder() {
        XCTAssertEqual(
            MeetingPrepService.dedupePreservingOrder(["a", "b", "a", "c", "b"]),
            ["a", "b", "c"]
        )
    }
}

// MARK: - Status from the prep card

/// Prep is read during the call to remember what to raise, and raising an
/// item is when it gets resolved — so its status must be settable from
/// there, and a "won't do" decision must not come back as unresolved.
@MainActor
final class MeetingPrepStatusTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func recurringEvent(_ id: String) -> CalendarEvent {
        CalendarEvent(
            id: "\(id)-occurrence", linkIdentifier: id, title: "Weekly Sync",
            startDate: .now, endDate: .now.addingTimeInterval(1800),
            attendees: [], isRecurring: true, source: .eventKit
        )
    }

    private func priorOccurrence(of event: CalendarEvent, in context: ModelContext, tasks: [(String, PrepTaskStatus)]) -> Meeting {
        let meeting = Meeting(title: "Weekly Sync", date: .now.addingTimeInterval(-7 * 86_400), status: .completed)
        meeting.calendarEventID = event.linkIdentifier
        context.insert(meeting)
        for (text, status) in tasks {
            let task = ActionItem(text: text)
            status.apply(to: task)
            task.meeting = meeting
            meeting.actionItems.append(task)
        }
        return meeting
    }

    func testDoneAndWontDoItemsAreNotUnresolved() throws {
        let context = try makeContext()
        let event = recurringEvent("series-1")
        _ = priorOccurrence(of: event, in: context, tasks: [
            ("Still open", .pending), ("Finished", .done), ("Dropped", .wontDo),
        ])
        let prep = MeetingPrepService().gatherPrepContext(for: event, in: context)
        XCTAssertEqual(prep.unresolvedItems.map(\.text), ["Still open"])
    }

    func testStatusesMapOntoTheTwoStoredFieldsExclusively() {
        let task = ActionItem(text: "x")
        PrepTaskStatus.done.apply(to: task)
        XCTAssertTrue(task.isCompleted); XCTAssertNil(task.dismissedAt)
        XCTAssertEqual(PrepTaskStatus(task), .done)

        PrepTaskStatus.wontDo.apply(to: task)
        XCTAssertFalse(task.isCompleted); XCTAssertNotNil(task.dismissedAt)
        XCTAssertEqual(PrepTaskStatus(task), .wontDo)

        PrepTaskStatus.pending.apply(to: task)
        XCTAssertFalse(task.isCompleted); XCTAssertNil(task.dismissedAt)
        XCTAssertEqual(PrepTaskStatus(task), .pending)
    }

    /// A task marked done from the card must be the same record the Tasks
    /// screen shows, not a copy.
    func testMarkingDoneFromPrepResolvesTheLiveTask() throws {
        let context = try makeContext()
        let event = recurringEvent("series-2")
        let meeting = priorOccurrence(of: event, in: context, tasks: [("Send the doc", .pending)])
        let prep = MeetingPrepService().gatherPrepContext(for: event, in: context)
        let id = try XCTUnwrap(prep.unresolvedItems.first?.id)

        let live = try XCTUnwrap(meeting.actionItems.first { $0.id == id })
        PrepTaskStatus.done.apply(to: live)

        XCTAssertTrue(try XCTUnwrap(meeting.actionItems.first).isCompleted)
        let again = MeetingPrepService().gatherPrepContext(for: event, in: context)
        XCTAssertTrue(again.unresolvedItems.isEmpty, "gone from the next occurrence's prep")
    }
}
