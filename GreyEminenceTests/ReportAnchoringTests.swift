import XCTest
@testable import Grey_Eminence

/// Pure tests for figure anchoring: response parsing (which must survive
/// everything a model actually does) and placement (which must never lose or
/// duplicate a screenshot).
final class ReportAnchoringTests: XCTestCase {

    // MARK: - Fixtures

    private let sections = [
        ReportComposerService.SectionOutline(index: 0, title: "Migration plan", pointLabels: ["Schema", "Cutover"]),
        ReportComposerService.SectionOutline(index: 1, title: "Q3 risks", pointLabels: ["Capacity"]),
    ]

    private func candidates(_ count: Int) -> [ReportComposerService.FrameCandidate] {
        (1...count).map {
            .init(
                id: UUID(),
                formattedTimestamp: "\($0):00",
                observation: "Observation \($0)",
                contentType: "slide",
                entities: ["Postgres"]
            )
        }
    }

    private func figure(_ id: UUID, at time: TimeInterval, caption: String = "original") -> ReportModel.Figure {
        .init(
            id: id,
            timestamp: time,
            formattedTimestamp: ReportModelBuilder.timestampLabel(time),
            caption: caption,
            imageData: Data([0xFF, 0xD8]),
            windowTitle: nil
        )
    }

    private func report(figures: [ReportModel.Figure]) -> ReportModel {
        ReportModel(
            meta: .init(
                title: "Braintrust", date: .init(timeIntervalSince1970: 0), duration: "30m",
                attendees: [], sourceApp: nil, generatedAt: .init(timeIntervalSince1970: 0)
            ),
            sections: [
                .init(id: 0, title: "Migration plan", intro: nil, points: [], figures: []),
                .init(id: 1, title: "Q3 risks", intro: nil, points: [], figures: []),
            ],
            actionItems: [], followUpQuestions: [], topics: [],
            shareSessions: [
                .init(
                    id: UUID(), windowTitle: "Keynote", startLabel: "0:00", endLabel: "9:00",
                    narrative: "A walkthrough.", keyMoments: [], figures: figures
                )
            ],
            transcript: []
        )
    }

    private func plan(_ anchors: [ReportAnchorPlan.Anchor], insight: UUID = UUID()) -> ReportAnchorPlan {
        .init(
            version: ReportAnchorPlan.currentVersion,
            insightID: insight,
            anchors: anchors,
            createdAt: .init(timeIntervalSince1970: 0),
            modelIdentifier: "test"
        )
    }

    // MARK: - Parsing

