import XCTest
@testable import Grey_Eminence

/// Joining diarization onto transcript text. This is the step re-processing
/// skipped entirely, collapsing every non-microphone voice into one anonymous
/// "Speaker" across 359 meetings.
final class SpeakerAlignmentTests: XCTestCase {
    private typealias Span = SpeakerAlignment.Span

    private let spans = [
        Span(speakerID: "a", start: 0, end: 10),
        Span(speakerID: "b", start: 10, end: 20),
        Span(speakerID: "a", start: 20, end: 24),
    ]

    // MARK: - Choosing a speaker

    func testSegmentFullyInsideOneTurn() {
        XCTAssertEqual(SpeakerAlignment.dominantSpeakerID(from: 2, to: 5, in: spans), "a")
        XCTAssertEqual(SpeakerAlignment.dominantSpeakerID(from: 12, to: 18, in: spans), "b")
    }

    func testStraddlingSegmentGoesToWhoeverHoldsMostOfIt() {
        // 8→14: 2s of "a", 4s of "b". A first-match rule would say "a".
        XCTAssertEqual(SpeakerAlignment.dominantSpeakerID(from: 8, to: 14, in: spans), "b")
    }

    func testOverlapIsSummedAcrossSeparateTurnsBySameSpeaker() {
        // 5→22: "a" holds 5s + 2s = 7s, "b" holds 10s.
        XCTAssertEqual(SpeakerAlignment.dominantSpeakerID(from: 5, to: 22, in: spans), "b")
        // 18→24: "b" holds 2s, "a" holds 4s.
        XCTAssertEqual(SpeakerAlignment.dominantSpeakerID(from: 18, to: 24, in: spans), "a")
    }

    func testNoOverlapReturnsNilRatherThanGuessing() {
        XCTAssertNil(SpeakerAlignment.dominantSpeakerID(from: 30, to: 40, in: spans))
    }

    func testEmptyDiarizationReturnsNil() {
        XCTAssertNil(SpeakerAlignment.dominantSpeakerID(from: 0, to: 5, in: []))
    }

    func testZeroLengthSegmentReturnsNil() {
        XCTAssertNil(SpeakerAlignment.dominantSpeakerID(from: 5, to: 5, in: spans))
    }

    func testTieIsBrokenDeterministicallyByWhoSpokeFirst() {
        // Exactly 5s each; without a tiebreak this depends on dictionary order.
        let tied = [
            Span(speakerID: "late", start: 10, end: 20),
            Span(speakerID: "early", start: 0, end: 10),
        ]
        for _ in 0..<20 {
            XCTAssertEqual(SpeakerAlignment.dominantSpeakerID(from: 5, to: 15, in: tied), "early")
        }
    }

    func testTouchingButNotOverlappingDoesNotCount() {
        // A turn ending exactly where the segment starts shares no audio.
        let touching = [Span(speakerID: "a", start: 0, end: 10)]
        XCTAssertNil(SpeakerAlignment.dominantSpeakerID(from: 10, to: 15, in: touching))
    }

    // MARK: - Labels

    func testLabelsAreNumberedByWhoSpeaksFirst() {
        let labels = SpeakerAlignment.labels(forSpansOrderedByTime: [
            Span(speakerID: "zzz", start: 30, end: 40),
            Span(speakerID: "aaa", start: 0, end: 10),
            Span(speakerID: "mmm", start: 15, end: 20),
        ])
        XCTAssertEqual(labels["aaa"], "Speaker 1")
        XCTAssertEqual(labels["mmm"], "Speaker 2")
        XCTAssertEqual(labels["zzz"], "Speaker 3")
    }

    func testRepeatedSpeakerKeepsOneLabel() {
        let labels = SpeakerAlignment.labels(forSpansOrderedByTime: spans)
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels["a"], "Speaker 1")
        XCTAssertEqual(labels["b"], "Speaker 2")
    }

    func testEmptyInputProducesNoLabels() {
        XCTAssertTrue(SpeakerAlignment.labels(forSpansOrderedByTime: []).isEmpty)
    }

    // MARK: - Filtering slivers

    func testBriefClustersAreNotTreatedAsParticipants() {
        // A cough or a crossfade shouldn't make a 1:1 look like a panel.
        let withSliver = [
            Span(speakerID: "a", start: 0, end: 60),
            Span(speakerID: "b", start: 60, end: 120),
            Span(speakerID: "blip", start: 62, end: 62.4),
        ]
        let significant = SpeakerAlignment.significantSpeakerIDs(in: withSliver)
        XCTAssertEqual(significant, ["a", "b"])
    }

    func testShortTurnsStillCountWhenTheyAddUp() {
        // Someone who only ever interjects is still a participant, once
        // there's enough of it.
        let interjector = (0..<30).map { Span(speakerID: "c", start: Double($0) * 10, end: Double($0) * 10 + 0.8) }
        XCTAssertTrue(SpeakerAlignment.significantSpeakerIDs(in: interjector).contains("c"))
    }

    func testBackchannelOnlyClusterIsNotAParticipant() {
        // The case that actually happens: a one-word "Yeah." seeds its own
        // cluster and then collects a dozen more. Thirteen seconds of
        // backchannel across a 25-minute 1:1 is not a third person.
        let backchannel = (0..<7).map { Span(speakerID: "yeah", start: 100 + Double($0) * 120, end: 100 + Double($0) * 120 + 1.8) }
        let liran = [Span(speakerID: "a", start: 0, end: 600)]
        XCTAssertEqual(SpeakerAlignment.significantSpeakerIDs(in: liran + backchannel), ["a"])
    }

    func testThresholdIsInclusive() {
        let exact = [Span(speakerID: "x", start: 0, end: SpeakerAlignment.minimumParticipantSeconds)]
        XCTAssertTrue(SpeakerAlignment.significantSpeakerIDs(in: exact).contains("x"))
        let justUnder = [Span(speakerID: "x", start: 0, end: SpeakerAlignment.minimumParticipantSeconds - 0.01)]
        XCTAssertTrue(SpeakerAlignment.significantSpeakerIDs(in: justUnder).isEmpty)
    }
}
