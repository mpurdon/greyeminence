import XCTest
@testable import Grey_Eminence

/// Re-checking cluster assignments once every voice is known. The bias is
/// toward leaving a turn where the diarizer put it: a move needs a clear match
/// to the other voice and a clear mismatch with its own.
final class HindsightReassignmentTests: XCTestCase {

    private func turn(_ id: String, _ embedding: [Float], from start: TimeInterval, seconds: TimeInterval = 5) -> DiarizedSegment {
        DiarizedSegment(
            speaker: .other("Speaker \(id)"),
            startTime: start,
            endTime: start + seconds,
            confidence: 1,
            speakerID: id,
            embedding: embedding
        )
    }

    /// Two established voices along different axes, plus one turn under test.
    private func meeting(with probe: DiarizedSegment) -> [DiarizedSegment] {
        (0..<6).map { turn("carlos", [1, 0, 0], from: Double($0) * 10) }
            + (0..<6).map { turn("paras", [0, 1, 0], from: 100 + Double($0) * 10) }
            + [probe]
    }

    func testOpeningTurnOfANewVoiceMovesToThatVoice() {
        // Paras's first sentence, filed under Carlos because Paras's cluster
        // did not exist yet. It sounds like Paras.
        let probe = turn("carlos", [0.1, 0.99, 0], from: 50, seconds: 9)
        let result = HindsightReassignment.apply(to: meeting(with: probe), among: ["carlos", "paras"])
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.movedSeconds, 9, accuracy: 0.001)
        XCTAssertEqual(result.turns.last?.speakerID, "paras")
        XCTAssertEqual(result.turns.last?.speaker, .other("Speaker paras"), "carries the destination's label")
        XCTAssertEqual(result.turns.last?.startTime, 50, "timing and embedding are untouched")
    }

    func testTurnThatMatchesItsOwnVoiceStays() {
        let probe = turn("carlos", [0.95, 0.3, 0], from: 50)
        let result = HindsightReassignment.apply(to: meeting(with: probe), among: ["carlos", "paras"])
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.turns.last?.speakerID, "carlos")
    }

    func testAmbiguousTurnIsNotMoved() {
        // Halfway between the two: a better match, but not a clear one.
        let probe = turn("carlos", [0.68, 0.73, 0], from: 50)
        let result = HindsightReassignment.apply(to: meeting(with: probe), among: ["carlos", "paras"])
        XCTAssertEqual(result.moved, 0, "margin under the floor must not move")
    }

    func testWeakMatchToAnotherVoiceIsNotMoved() {
        // Fits nobody well. Clearly not Carlos, but not clearly Paras either;
        // moving it would be trading one guess for another.
        let probe = turn("carlos", [0.1, 0.4, 0.9], from: 50)
        let result = HindsightReassignment.apply(to: meeting(with: probe), among: ["carlos", "paras"])
        XCTAssertEqual(result.moved, 0)
    }

    func testShortTurnIsNotReJudged() {
        // A one-word interjection's embedding is noise; leave it.
        let probe = turn("carlos", [0, 1, 0], from: 50, seconds: 1.5)
        let result = HindsightReassignment.apply(to: meeting(with: probe), among: ["carlos", "paras"])
        XCTAssertEqual(result.moved, 0)
    }

    func testSliverTurnsCanMoveToARealVoice() {
        // A cluster below the participant floor is not a destination, but its
        // turns are the likeliest to belong to someone who is.
        let probe = turn("blip", [0, 1, 0], from: 50)
        let result = HindsightReassignment.apply(to: meeting(with: probe), among: ["carlos", "paras"])
        XCTAssertEqual(result.turns.last?.speakerID, "paras")
    }

    func testNothingMovesOntoASliver() {
        // The floor just removed this voice; hindsight must not bring it back.
        let sliver = turn("blip", [0, 0, 1], from: 200, seconds: 3)
        let probe = turn("carlos", [0, 0, 1], from: 50)
        let result = HindsightReassignment.apply(to: meeting(with: sliver) + [probe], among: ["carlos", "paras"])
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.turns.last?.speakerID, "carlos")
    }

    func testTurnsWithoutEmbeddingsAreLeftAlone() {
        let probe = DiarizedSegment(speaker: .other("Speaker carlos"), startTime: 50, endTime: 55, confidence: 1, speakerID: "carlos", embedding: [])
        let result = HindsightReassignment.apply(to: meeting(with: probe), among: ["carlos", "paras"])
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.turns.count, 13)
    }

    func testEmptyInputIsANoOp() {
        let result = HindsightReassignment.apply(to: [], among: ["a"])
        XCTAssertTrue(result.turns.isEmpty)
        XCTAssertEqual(result.moved, 0)
    }
}