    func testParsesCleanResponse() {
        let frames = candidates(3)
        let parsed = ReportComposerService.parse(
            response: #"{"anchors":[{"section":"S1","frame":"F2","caption":"burndown"}]}"#,
            sections: sections,
            frames: frames
        )
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.sectionIndex, 1)
        XCTAssertEqual(parsed?.first?.frameID, frames[1].id, "F2 must map to the second frame, not the third")
        XCTAssertEqual(parsed?.first?.caption, "burndown")
    }

    /// Models wrap JSON in prose and markdown fences however firmly they are
    /// told not to.
    func testParsesJSONWrappedInProseAndFences() {
        let frames = candidates(2)
        let response = """
        Sure! Here are the anchors:
        ```json
        {"anchors":[{"section":"S0","frame":"F1","caption":"schema diff"}]}
        ```
        Let me know if you'd like changes.
        """
        XCTAssertEqual(
            ReportComposerService.parse(response: response, sections: sections, frames: frames)?.count,
            1
        )
    }

    /// A brace inside a caption must not terminate the object early.
    func testExtractionIgnoresBracesInsideStrings() {
        let json = #"{"anchors":[{"section":"S0","frame":"F1","caption":"the {} operator"}]}"#
        XCTAssertEqual(ReportComposerService.extractJSONObject(from: "noise " + json + " trailing"), json)
    }

    /// A hallucinated *frame* is meaningless and the entry goes; a
    /// hallucinated *section* only costs the anchoring, because the caption
    /// is still worth printing. Either way one bad entry never fails the run.
    func testOutOfRangeIdentifiersDegradeRatherThanFail() {
        let frames = candidates(2)
        let parsed = ReportComposerService.parse(
            response: """
            {"figures":[
              {"section":"S9","frame":"F1","caption":"bad section"},
              {"section":"S0","frame":"F99","caption":"bad frame"},
              {"section":"S0","frame":"F0","caption":"frames are 1-based"},
              {"section":"S1","frame":"F2","caption":"good"}
            ]}
            """,
            sections: sections,
            frames: frames
        )
        XCTAssertEqual(parsed?.count, 2, "entries naming no real frame should go; the rest should not")
        XCTAssertEqual(parsed?.first?.caption, "bad section")
        XCTAssertNil(parsed?.first?.sectionIndex, "an unknown section must not anchor")
        XCTAssertEqual(parsed?.last?.sectionIndex, 1)
    }

    /// Every screenshot gets a caption; only some get a section. An entry
    /// with a null section must survive as a caption rather than be dropped.
    func testUnanchoredEntriesStillProduceCaptions() {
        let frames = candidates(3)
        let parsed = ReportComposerService.parse(
            response: """
            {"figures":[
              {"frame":"F1","section":"S0","caption":"schema diff"},
              {"frame":"F2","section":null,"caption":"the agenda slide"},
              {"frame":"F3","caption":"a burndown chart"}
            ]}
            """,
            sections: sections,
            frames: frames
        )
        XCTAssertEqual(parsed?.count, 3)
        XCTAssertEqual(parsed?[0].sectionIndex, 0)
        XCTAssertNil(parsed?[1].sectionIndex, "a null section must not become an anchor")
        XCTAssertNil(parsed?[2].sectionIndex, "an absent section must not become an anchor")
        XCTAssertEqual(parsed?[2].caption, "a burndown chart")
    }

    /// A section that does not exist degrades to "captioned but unanchored",
    /// rather than throwing the caption away with it.
    func testInvalidSectionKeepsTheCaption() {
        let parsed = ReportComposerService.parse(
            response: #"{"figures":[{"frame":"F1","section":"S9","caption":"still useful"}]}"#,
            sections: sections,
            frames: candidates(1)
        )
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertNil(parsed?.first?.sectionIndex)
        XCTAssertEqual(parsed?.first?.caption, "still useful")
    }

    /// The prompt was renamed from "anchors" to "figures"; a user with an
    /// overridden prompt in developer settings must keep working.
    func testLegacyAnchorsKeyStillParses() {
        let parsed = ReportComposerService.parse(
            response: #"{"anchors":[{"section":"S0","frame":"F1","caption":"c"}]}"#,
            sections: sections,
            frames: candidates(1)
        )
        XCTAssertEqual(parsed?.count, 1)
        XCTAssertEqual(parsed?.first?.sectionIndex, 0)
    }

    func testUnparseableResponseReturnsNil() {
        XCTAssertNil(ReportComposerService.parse(response: "no json at all", sections: sections, frames: candidates(1)))
    }

    func testBareNumbersAreAccepted() {
        XCTAssertEqual(ReportComposerService.index(from: "S3", prefix: "S"), 3)
        XCTAssertEqual(ReportComposerService.index(from: " 3 ", prefix: "S"), 3)
        XCTAssertEqual(ReportComposerService.index(from: "s3", prefix: "S"), 3)
        XCTAssertNil(ReportComposerService.index(from: "section three", prefix: "S"))
    }

    /// Frame indices are 1-based in the prompt, so F1 is frames[0]. Getting
    /// this wrong silently prints the wrong screenshot under every heading.
    func testFrameOrdinalsAreOneBased() {
        let frames = candidates(3)
        let parsed = ReportComposerService.parse(
            response: #"{"anchors":[{"section":"S0","frame":"F3","caption":"c"}]}"#,
            sections: sections, frames: frames
        )
        XCTAssertEqual(parsed?.first?.frameID, frames[2].id)
    }

    // MARK: - Prompt rendering

    func testFrameCatalogueUsesShortIndicesNotUUIDs() {
        let frames = candidates(2)
        let rendered = ReportComposerService.renderFrames(frames)
        XCTAssertTrue(rendered.contains("F1 | 1:00"))
        XCTAssertFalse(
            rendered.contains(frames[0].id.uuidString),
            "UUIDs in the prompt are pure token cost and get transcribed wrong"
        )
    }

    /// Observations are capped, but generously: the specifics that make a
    /// caption useful are spread through the whole paragraph, and cutting
    /// early left the model describing the application window rather than
    /// what was in it.
    func testLongObservationsAreTruncatedInThePrompt() {
        let long = String(repeating: "x", count: 2_000)
        let rendered = ReportComposerService.renderFrames([
            .init(id: UUID(), formattedTimestamp: "1:00", observation: long, contentType: nil, entities: [])
        ])
        XCTAssertLessThan(rendered.count, ReportComposerService.observationCap + 100)
        XCTAssertTrue(rendered.contains("…"))
    }

    /// A real observation of this length must reach the model intact — this
    /// is the length that was previously being cut in half.
    func testTypicalObservationSurvivesIntact() {
        let observation = """
        A detailed view of the Disability Decision Tool (DDM template) opened in the design \
        application. A modal dialog displays the template details: Title is 'Disability Decision \
        Tool' by John Rymal, authored by Trajector Medical. There is an RDL section showing \
        'Suggested (2)' and 'Manually (0)' tabs, with a table of Pursued Disability rows \
        showing Joint Pain with Approved decision and a 10% rating.
        """
        let rendered = ReportComposerService.renderFrames([
            .init(id: UUID(), formattedTimestamp: "5:36", observation: observation, contentType: "document", entities: [])
        ])
        XCTAssertFalse(rendered.contains("…"), "a typical observation should not be clipped")
        XCTAssertTrue(rendered.contains("Joint Pain"), "the specifics must reach the model")
    }

    // MARK: - Transcript excerpts

    private func line(_ t: TimeInterval, _ speaker: String, _ text: String) -> ReportComposerService.TranscriptLine {
        .init(startTime: t, speaker: speaker, text: text)
    }

    /// The excerpt is what ties a screenshot to a section: the words spoken
    /// as it was on screen, leaning toward what led up to it.
    func testExcerptTakesTheConversationAroundTheCapture() {
        let lines = [
            line(100, "Ann", "Before the window."),
            line(230, "Ann", "Let me share the pipeline."),
            line(290, "Bob", "That OCR step is new."),
            line(320, "Ann", "Right, it branches here."),
            line(400, "Bob", "Moving on to budget."),
        ]
        let excerpt = ReportComposerService.transcriptExcerpt(around: 300, in: lines)
        XCTAssertEqual(excerpt, "Ann: Let me share the pipeline. Bob: That OCR step is new. Ann: Right, it branches here.")
    }

    func testExcerptIsOrderedByTimeRegardlessOfInputOrder() {
        let lines = [line(310, "Bob", "second"), line(290, "Ann", "first")]
        XCTAssertEqual(ReportComposerService.transcriptExcerpt(around: 300, in: lines), "Ann: first Bob: second")
    }

    func testExcerptIsEmptyWhenNothingWasSaid() {
        XCTAssertEqual(ReportComposerService.transcriptExcerpt(around: 300, in: []), "")
        XCTAssertEqual(ReportComposerService.transcriptExcerpt(around: 300, in: [line(10, "Ann", "far away")]), "")
    }

    func testExcerptIsCappedOnAWordBoundary() {
        let long = (1...200).map { "word\($0)" }.joined(separator: " ")
        let excerpt = ReportComposerService.transcriptExcerpt(around: 300, in: [line(300, "Ann", long)])
        XCTAssertLessThanOrEqual(excerpt.count, ReportComposerService.transcriptCap + 1)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertFalse(excerpt.dropLast().hasSuffix("wor"), "cut mid-word")
    }

    func testCatalogueCarriesTheExcerptAndOmitsItWhenEmpty() {
        let spoken = ReportComposerService.FrameCandidate(
            id: UUID(), formattedTimestamp: "5:00", observation: "A pipeline diagram.",
            contentType: "diagram", entities: [], transcriptExcerpt: "Ann: here is the OCR branch"
        )
        let silent = ReportComposerService.FrameCandidate(
            id: UUID(), formattedTimestamp: "6:00", observation: "A slide.",
            contentType: "slide", entities: []
        )
        let rendered = ReportComposerService.renderFrames([spoken, silent])
        XCTAssertTrue(rendered.contains("said around then: \"Ann: here is the OCR branch\""))
        XCTAssertEqual(rendered.components(separatedBy: "said around then").count, 2, "only the frame with an excerpt carries one")
    }

    // MARK: - Placement

    func testAnchoredFigureMovesFromAppendixIntoItsSection() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 60)])
            .applyingAnchors(plan([.init(sectionIndex: 1, frameID: id, caption: "burndown")]))

        XCTAssertEqual(result.sections[1].figures.count, 1)
        XCTAssertEqual(result.sections[1].figures.first?.caption, "burndown", "the anchor caption should win")
        XCTAssertTrue(result.sections[0].figures.isEmpty)
        XCTAssertTrue(
            result.shareSessions[0].figures.isEmpty,
            "an anchored figure must not also appear in the appendix"
        )
    }

    /// This is a summary report: a screenshot that carries no point in the
    /// summary is not printed at all. Everything captured stays in the app.
    func testUnpickedFiguresAreNotPrinted() {
        let kept = UUID(), unpicked = UUID()
        let result = report(figures: [figure(kept, at: 60), figure(unpicked, at: 120)])
            .applyingAnchors(plan([.init(sectionIndex: 0, frameID: kept, caption: "schema")]))

        XCTAssertEqual(result.sections[0].figures.map(\.id), [kept])
        XCTAssertTrue(result.shareSessions[0].figures.isEmpty)
        XCTAssertEqual(result.allFigures.count, 1, "only the screenshot that made a point should print")
    }

    /// ...unless the template explicitly asks for the leftovers.
    func testUnpickedFiguresKeptWhenTemplateWantsThem() {
        let kept = UUID(), unpicked = UUID()
        let result = report(figures: [figure(kept, at: 60), figure(unpicked, at: 120)])
            .applyingAnchors(
                plan([.init(sectionIndex: 0, frameID: kept, caption: "schema")]),
                keepsUnpicked: true
            )
        XCTAssertEqual(result.allFigures.count, 2)
    }

    /// Without an anchoring plan nothing can be tied to a section, so the
    /// report keeps a few spread across the meeting rather than all of them.
    func testNoPlanKeepsOnlyAHandfulSpreadAcrossTheMeeting() {
        let figures = (0..<12).map { figure(UUID(), at: TimeInterval($0) * 60) }
        let result = report(figures: figures).keepingBestFigures(limit: 3)

        XCTAssertEqual(result.allFigures.count, 3)
        let times = result.allFigures.map(\.timestamp)
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(times.last! - times.first!, 240, "the kept few should span the meeting")
    }

    func testKeepingBestFiguresLeavesSmallSetsAlone() {
        let figures = (0..<2).map { figure(UUID(), at: TimeInterval($0) * 60) }
        XCTAssertEqual(report(figures: figures).keepingBestFigures(limit: 3).allFigures.count, 2)
    }

    func testOneFigureCannotBeAnchoredToTwoSections() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 60)])
            .applyingAnchors(plan([
                .init(sectionIndex: 0, frameID: id, caption: "first"),
                .init(sectionIndex: 1, frameID: id, caption: "second"),
            ]))

        XCTAssertEqual(result.allFigures.count, 1, "the same screenshot must not print twice")
        XCTAssertEqual(result.sections[0].figures.count, 1)
        XCTAssertTrue(result.sections[1].figures.isEmpty)
    }

    func testAnchorsNamingUnknownFramesOrSectionsAreIgnored() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 60)])
            .applyingAnchors(plan([
                .init(sectionIndex: 47, frameID: id, caption: "no such section"),
                .init(sectionIndex: 0, frameID: UUID(), caption: "no such frame"),
            ]))

        XCTAssertTrue(result.sections.allSatisfy { $0.figures.isEmpty })
        // Nothing was validly anchored, so nothing is printed — a bad
        // identifier must not smuggle a picture into the report.
        XCTAssertTrue(result.shareSessions[0].figures.isEmpty)
    }

    func testFiguresWithinASectionAreOrderedByTime() {
        let late = UUID(), early = UUID()
        let result = report(figures: [figure(late, at: 300), figure(early, at: 30)])
            .applyingAnchors(plan([
                .init(sectionIndex: 0, frameID: late, caption: "later"),
                .init(sectionIndex: 0, frameID: early, caption: "earlier"),
            ]))

        XCTAssertEqual(result.sections[0].figures.map(\.id), [early, late])
    }

    /// The formal-report arrangement: nothing moves into the prose, but every
    /// anchored figure still records which section it belongs to so the two
    /// can be cross-linked.
    func testFiguresAtEndKeepsFiguresInTheAppendixButRecordsTheirSection() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 60)])
            .applyingAnchors(
                plan([.init(sectionIndex: 1, frameID: id, caption: "burndown")]),
                figuresAtEnd: true
            )

        XCTAssertTrue(result.sections.allSatisfy { $0.figures.isEmpty }, "nothing should move inline")
        XCTAssertEqual(result.shareSessions[0].figures.count, 1)
        XCTAssertEqual(result.shareSessions[0].figures.first?.sectionIndex, 1)
        XCTAssertEqual(result.shareSessions[0].figures.first?.sectionTitle, "Q3 risks")
        XCTAssertEqual(result.shareSessions[0].figures.first?.caption, "burndown")
    }

    func testInlinePlacementAlsoRecordsTheSection() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 60)])
            .applyingAnchors(plan([.init(sectionIndex: 0, frameID: id, caption: "schema")]))
        XCTAssertEqual(result.sections[0].figures.first?.sectionIndex, 0)
        XCTAssertEqual(result.sections[0].figures.first?.sectionTitle, "Migration plan")
    }

    /// A screenshot the plan captions but does not anchor must still get its
    /// caption — an appendix picture with no explanation is as useless as one
    /// with no link.
    func testUnanchoredFigureStillReceivesItsCaption() {
        let anchored = UUID(), captionedOnly = UUID()
        let result = report(figures: [figure(anchored, at: 60), figure(captionedOnly, at: 120)])
            .applyingAnchors(
                plan([
                    .init(sectionIndex: 0, frameID: anchored, caption: "schema diff"),
                    .init(sectionIndex: nil, frameID: captionedOnly, caption: "the agenda slide"),
                ]),
                keepsUnpicked: true
            )

        XCTAssertEqual(result.sections[0].figures.first?.caption, "schema diff")
        let appendix = result.shareSessions[0].figures
        XCTAssertEqual(appendix.count, 1)
        XCTAssertEqual(appendix.first?.caption, "the agenda slide")
        XCTAssertNil(appendix.first?.sectionIndex, "captioning must not imply anchoring")
    }

    func testCaptionsApplyInFiguresAtEndModeToo() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 60, caption: "original")])
            .applyingAnchors(
                plan([.init(sectionIndex: nil, frameID: id, caption: "the agenda slide")]),
                figuresAtEnd: true,
                keepsUnpicked: true
            )
        XCTAssertEqual(result.shareSessions[0].figures.first?.caption, "the agenda slide")
    }

    func testEmptyAnchorCaptionKeepsTheOriginal() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 60, caption: "original")])
            .applyingAnchors(plan([.init(sectionIndex: 0, frameID: id, caption: "   ")]))
        XCTAssertEqual(result.sections[0].figures.first?.caption, "original")
    }

    // MARK: - Section selection

    func testDeselectedSectionsAreDropped() {
        let result = report(figures: [])
            .keepingSections([1])

        XCTAssertEqual(result.sections.map(\.id), [1])
        XCTAssertEqual(result.sections.first?.title, "Q3 risks")
    }

    /// A screenshot tied to a section the user left out must lose that tie.
    /// Keeping it would emit a cross-reference to a heading that is not in
    /// the document — a dead link in the PDF with nothing to show for it.
    func testFiguresLoseTheirTieToADroppedSection() {
        let kept = UUID(), orphaned = UUID()
        let anchored = report(figures: [figure(kept, at: 30), figure(orphaned, at: 90)])
            .applyingAnchors(
                plan([
                    .init(sectionIndex: 0, frameID: kept, caption: "schema"),
                    .init(sectionIndex: 1, frameID: orphaned, caption: "burndown"),
                ]),
                figuresAtEnd: true
            )
        // Drop section 1; its figure stays but must no longer point at it.
        let result = anchored.keepingSections([0])

        let figures = result.shareSessions[0].figures
        XCTAssertEqual(figures.count, 2, "the screenshot itself should survive")
        XCTAssertEqual(figures.first(where: { $0.id == kept })?.sectionIndex, 0)
        XCTAssertNil(
            figures.first(where: { $0.id == orphaned })?.sectionIndex,
            "a figure tied to a dropped section would render a dead link"
        )
        XCTAssertNil(figures.first(where: { $0.id == orphaned })?.sectionTitle)
    }

    /// Filtering has to happen after anchoring, because the cached plan's
    /// indices refer to the full section list.
    func testAnchoringThenFilteringKeepsFiguresOnTheRightSection() {
        let id = UUID()
        let result = report(figures: [figure(id, at: 30)])
            .applyingAnchors(plan([.init(sectionIndex: 1, frameID: id, caption: "burndown")]))
            .keepingSections([1])

        XCTAssertEqual(result.sections.count, 1)
        XCTAssertEqual(result.sections[0].figures.map(\.id), [id], "the figure followed the wrong section")
    }

    func testKeepingNoSectionsLeavesTheOtherBlocksAlone() {
        let result = report(figures: []).keepingSections([])
        XCTAssertTrue(result.sections.isEmpty)
        XCTAssertEqual(result.shareSessions.count, 1, "shared screens are a separate switch")
    }

    // MARK: - Cache validity

    /// Regenerating the analysis produces new sections, so an old plan would
    /// anchor figures to headings that no longer exist.
    func testPlanIsInvalidatedByANewInsight() {
        let insight = UUID()
        let stored = plan([], insight: insight)
        XCTAssertTrue(stored.isValid(forInsight: insight))
        XCTAssertFalse(stored.isValid(forInsight: UUID()))
    }

    /// A plan from an older planner must not be reused: its anchors were
    /// chosen by a different prompt and may name frames the current selection
    /// no longer carries, which would silently produce a report with no links.
    func testPlanIsInvalidatedByAnOlderPlannerVersion() {
        let insight = UUID()
        var stale = plan([], insight: insight)
        stale.version = ReportAnchorPlan.currentVersion - 1
        XCTAssertFalse(stale.isValid(forInsight: insight))
    }

    /// v1 files predate the version field entirely. Decoding must fail so the
    /// cache misses and the plan is recomputed, rather than silently
    /// defaulting to "current" and reusing stale anchors.
    func testVersionlessCacheFileIsRejected() {
        let legacy = """
        {"insightID":"\(UUID().uuidString)","anchors":[],\
        "createdAt":0,"modelIdentifier":"old"}
        """
        XCTAssertNil(
            try? JSONDecoder().decode(ReportAnchorPlan.self, from: Data(legacy.utf8)),
            "a v1 cache file must not decode as current"
        )
    }
}
