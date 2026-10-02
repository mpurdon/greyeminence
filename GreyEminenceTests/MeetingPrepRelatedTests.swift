import XCTest
@testable import Grey_Eminence

final class MeetingPrepRelatedTests: XCTestCase {

    // MARK: - Keywords

    func testKeywordsDropMeetingKindWords() {
        XCTAssertEqual(MeetingPrepRelated.keywords(fromTitle: "Cadence Eng Sync"), ["cadence"])
        XCTAssertEqual(MeetingPrepRelated.keywords(fromTitle: "OLP / VAS Weekly Check-in"), ["olp", "vas"])
    }

    func testAllGenericTitleHasNoKeywords() {
        XCTAssertEqual(MeetingPrepRelated.keywords(fromTitle: "Weekly Team Sync"), [])
        XCTAssertEqual(MeetingPrepRelated.keywords(fromTitle: "1:1"), [])
    }

    func testKeywordsDedupeInTitleOrder() {
        XCTAssertEqual(MeetingPrepRelated.keywords(fromTitle: "Cadence: Cadence Migration"), ["cadence", "migration"])
    }

    // MARK: - Selection

    private func result(_ meeting: UUID, _ text: String, title: String = "Some Meeting", daysAgo: Double = 1) -> SearchResult {
        SearchResult(
            id: UUID().uuidString,
            sourceKind: .transcriptSegment,
            sourceID: UUID(),
            meetingID: meeting,
            meetingTitle: title,
            meetingDate: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400),
            text: text,
            score: 1
        )
    }

    func testSelectKeepsOnlyResultsNamingAKeyword() {
        let a = UUID(), b = UUID()
        let groups = MeetingPrepRelated.select(
            results: [
                result(a, "The Cadence rollout slipped a week."),
                result(b, "We should decide the release rhythm."),  // dense near-miss
            ],
            keywords: ["cadence"]
        )
        XCTAssertEqual(groups.map(\.source.meetingID), [a])
    }

    func testSelectMatchesWholeWordsOnly() {
        let groups = MeetingPrepRelated.select(
            results: [result(UUID(), "Vasectomy jokes aside")],
            keywords: ["vas"]
        )
        XCTAssertTrue(groups.isEmpty)
    }

    func testSelectCapsPerMeetingAndOrdersNewestFirst() {
        let older = UUID(), newer = UUID()
        let results = (0..<5).map { result(older, "cadence point \($0)", daysAgo: 10) }
            + [result(newer, "cadence latest", daysAgo: 1)]
        let groups = MeetingPrepRelated.select(results: results, keywords: ["cadence"])
        XCTAssertEqual(groups.map(\.source.meetingID), [newer, older])
        XCTAssertEqual(groups[1].excerpts.count, MeetingPrepRelated.perMeetingCap)
    }

    func testSelectCapsMeetingCountAndHonoursExclusions() {
        let excluded = UUID()
        let results = [result(excluded, "cadence here")]
            + (0..<10).map { _ in result(UUID(), "cadence") }
        let groups = MeetingPrepRelated.select(results: results, keywords: ["cadence"], excludingMeetingIDs: [excluded])
        XCTAssertEqual(groups.count, MeetingPrepRelated.maxMeetings)
        XCTAssertFalse(groups.contains { $0.source.meetingID == excluded })
    }

    // MARK: - Parse

    func testParseMapsMeetingIDsAndDropsUnknown() {
        let response = #"{"points":[{"text":"Rollout slipped.","meetings":["M2","M9","M1"]},{"text":"  ","meetings":["M1"]}]}"#
        let points = MeetingPrepRelated.parse(response: response, sourceCount: 3)
        XCTAssertEqual(points, [RelatedPrep.Point(text: "Rollout slipped.", sourceIndices: [0, 1])])
    }

    func testParseEmptyListMeansNothingSubstantive() {
        XCTAssertEqual(MeetingPrepRelated.parse(response: #"{"points":[]}"#, sourceCount: 2), [])
    }

    func testParseUnreadableIsNil() {
        XCTAssertNil(MeetingPrepRelated.parse(response: "no json here", sourceCount: 2))
    }

    // MARK: - Display gating

    func testOneOffShowsOnlyOnceRelatedContextArrives() {
        var context = MeetingPrepContext(provenance: .notApplicable, unresolvedItems: [], previousTopics: [], followUps: [])
        XCTAssertFalse(context.shouldDisplay)
        context.related = .loading
        XCTAssertFalse(context.shouldDisplay)
        context.related = .ready(RelatedPrep(keywords: ["cadence"], points: [], sources: [], summaryUnavailable: true, generatedAt: .now))
        XCTAssertTrue(context.shouldDisplay)
    }

    // MARK: - Prep meetings earlier the same day

    func testEarlierSameDayMeetingTakesASlotDespiteLowRank() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let prepMeeting = UUID()
        // Six strong older meetings fill the cap by rank; today's prep meeting ranks last.
        var results = (0..<MeetingPrepRelated.maxMeetings).map { _ in result(UUID(), "cadence detail", daysAgo: 5) }
        results.append(SearchResult(
            id: "p", sourceKind: .transcriptSegment, sourceID: UUID(), meetingID: prepMeeting,
            meetingTitle: "Prep", meetingDate: start.addingTimeInterval(-2 * 3600),
            text: "for cadence we should raise the rollout", score: 0.1
        ))
        let groups = MeetingPrepRelated.select(results: results, keywords: ["cadence"], meetingStart: start)
        XCTAssertEqual(groups.count, MeetingPrepRelated.maxMeetings)
        XCTAssertEqual(groups.first?.source.meetingID, prepMeeting)
    }

    func testPromptMarksEarlierTodayMeetings() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let source = RelatedPrep.Source(meetingID: UUID(), title: "Prep", date: start.addingTimeInterval(-3600), excerpt: "")
        let prompt = MeetingPrepRelated.prompt(title: "Cadence Eng Sync", keywords: ["cadence"], groups: [(source, ["x"])], meetingStart: start)
        XCTAssertTrue(prompt.contains("[M1] Prep — "))
        XCTAssertTrue(prompt.contains("(earlier today)"))
    }

    func testPrepWordsAreGeneric() {
        XCTAssertEqual(MeetingPrepRelated.keywords(fromTitle: "Prep for Cadence Sync"), ["cadence"])
    }

    // MARK: - Scheduler eligibility

    private func event(title: String, hours: Double = 0.5, attendees: Int = 2) -> CalendarEvent {
        CalendarEvent(
            id: UUID().uuidString, linkIdentifier: "x", title: title,
            startDate: .now, endDate: .now.addingTimeInterval(hours * 3600),
            attendees: (0..<attendees).map { EventAttendee(name: "P\($0)") },
            isRecurring: false, source: .eventKit
        )
    }

    func testSchedulerSkipsAllDaySoloAndGenericEvents() {
        XCTAssertTrue(MeetingPrepScheduler.isPreppable(event(title: "Cadence Eng Sync")))
        XCTAssertFalse(MeetingPrepScheduler.isPreppable(event(title: "Thanksgiving", hours: 24)))
        XCTAssertFalse(MeetingPrepScheduler.isPreppable(event(title: "Cadence focus", attendees: 0)))
        XCTAssertFalse(MeetingPrepScheduler.isPreppable(event(title: "Weekly Team Sync")))
    }

    func testSchedulerKeyDistinguishesOccurrences() {
        let a = CalendarEvent(id: "same", linkIdentifier: "s", title: "T", startDate: Date(timeIntervalSince1970: 0),
                              endDate: Date(timeIntervalSince1970: 60), attendees: [], isRecurring: true, source: .eventKit)
        let b = CalendarEvent(id: "same", linkIdentifier: "s", title: "T", startDate: Date(timeIntervalSince1970: 86_400),
                              endDate: Date(timeIntervalSince1970: 86_460), attendees: [], isRecurring: true, source: .eventKit)
        XCTAssertNotEqual(MeetingPrepScheduler.key(for: a), MeetingPrepScheduler.key(for: b))
    }
}
