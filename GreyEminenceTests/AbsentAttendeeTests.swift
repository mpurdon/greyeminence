import SwiftData
import XCTest
@testable import Grey_Eminence

/// An invitee marked "did not attend" stays on the meeting and leaves every
/// roster that feeds the AI: they must not be offered as a speaker, handed an
/// action item, or matched to a voice.
@MainActor
final class AbsentAttendeeTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Meeting.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeMeeting(in context: ModelContext, names: [String]) -> (Meeting, [Contact]) {
        let meeting = Meeting(title: "Sync")
        context.insert(meeting)
        let contacts = names.map { name -> Contact in
            let contact = Contact(name: name)
            context.insert(contact)
            meeting.attendees.append(contact)
            return contact
        }
        return (meeting, contacts)
    }

    func testAbsentInviteeStaysListedButLeavesThePresentRoster() throws {
        let context = try makeContext()
        let (meeting, contacts) = makeMeeting(in: context, names: ["Ann", "Bob", "Cy"])
        meeting.setAbsent(contacts[1], true)

        XCTAssertEqual(meeting.attendees.count, 3, "still invited")
        XCTAssertEqual(Set(meeting.presentAttendees.map(\.name)), ["Ann", "Cy"])
        XCTAssertTrue(meeting.isAbsent(contacts[1]))
        XCTAssertFalse(meeting.isAbsent(contacts[0]))
    }

    func testMarkingIsIdempotentAndReversible() throws {
        let context = try makeContext()
        let (meeting, contacts) = makeMeeting(in: context, names: ["Ann"])
        meeting.setAbsent(contacts[0], true)
        meeting.setAbsent(contacts[0], true)
        XCTAssertEqual(meeting.absentAttendeeIDs.count, 1, "no duplicate IDs")
        meeting.setAbsent(contacts[0], false)
        XCTAssertFalse(meeting.isAbsent(contacts[0]))
        XCTAssertEqual(meeting.presentAttendees.count, 1)
    }

    func testTheAIRosterExcludesAbsentInvitees() throws {
        let context = try makeContext()
        let (meeting, contacts) = makeMeeting(in: context, names: ["Ann", "Bob"])
        meeting.setAbsent(contacts[1], true)
        let roster = MeetingRoster.snapshot(for: meeting)
        XCTAssertEqual(roster.otherAttendees.filter { $0 == "Bob" }, [], "an absentee cannot be assigned an action item")
        XCTAssertTrue(roster.otherAttendees.contains("Ann") || roster.myName == "Ann")
    }

    func testTheCorrectionContextNamesOnlyThoseWhoWereThere() throws {
        let context = try makeContext()
        let (meeting, contacts) = makeMeeting(in: context, names: ["Ann", "Bob"])
        meeting.setAbsent(contacts[0], true)
        let participants = TranscriptCorrectionService.Context.make(for: meeting).participants
        XCTAssertEqual(participants, ["Bob"])
    }

    func testRemovingAnAbsenteeClearsTheirMark() throws {
        let context = try makeContext()
        let (meeting, contacts) = makeMeeting(in: context, names: ["Ann"])
        meeting.setAbsent(contacts[0], true)
        meeting.setAbsent(contacts[0], false)
        meeting.attendees.removeAll { $0.id == contacts[0].id }
        XCTAssertTrue(meeting.absentAttendeeIDs.isEmpty)
        XCTAssertTrue(meeting.presentAttendees.isEmpty)
    }

    func testAbsentTooltipSaysSo() {
        let contact = Contact(name: "Ann Lee")
        XCTAssertEqual(contact.attendeeTooltip(absent: true), "Ann Lee · did not attend")
        XCTAssertEqual(contact.attendeeTooltip(absent: false), "Ann Lee")
    }
}
