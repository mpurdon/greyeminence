import XCTest
@testable import Grey_Eminence

/// A second call soon after a recorded meeting was auto-linked to that
/// meeting's event — taking its title and attendees — because the event was
/// still within the ±60-minute window.
@MainActor
final class CalendarAutoLinkTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ link: String = "evt", minutes: Double = 45) -> CalendarEvent {
        CalendarEvent(
            id: link + "-occurrence",
            linkIdentifier: link,
            title: "TD Exhibit file analysis",
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            attendees: [],
            isRecurring: true,
            source: .eventKit
        )
    }

    private func meeting(linkedTo link: String?, minutesAfterStart: Double) -> Meeting {
        let meeting = Meeting(title: "Call", status: .completed)
        meeting.date = start.addingTimeInterval(minutesAfterStart * 60)
        meeting.calendarEventID = link
        return meeting
    }

    func testAnOccurrenceWithARecordingIsTaken() {
        let recorded = meeting(linkedTo: "evt", minutesAfterStart: 2)
        XCTAssertTrue(RecordingViewModel.isAlreadyRecorded(event(), by: [recorded], excluding: nil))
    }

    func testTheRecordingBeingLinkedDoesNotCountAgainstItself() {
        let current = meeting(linkedTo: "evt", minutesAfterStart: 2)
        XCTAssertFalse(RecordingViewModel.isAlreadyRecorded(event(), by: [current], excluding: current.id))
    }

    func testLastWeeksOccurrenceOfTheSeriesDoesNotBlockThisOne() {
        let lastWeek = meeting(linkedTo: "evt", minutesAfterStart: -7 * 24 * 60)
        XCTAssertFalse(RecordingViewModel.isAlreadyRecorded(event(), by: [lastWeek], excluding: nil))
    }

    func testOtherEventsAndLateStartsDoNotCount() {
        XCTAssertFalse(RecordingViewModel.isAlreadyRecorded(event(), by: [meeting(linkedTo: "other", minutesAfterStart: 2)], excluding: nil))
        XCTAssertFalse(RecordingViewModel.isAlreadyRecorded(event(), by: [meeting(linkedTo: "evt", minutesAfterStart: 50)], excluding: nil),
                       "started after the event ended: not this occurrence")
        XCTAssertTrue(RecordingViewModel.isAlreadyRecorded(event(), by: [meeting(linkedTo: "evt", minutesAfterStart: -20)], excluding: nil),
                      "joined early still counts")
    }
}
