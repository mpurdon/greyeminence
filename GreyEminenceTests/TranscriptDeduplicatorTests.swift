import SwiftData
import XCTest
@testable import Grey_Eminence

/// Speaker bleed: the microphone hears the far side through the speakers,
/// and Whisper writes it down as if the user said it. Whole-line echoes are
/// caught by similarity; these pin the fragment case, where the mic line is
/// a short piece of a long system line.
@MainActor
final class TranscriptDeduplicatorTests: XCTestCase {

    private func segment(_ speaker: Speaker, _ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, text: text, startTime: start, endTime: end, isFinal: true)
    }

    private let geneLine = "Like every, it seemed like everybody in Anthropic, like their titles, member of technical staff,"

    /// The exact shape from the 2026-09-10 report: one system line, four mic
    /// fragments over the following seconds, none of which Dice could see.
    func testFragmentsOfOneSystemLineAreAllRemoved() {
        let gene = segment(.other("Gene Huh"), geneLine, 232, 238)
        let fragments = [
            segment(.me, "it seems like everybody", 233, 234),
            segment(.me, "in Anthropic", 234, 235),
            segment(.me, "like their title", 236, 236.8),
            segment(.me, "member of technical staff", 236.9, 238),
        ]
        let result = TranscriptDeduplicator.deduplicate([gene] + fragments)
        XCTAssertEqual(result.removedCount, 4)
        XCTAssertEqual(result.segments.map(\.text), [geneLine])
    }

    func testDiceAloneCannotSeeAFragment() {
        // Documents why containment exists: the old metric on the same pair.
        XCTAssertLessThan(TranscriptDeduplicator.textSimilarity("in Anthropic", geneLine), 0.45)
        XCTAssertGreaterThanOrEqual(TranscriptDeduplicator.fragmentContainment("in Anthropic", in: geneLine), 0.9)
    }

    func testAFragmentEchoedFromTheTailOfALongLineIsCaught() {
        // 25 s of the far side talking; the echo of its last words starts
        // 20 s after the line did, beyond the old start-to-start cap.
        let long = segment(.other("Ann"), "the first part of a long explanation " + String(repeating: "and more detail ", count: 8) + "member of technical staff", 100, 125)
        let tail = segment(.me, "member of technical staff", 121, 122)
        let result = TranscriptDeduplicator.deduplicate([long, tail])
        XCTAssertEqual(result.removedCount, 1)
    }

    /// A one-word or very short line is in every meeting; it is never evidence.
    func testTooShortFragmentsAreNeverDuplicates() {
        let gene = segment(.other("Gene Huh"), "Yeah, okay, I think so too.", 10, 12)
        let mine = [segment(.me, "yeah", 11, 11.4), segment(.me, "okay", 11.5, 11.9), segment(.me, "I think", 11.9, 12.2)]
        let result = TranscriptDeduplicator.deduplicate([gene] + mine)
        XCTAssertEqual(result.removedCount, 0)
    }

    /// The user genuinely saying something *after* the other person finished
    /// and the echo window closed must survive, however similar the words.
    func testAMatchingPhraseOutsideTheEchoWindowIsKept() {
        let gene = segment(.other("Gene Huh"), "We should look at the intake flow together.", 10, 13)
        let mine = segment(.me, "look at the intake flow", 25, 26.5)  // 12 s after Gene finished
        let result = TranscriptDeduplicator.deduplicate([gene, mine])
        XCTAssertEqual(result.removedCount, 0)
    }

    func testFragmentContainmentIgnoresLinesThatAreNotLonger() {
        // Same length is Dice's job; containment stays out of it.
        XCTAssertEqual(TranscriptDeduplicator.fragmentContainment("member of staff", in: "member of staff"), 0)
    }

    func testWholeLineEchoStillCaughtBySimilarity() {
        let gene = segment(.other("Gene Huh"), "We should probably ship the feature flag first.", 10, 13)
        let echo = segment(.me, "We should probably ship the feature flag first", 11, 14)
        XCTAssertEqual(TranscriptDeduplicator.deduplicate([gene, echo]).removedCount, 1)
    }
}
