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

// MARK: - Loudness

/// The far side through the speakers is quiet on the microphone; the user
/// is loud. Once a baseline for the user's voice exists, a quiet mic line
/// needs only a resemblance to a system line to be a duplicate, and a quiet
/// line with no match at all — spoken while the far side was talking — is
/// relabelled rather than credited to the user.
@MainActor
final class TranscriptDeduplicatorLoudnessTests: XCTestCase {

    private func mic(_ text: String, _ start: TimeInterval, _ end: TimeInterval, level: Float) -> TranscriptSegment {
        let s = TranscriptSegment(speaker: .me, text: text, startTime: start, endTime: end, isFinal: true)
        s.micLevel = level
        return s
    }
    private func sys(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(speaker: .other("Gene Huh"), text: text, startTime: start, endTime: end, isFinal: true)
    }

    /// Five clearly-the-user lines at ~0.08 RMS, nowhere near the far side.
    private func userLines() -> [TranscriptSegment] {
        var lines: [TranscriptSegment] = []
        for i in 0..<5 {
            let start = TimeInterval(1000 + i * 40)
            lines.append(mic("This is me talking about the plan number \(i).", start, start + 10, level: 0.08))
        }
        return lines
    }

    func testBaselineComesFromLinesWithNothingOnTheFarSide() {
        let users = userLines()
        let far = sys("A completely different sentence from the far side.", 100, 105)
        let quietEcho = mic("completely different sentence", 101, 102, level: 0.02)
        let all = users + [far, quietEcho]
        let sorted = all.filter { !$0.speaker.isMe }
        let baseline = TranscriptDeduplicator.userLevelBaseline(
            micSegments: all.filter(\.speaker.isMe), systemSegments: sorted,
            sysMids: sorted.map { ($0.startTime + $0.endTime) / 2 }
        )
        XCTAssertEqual(baseline ?? 0, 0.08, accuracy: 0.001, "the echo near the far side must not drag the baseline down")
    }

    func testAQuietLineNeedsOnlyAResemblanceToBeADuplicate() {
        let far = sys("We should look at the intake flow together next week.", 100, 104)
        // Whisper heard the echo badly: Dice 0.42, containment 0.57 — under
        // the loud bars (0.45 / 0.7), over the quiet ones (0.25 / 0.5).
        let echo = mic("the intake and outtake tomorrow", 101, 103, level: 0.02)
        let loudSame = mic("the intake and outtake tomorrow", 101, 103, level: 0.09)
        let withQuiet = TranscriptDeduplicator.deduplicate(userLines() + [far, echo])
        XCTAssertEqual(withQuiet.removedCount, 1)
        let withLoud = TranscriptDeduplicator.deduplicate(userLines() + [far, loudSame])
        XCTAssertEqual(withLoud.removedCount, 0, "the same words at the user's own loudness are the user")
    }

    func testAQuietUnmatchedLineDuringFarSideSpeechIsReattributedNotDeleted() {
        let far = sys("Something the system track heard as noise.", 100, 106)
        let bleed = mic("the model distillation step is what worries me", 102, 104, level: 0.015)
        let result = TranscriptDeduplicator.deduplicate(userLines() + [far, bleed])
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.reassignedCount, 1)
        XCTAssertEqual(bleed.speaker, .unidentified)
        XCTAssertNotNil(bleed.originalSpeakerData, "reversible, like a speaker repair")
        XCTAssertFalse(bleed.isEdited, "a machine relabel is not the user's edit")
        XCTAssertTrue(result.segments.contains { $0.id == bleed.id }, "still in the transcript")
    }

    func testAQuietLineWithNobodyOnTheFarSideStaysTheUsers() {
        // Talking softly to yourself with nobody else speaking is not bleed.
        let soft = mic("hmm let me think about that for a second", 500, 503, level: 0.015)
        let result = TranscriptDeduplicator.deduplicate(userLines() + [soft])
        XCTAssertEqual(result.reassignedCount, 0)
        XCTAssertEqual(soft.speaker, .me)
    }

    func testWithoutABaselineLoudnessIsIgnored() {
        // Two levelled lines cannot make a baseline; behaviour is the old one.
        let far = sys("We should look at the intake flow together next week.", 100, 104)
        let echo = mic("the intake and outtake tomorrow", 101, 103, level: 0.02)
        let one = mic("Just one other line from me.", 900, 903, level: 0.08)
        let result = TranscriptDeduplicator.deduplicate([far, echo, one])
        XCTAssertNil(result.userLevelBaseline)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.reassignedCount, 0)
    }

    func testLevelFromSamplesClampsToTheAudio() {
        let samples = [Float](repeating: 0.5, count: 16000)  // one second
        XCTAssertEqual(HighQualityTranscriber.level(of: samples, from: 0, to: 1), 0.5, accuracy: 0.001)
        XCTAssertEqual(HighQualityTranscriber.level(of: samples, from: 0.5, to: 3), 0.5, accuracy: 0.001, "end past the audio is clamped")
        XCTAssertEqual(HighQualityTranscriber.level(of: samples, from: 2, to: 3), 0)
    }
}
