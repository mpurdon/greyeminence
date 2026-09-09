import XCTest
@testable import Grey_Eminence

/// The correction pass may change a few misheard words and nothing else.
/// These pin the prompt rendering, the response parsing, and the guard
/// that decides whether a proposed change is a fix or a rewrite.
final class TranscriptCorrectionTests: XCTestCase {

    private func line(_ index: Int, _ text: String, confidence: Float = 0.8, edited: Bool = false) -> TranscriptCorrectionService.Line {
        .init(index: index, speaker: "Ann", text: text, confidence: confidence, isUserEdited: edited)
    }

    // MARK: - Rendering

    func testLinesAreOneBasedAndLowConfidenceIsFlagged() {
        let rendered = TranscriptCorrectionService.renderLines([
            line(0, "Fine line."),
            line(1, "Mumbled line.", confidence: 0.3),
        ])
        XCTAssertEqual(rendered, "L1 [Ann] Fine line.\nL2 [Ann] (low confidence) Mumbled line.")
    }

    // MARK: - Parsing

    func testParsesCorrectionsWithPrefixedAndBareLineNumbers() throws {
        let response = """
        Here you go:
        ```json
        {"corrections":[{"line":"L12","text":"software engineering"},{"line":"3","text":"Cadence"}]}
        ```
        """
        let parsed = try XCTUnwrap(TranscriptCorrectionService.parse(response: response))
        XCTAssertEqual(parsed, [.init(index: 11, text: "software engineering"), .init(index: 2, text: "Cadence")])
    }

    func testEmptyListAndGarbage() {
        XCTAssertEqual(TranscriptCorrectionService.parse(response: "{\"corrections\":[]}"), [])
        XCTAssertNil(TranscriptCorrectionService.parse(response: "no json here"))
    }

    // MARK: - The guard

    func testAMisheardPhraseIsAccepted() {
        let original = "You did blue collar work before you got into suffering. I didn't know that."
        let fixed = "You did blue collar work before you got into software engineering. I didn't know that."
        XCTAssertTrue(TranscriptCorrectionService.decision(original: original, corrected: fixed, isUserEdited: false))
    }

    func testARewriteIsRejected() {
        let original = "Um so yeah I think we should probably look at the intake flow next week maybe."
        let rewrite = "We should review the intake flow next week."
        XCTAssertFalse(TranscriptCorrectionService.decision(original: original, corrected: rewrite, isUserEdited: false))
    }

    func testIdenticalEmptyAndUserEditedLinesAreLeftAlone() {
        XCTAssertFalse(TranscriptCorrectionService.decision(original: "Same.", corrected: " Same. ", isUserEdited: false))
        XCTAssertFalse(TranscriptCorrectionService.decision(original: "Words.", corrected: "", isUserEdited: false))
        XCTAssertFalse(TranscriptCorrectionService.decision(original: "got into suffering", corrected: "got into software engineering", isUserEdited: true))
    }

    func testChangedFractionCountsWordsNotCharacters() {
        XCTAssertEqual(TranscriptCorrectionService.changedFraction(from: "got into suffering", to: "got into software engineering"), 0.5, accuracy: 0.001)
        XCTAssertEqual(TranscriptCorrectionService.changedFraction(from: "a b c d", to: "a b c d"), 0, accuracy: 0.001)
        XCTAssertEqual(TranscriptCorrectionService.changedFraction(from: "a b", to: "x y"), 1, accuracy: 0.001)
    }

    // MARK: - Whisper side

    func testConfidenceIsTheAverageTokenProbability() {
        XCTAssertEqual(HighQualityTranscriber.confidence(fromAvgLogprob: 0), 1, accuracy: 0.001)
        XCTAssertEqual(HighQualityTranscriber.confidence(fromAvgLogprob: -1), 0.368, accuracy: 0.001)
        XCTAssertEqual(HighQualityTranscriber.confidence(fromAvgLogprob: -.infinity), 1, "unknown reads as confident, never as a warning")
    }

    func testPromptTextIsProseWithDeduplicatedNouns() {
        let prompt = HighQualityTranscriber.promptText(
            title: "OL efficiency",
            participants: ["Teancum Besendorfer", "Me", "teancum besendorfer"],
            vocabulary: ["Cadence", "CarePatron", " "],
            topics: ["software engineering", "cadence"]
        )
        XCTAssertEqual(prompt, "Meeting: OL efficiency. With Teancum Besendorfer, Me. Terms: Cadence, CarePatron. Topics: software engineering, cadence.")
    }

    /// The prompt is built and logged but must not reach the decoder while
    /// prompting is disabled: with it on, WhisperKit 0.9 returned ~1% of a
    /// meeting's words.
    func testPromptingIsDisabledAndDecodingOptionsStayDefault() {
        XCTAssertFalse(HighQualityTranscriber.promptingEnabled)
        let options = HighQualityTranscriber.decodingOptions(promptText: "Meeting: anything.", tokenizer: nil)
        XCTAssertNil(options.promptTokens)
    }

    func testAThinRetranscriptionIsRejectedButShortOriginalsAreNot() {
        XCTAssertTrue(HighQualityTranscriber.isImplausiblyThin(newWords: 349, existingWords: 17_000), "19 segments for two hours")
        XCTAssertFalse(HighQualityTranscriber.isImplausiblyThin(newWords: 12_000, existingWords: 17_000), "a normal pass loses some filler")
        XCTAssertFalse(HighQualityTranscriber.isImplausiblyThin(newWords: 5, existingWords: 40), "a 45-second recording has nothing to protect")
        XCTAssertFalse(HighQualityTranscriber.isImplausiblyThin(newWords: 0, existingWords: 0))
    }

    func testPromptTextIsEmptyWhenThereIsNothingToSay() {
        XCTAssertEqual(HighQualityTranscriber.promptText(title: " ", participants: [], vocabulary: [], topics: []), "")
    }

    func testOldCheckpointsDecodeAsFullyConfident() throws {
        let json = """
        {"source":"mic","text":"hello","startTime":1,"endTime":2}
        """.data(using: .utf8)!
        let persisted = try JSONDecoder().decode(ReProcessingCheckpoint.PersistedSegment.self, from: json)
        XCTAssertEqual(persisted.toSegment().confidence, 1)
    }
}
