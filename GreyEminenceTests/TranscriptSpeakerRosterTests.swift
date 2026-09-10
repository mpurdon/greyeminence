import XCTest
@testable import Grey_Eminence

/// Ordering and tallies for the transcript's speaker filter. The roster is
/// what the user reads while deciding which voice to listen to, so it must
/// be stable across rebuilds and must not lose a quiet speaker.
final class TranscriptSpeakerRosterTests: XCTestCase {

    private let ann = Speaker.other("Ann")
    private let bob = Speaker.other("Bob")
    private let quiet = Speaker.other("Speaker 3")

    func testMeComesFirstThenLongestSpeakerDown() {
        let roster = TranscriptSpeakerRoster.build(speakers: [
            (bob, 300), (ann, 600), (.me, 10), (quiet, 60),
        ])
        XCTAssertEqual(roster.entries.map(\.speaker), [.me, ann, bob, quiet],
                       "the user first, then by speaking time — not by who talked first")
    }

    func testCountsAndSecondsAccumulatePerSpeaker() {
        let roster = TranscriptSpeakerRoster.build(speakers: [
            (ann, 30), (bob, 5), (ann, 45), (ann, 25),
        ])
        let annEntry = roster.entry(for: ann)
        XCTAssertEqual(annEntry?.segmentCount, 3)
        XCTAssertEqual(annEntry?.seconds, 100)
        XCTAssertEqual(roster.entry(for: bob)?.segmentCount, 1)
    }

    /// The case that prompted this: one minute inside a two-hour call must
    /// still be listed, and reachable.
    func testAQuietVoiceInALongCallIsStillListed() {
        var speakers: [(Speaker, TimeInterval)] = (0..<400).map { _ in (ann, 18) }
        speakers.append((quiet, 60))
        let roster = TranscriptSpeakerRoster.build(speakers: speakers)
        XCTAssertEqual(roster.entries.count, 2)
        XCTAssertEqual(roster.entry(for: quiet)?.durationLabel, "1m")
        XCTAssertTrue(roster.entry(for: quiet)?.isUnidentified == true)
    }

    func testOrderIsStableForEqualSpeakingTime() {
        let first = TranscriptSpeakerRoster.build(speakers: [(bob, 100), (ann, 100)])
        let again = TranscriptSpeakerRoster.build(speakers: [(bob, 100), (ann, 100)])
        XCTAssertEqual(first.entries.map(\.speaker), [bob, ann], "ties break on first appearance")
        XCTAssertEqual(first, again)
    }

    func testNegativeDurationsCannotSwampTheOrdering() {
        let roster = TranscriptSpeakerRoster.build(speakers: [(ann, -5000), (bob, 10)])
        XCTAssertEqual(roster.entries.map(\.speaker), [bob, ann])
        XCTAssertEqual(roster.entry(for: ann)?.seconds, 0)
    }

    func testFilteringIsOfferedOnlyWhenThereIsAChoice() {
        XCTAssertFalse(TranscriptSpeakerRoster.build(speakers: []).isFilterable)
        XCTAssertFalse(TranscriptSpeakerRoster.build(speakers: [(.me, 30), (.me, 20)]).isFilterable)
        XCTAssertTrue(TranscriptSpeakerRoster.build(speakers: [(.me, 30), (ann, 20)]).isFilterable)
    }

    func testDurationLabelSwitchesFromSecondsToMinutes() {
        XCTAssertEqual(TranscriptSpeakerRoster.build(speakers: [(ann, 45)]).entries[0].durationLabel, "45s")
        XCTAssertEqual(TranscriptSpeakerRoster.build(speakers: [(ann, 59)]).entries[0].durationLabel, "59s")
        XCTAssertEqual(TranscriptSpeakerRoster.build(speakers: [(ann, 200)]).entries[0].durationLabel, "3m")
    }
}
