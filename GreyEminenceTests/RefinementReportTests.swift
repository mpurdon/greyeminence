import PDFKit
import XCTest
@testable import Grey_Eminence

/// Pure tests for Refinements: the analysis signal that lists a meeting,
/// the backfill that assesses older ones, the structured report (what goes
/// in, what a model's response decodes to, how it exports), and the Jira
/// ticket it can become.
final class RefinementReportTests: XCTestCase {

    private func input(
        participants: [String] = ["Priya", "Sam"],
        screenContext: String? = nil,
        transcript: String = "[00:12] Me: Let's cap uploads at 10MB.\n[00:20] Priya: Agreed, reject with a clear error."
    ) -> RefinementReportService.Input {
        RefinementReportService.Input(
            title: "Upload Limits Refinement",
            date: Date(timeIntervalSince1970: 1_790_000_000),
            participants: participants,
            screenContext: screenContext,
            transcript: transcript
        )
    }

    // MARK: - Refinement signal

    func testSignalParsesNumbersAndNumericStrings() {
        XCTAssertEqual(
            RefinementSignal.parse(["likelihood": 0.82, "features": ["Bulk export"]]),
            RefinementSignal(likelihood: 0.82, features: ["Bulk export"])
        )
        XCTAssertEqual(RefinementSignal.parse(["likelihood": "0.3"])?.likelihood, 0.3)
        XCTAssertEqual(RefinementSignal.parse(["likelihood": 1])?.likelihood, 1.0)
    }

    func testSignalClampsAndDropsEmptyFeatureNames() {
        XCTAssertEqual(RefinementSignal(likelihood: 1.7, features: []).likelihood, 1)
        XCTAssertEqual(RefinementSignal(likelihood: -0.2, features: []).likelihood, 0)
        XCTAssertEqual(RefinementSignal(likelihood: 0.1, features: ["  ", "null"]).features, [])
    }

    func testSignalIsNilWithoutAReadableLikelihood() {
        XCTAssertNil(RefinementSignal.parse(nil))
        XCTAssertNil(RefinementSignal.parse("0.9"))
        XCTAssertNil(RefinementSignal.parse(["features": ["Export"]]))
        XCTAssertNil(RefinementSignal.parse(["likelihood": "high"]))
    }

    func testCandidacyFollowsThresholdAndUserOverride() {
        let meeting = Meeting(title: "Grooming", status: .completed)
        XCTAssertFalse(meeting.isRefinementCandidate, "unassessed meetings are not listed")

        meeting.applyRefinementSignal(RefinementSignal(likelihood: 0.75, features: ["Export"]))
        XCTAssertTrue(meeting.isRefinementCandidate)
        XCTAssertEqual(meeting.refinementFeatures, ["Export"])

        meeting.refinementOverride = false
        XCTAssertFalse(meeting.isRefinementCandidate, "the user's removal beats the analysis")

        meeting.refinementOverride = true
        meeting.applyRefinementSignal(RefinementSignal(likelihood: 0.05, features: []))
        XCTAssertTrue(meeting.isRefinementCandidate, "the user's addition beats a later analysis")
        XCTAssertEqual(meeting.refinementFeatures, ["Export"], "no names does not erase named ones")

        meeting.applyRefinementSignal(nil)
        XCTAssertEqual(meeting.refinementLikelihood, 0.05, "a pass with no signal leaves the last one")

        let interview = Meeting(title: "Interview", status: .completed)
        interview.isInterviewMeeting = true
        interview.refinementOverride = true
        XCTAssertFalse(interview.isRefinementCandidate)
    }

    func testAnalysisPromptAsksForTheSignalOnlyInTheFinalPass() {
        let system = AIPromptTemplates.defaultText(for: .meetingSystem)
        XCTAssertTrue(system.contains("\"refinement\": {\"likelihood\""))
        XCTAssertTrue(system.contains("final analysis only"))
        XCTAssertTrue(AIPromptTemplates.defaultText(for: .meetingFinal).contains("\"refinement\" object"))
    }

    func testBothDetectionPromptsShareTheFeatureRules() {
        // An architecture discussed for a feature is part of it, not a second
        // feature — the split that listed "Outbox pattern" beside the feature
        // it was designed for.
        for key in [PromptKey.meetingSystem, .refinementClassify] {
            let text = AIPromptTemplates.defaultText(for: key)
            XCTAssertTrue(text.contains(AIPromptTemplates.refinementFeatureRules), "\(key.rawValue) lacks the shared feature rules")
        }
        XCTAssertTrue(AIPromptTemplates.refinementFeatureRules.contains("not \"Outbox pattern\""))
        XCTAssertFalse(AIPromptTemplates.defaultText(for: .refinementClassify).contains("retry policy"),
                       "the example must not model a feature's mechanism as a second feature")
    }

    // MARK: - Backfill

    func testBackfillParseMapsIdentifiersBackToTheBatch() {
        let response = """
        ```json
        {"meetings":[
          {"id":"M1","likelihood":0.9,"features":["Bulk export"]},
          {"id":"m3","likelihood":0.1,"features":[]},
          {"id":"M9","likelihood":0.8},
          {"id":"M2"}
        ]}
        ```
        """
        let signals = RefinementBackfill.parse(response: response, count: 3)
        XCTAssertEqual(signals.count, 2)
        XCTAssertEqual(signals[0], RefinementSignal(likelihood: 0.9, features: ["Bulk export"]))
        XCTAssertEqual(signals[2], RefinementSignal(likelihood: 0.1, features: []))
        XCTAssertNil(signals[1], "an entry with no likelihood stays unassessed")
    }

    func testBackfillParseSurvivesGarbage() {
        XCTAssertTrue(RefinementBackfill.parse(response: "I can't classify these.", count: 3).isEmpty)
    }

    func testBackfillFlattensSectionSummariesAndCapsLength() {
        let json = #"[{"title":"Export","points":[{"label":"Format","detail":"CSV first"}]}]"#
        XCTAssertEqual(RefinementBackfill.flatten(summary: json), "Export; Format: CSV first")

        let long = String(repeating: "a", count: RefinementBackfill.summaryCharacterLimit + 50)
        XCTAssertEqual(RefinementBackfill.flatten(summary: long).count, RefinementBackfill.summaryCharacterLimit + 1)
    }

    func testBackfillCatalogueNumbersFromOne() {
        let entries = [
            RefinementBackfill.Entry(title: "Grooming", date: Date(timeIntervalSince1970: 1_790_000_000), topics: ["Export"], summary: "CSV"),
            RefinementBackfill.Entry(title: "Standup", date: Date(timeIntervalSince1970: 1_790_000_000), topics: [], summary: "Status"),
        ]
        let catalogue = RefinementBackfill.catalogue(entries)
        XCTAssertTrue(catalogue.hasPrefix("M1 | Grooming | "))
        XCTAssertTrue(catalogue.contains("Topics: Export"))
        XCTAssertTrue(catalogue.contains("M2 | Standup | "))
    }

    // MARK: - Report prompt

    func testDefaultPromptsUseEveryDeclaredPlaceholder() {
        for key in [PromptKey.refinementReport, .refinementClassify, .topicClassify] {
            let text = AIPromptTemplates.defaultText(for: key)
            for placeholder in key.placeholders {
                XCTAssertTrue(text.contains("{{\(placeholder)}}"), "\(key.rawValue) never uses {{\(placeholder)}}")
            }
        }
    }

    func testUserPromptCarriesMeetingAndLeavesNoPlaceholders() {
        let prompt = RefinementReportService.userPrompt(for: input())
        XCTAssertTrue(prompt.contains("Upload Limits Refinement"))
        XCTAssertTrue(prompt.contains("Participants: Priya, Sam"))
        XCTAssertTrue(prompt.contains("[00:20] Priya: Agreed, reject with a clear error."))
        XCTAssertFalse(prompt.contains("{{"), "unrendered placeholder left in prompt")
        XCTAssertTrue(RefinementReportService.userPrompt(for: input(participants: [])).contains("Participants: Not recorded"))
    }

    func testScreenContextOnlyAppearsWhenThereIsSome() {
        XCTAssertEqual(RefinementReportService.screenContextBlock(nil), "")
        XCTAssertEqual(RefinementReportService.screenContextBlock("  \n "), "")
        XCTAssertFalse(RefinementReportService.userPrompt(for: input()).contains("SHARED SCREEN"))
        XCTAssertTrue(RefinementReportService.userPrompt(for: input(screenContext: "Jira UP-12")).contains("SHARED SCREEN"))
    }

    func testParticipantsLabelTheMeSpeaker() {
        XCTAssertEqual(
            RefinementReportService.participants(roster: MeetingRoster(myName: "Matt", otherAttendees: ["Priya"])),
            ["Matt (\"Me\" in the transcript)", "Priya"]
        )
    }

    // MARK: - Report parsing

    private let fullResponse = """
    Here is the analysis:
    {
      "is_refinement": true,
      "intent": "Stop oversized uploads from failing silently.",
      "acceptance_criteria": [
        {"text": "Uploads over 10MB are rejected", "basis": "EXPLICIT", "confidence": null, "evidence": "[00:12]"},
        {"text": "The error names the limit", "basis": "inferred", "confidence": "Medium", "evidence": "[00:20] 'clear error'"},
        {"basis": "emergent"}
      ],
      "decisions": [
        {"decision": "Enforce on the server", "category": "validation", "reason": null, "alternatives": "client-only", "effect": "API returns 413", "basis": "explicit"}
      ],
      "rejected_approaches": [{"approach": "Client-side only", "reason": "bypassable"}],
      "constraints": [{"text": "CDN caps bodies at 20MB", "source": null}],
      "reviewer_notes": ["Existing uploads over 10MB stay valid", ""],
      "open_questions": [{"question": "Does the limit apply to admins?", "owner": "Priya"}],
      "spec": {
        "intent": "Reject uploads over 10MB with a clear error.",
        "acceptance_criteria": ["Over 10MB → 413 with the limit in the message"],
        "decisions": ["Server-side enforcement"],
        "constraints": [],
        "open_questions": ["Admin exemption?"]
      }
    }
    """

    func testParsesAFullResponseAndDropsMalformedEntries() throws {
        let content = try XCTUnwrap(RefinementReportService.parse(response: fullResponse))
        XCTAssertTrue(content.isRefinement)
        XCTAssertEqual(content.intent, "Stop oversized uploads from failing silently.")
        XCTAssertEqual(content.acceptanceCriteria.count, 2, "the criterion with no text is dropped, not the report")
        XCTAssertEqual(content.acceptanceCriteria[0].basis, .explicit)
        XCTAssertEqual(content.acceptanceCriteria[1].basis, .inferred)
        XCTAssertEqual(content.acceptanceCriteria[1].confidence, .medium)
        XCTAssertEqual(content.decisions.first?.alternatives, "client-only")
        XCTAssertNil(content.decisions.first?.reason)
        XCTAssertEqual(content.reviewerNotes, ["Existing uploads over 10MB stay valid"])
        XCTAssertEqual(content.openQuestions.first?.owner, "Priya")
        XCTAssertEqual(content.spec.decisions, ["Server-side enforcement"])
    }

    func testParseToleratesMissingSectionsAndOddLabels() throws {
        let content = try XCTUnwrap(RefinementReportService.parse(response: """
        {"intent": "Standup, not a refinement.", "is_refinement": false,
         "acceptance_criteria": [{"text": "x", "basis": "Inferred (low)"}]}
        """))
        XCTAssertFalse(content.isRefinement)
        XCTAssertEqual(content.acceptanceCriteria.first?.basis, .inferred)
        XCTAssertTrue(content.decisions.isEmpty)
        XCTAssertEqual(content.spec, RefinementReportContent.Spec())
    }

    func testUnreadableResponseIsNil() {
        XCTAssertNil(RefinementReportService.parse(response: "Sorry, I can't help with that."))
    }

    func testStoredReportRoundTrips() throws {
        let content = try XCTUnwrap(RefinementReportService.parse(response: fullResponse))
        let report = RefinementReport(
            content: content,
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            modelIdentifier: "claude-sonnet-5",
            promptVersion: RefinementReportService.promptVersion,
            transcriptFingerprint: input().fingerprint,
            jiraIssue: JiraIssueLink(key: "UP-7", url: URL(string: "https://acme.atlassian.net/browse/UP-7")!, createdAt: Date(timeIntervalSince1970: 1_790_000_100))
        )
        let decoded = try JSONDecoder().decode(RefinementReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
    }

    func testFingerprintIsStableAndSensitiveToTheTranscript() {
        let a = RefinementReportService.fingerprint(of: "[00:01] Me: hello")
        XCTAssertEqual(a, RefinementReportService.fingerprint(of: "[00:01] Me: hello"))
        XCTAssertNotEqual(a, RefinementReportService.fingerprint(of: "[00:01] Speaker 2: hello"))
    }

    // MARK: - Markdown

    func testFullMarkdownHasEverySectionAndLabels() throws {
        let content = try XCTUnwrap(RefinementReportService.parse(response: fullResponse))
        let markdown = RefinementReportMarkdown.full(content, title: "Upload limits", date: Date(timeIntervalSince1970: 1_790_000_000))
        for heading in ["## 1. Intent", "## 2. Acceptance criteria that emerged", "## 3. Decisions made during refinement",
                        "## 4. Rejected approaches", "## 5. Constraints discovered",
                        "## 6. Implementer- and reviewer-relevant information", "## 7. Unresolved questions",
                        "## 8. Effective session spec", "### Acceptance Criteria", "### Open Questions"] {
            XCTAssertTrue(markdown.contains(heading), "missing \(heading)")
        }
        XCTAssertTrue(markdown.contains("- **EXPLICIT** — Uploads over 10MB are rejected"))
        XCTAssertTrue(markdown.contains("**INFERRED · Medium confidence** — The error names the limit"))
        XCTAssertTrue(markdown.contains("  - **Reason/evidence:** Not stated"), "a missing reason is said, never invented")
        XCTAssertTrue(markdown.contains("Does the limit apply to admins? _(owner: Priya)_"))
    }

    func testEmptySectionsSayNoneIdentified() {
        let markdown = RefinementReportMarkdown.spec(RefinementReportContent.Spec(intent: "Ship it"))
        XCTAssertTrue(markdown.hasPrefix("## Intent\n\nShip it"))
        XCTAssertTrue(markdown.contains("## Constraints / Non-goals\n\nNone identified."))
    }

    func testSuggestedFilenameIsDatedAndTagged() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 23
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(
            RefinementDetailView.suggestedFilename(title: "Upload Limits", date: date),
            "Upload Limits — 2026-09-23 (refinement).md"
        )
    }

    func testPDFFilenamesSayWhichExportTheyAre() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 23
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(
            RefinementDetailView.suggestedFilename(title: "Upload Limits", date: date, suffix: "spec", fileExtension: "pdf"),
            "Upload Limits — 2026-09-23 (spec).pdf"
        )
    }

    func testModelLabelHidesInferenceProfileARNs() {
        let arn = "arn:aws:bedrock:us-east-2:111122223333:application-inference-profile/abc123"
        XCTAssertEqual(RefinementReportService.modelLabel("claude-sonnet-5", settings: nil), "Claude Sonnet")
        XCTAssertEqual(RefinementReportService.modelLabel("bedrock:us-east-2:\(arn)", settings: nil), "Claude via Bedrock")
        XCTAssertEqual(RefinementReportService.modelLabel("some-other-model", settings: nil), "some-other-model")
    }

    // MARK: - PDF

    @MainActor
    func testPDFExportPaginatesAndKeepsText() throws {
        var content = try XCTUnwrap(RefinementReportService.parse(response: fullResponse))
        // Enough decisions to force a second page.
        content.decisions = Array(repeating: content.decisions[0], count: 14)
        let report = RefinementReport(
            content: content,
            generatedAt: .now,
            modelIdentifier: "claude-sonnet-5",
            promptVersion: RefinementReportService.promptVersion,
            transcriptFingerprint: "x"
        )
        let meeting = Meeting(title: "OLP Intake", status: .completed)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fullURL = dir.appendingPathComponent("full.pdf")
        try RefinementPDFExporter.write(report, scope: .full, feature: "Upload limits", meeting: meeting, to: fullURL)
        let full = try XCTUnwrap(PDFDocument(url: fullURL))
        XCTAssertGreaterThan(full.pageCount, 1)
        let lastPage = full.page(at: full.pageCount - 1)?.string ?? ""
        XCTAssertTrue(lastPage.contains("Effective Spec"), "the spec opens its own page")
        XCTAssertFalse(lastPage.contains("Does the limit apply to admins?"), "the rationale's last section stays off the spec's page")
        let previousPage = full.page(at: full.pageCount - 2)?.string ?? ""
        XCTAssertTrue(previousPage.contains("Does the limit apply to admins?"))
        XCTAssertEqual(full.page(at: 0)?.bounds(for: .mediaBox).size, RefinementPDFExporter.pageSize)

        let specURL = dir.appendingPathComponent("spec.pdf")
        try RefinementPDFExporter.write(report, scope: .specOnly, feature: "Upload limits", meeting: meeting, to: specURL)
        let spec = try XCTUnwrap(PDFDocument(url: specURL))
        XCTAssertEqual(spec.pageCount, 1)
        XCTAssertLessThan(spec.pageCount, full.pageCount)
        let text = spec.string ?? ""
        XCTAssertTrue(text.contains("Upload limits"), "PDF text should be real text, not an image: \(text.prefix(200))")
        XCTAssertTrue(text.contains("Page 1 of 1"))
    }

    // MARK: - Several features per meeting

    func testSignalReadsAFeatureList() {
        let signal = RefinementSignal.parse(["likelihood": 0.8, "features": ["Bulk export", " bulk EXPORT ", "Retry policy", "", "A", "B", "C"]])
        XCTAssertEqual(signal?.features, ["Bulk export", "Retry policy", "A", "B"], "deduped case-insensitively, capped at four")
        XCTAssertEqual(RefinementSignal.parse(["likelihood": 0.2, "features": []])?.features, [])
    }

    func testMeetingTopicsFollowItsFeatures() {
        let meeting = Meeting(title: "OLP Sync", status: .completed)
        XCTAssertEqual(meeting.refinementTopics, ["OLP Sync"], "no names yet: the meeting's own title")

        meeting.applyRefinementSignal(RefinementSignal(likelihood: 0.8, features: ["Intake", "Contract trigger"]))
        XCTAssertEqual(meeting.refinementTopics, ["Intake", "Contract trigger"])

        meeting.applyRefinementSignal(RefinementSignal(likelihood: 0.8, features: []))
        XCTAssertEqual(meeting.refinementTopics, ["Intake", "Contract trigger"], "an empty list doesn't erase named features")
    }

    private func report(_ intent: String, at seconds: TimeInterval = 0) -> RefinementReport {
        RefinementReport(
            content: RefinementReportContent(intent: intent),
            generatedAt: Date(timeIntervalSince1970: seconds),
            modelIdentifier: "m",
            promptVersion: "v",
            transcriptFingerprint: "f"
        )
    }

    func testShelfKeysReportsByFeatureAndMigratesTheLegacyOne() throws {
        // A file from before several features: one bare report.
        let legacyData = try JSONEncoder().encode(report("old"))
        XCTAssertNil(try? JSONDecoder().decode(RefinementReportShelf.self, from: legacyData), "a bare report must not read as a shelf")

        var shelf = RefinementReportShelf(reports: [RefinementReportShelf.legacyKey: report("old")])
        XCTAssertEqual(shelf.report(for: "Intake", isFirst: true)?.content.intent, "old", "the first feature inherits it")
        XCTAssertNil(shelf.report(for: "Contract trigger", isFirst: false))

        shelf.store(report("new"), for: "Intake", isFirst: true)
        XCTAssertNil(shelf.reports[RefinementReportShelf.legacyKey], "replaced, not kept alongside")
        shelf.store(report("second"), for: "Contract Trigger", isFirst: false)
        XCTAssertEqual(shelf.report(for: "contract trigger", isFirst: false)?.content.intent, "second", "keys ignore case")

        let decoded = try JSONDecoder().decode(RefinementReportShelf.self, from: JSONEncoder().encode(shelf))
        XCTAssertEqual(decoded, shelf)
    }

    func testRenamedFeatureDoesNotLoseItsReport() {
        let shelf = RefinementReportShelf(reports: [
            "old name": report("orphan", at: 10),
            "contract trigger": report("claimed", at: 20),
        ])
        let known = ["New name", "Contract trigger"]
        XCTAssertEqual(shelf.report(for: "New name", isFirst: true, knownFeatures: known)?.content.intent, "orphan")
        XCTAssertNil(shelf.report(for: "Other", isFirst: false, knownFeatures: known))
    }

    func testFocusNarrowsOnlyMultiFeatureMeetings() {
        XCTAssertEqual(RefinementReportService.focusBlock(feature: "Intake", allFeatures: ["Intake"]), "")
        XCTAssertEqual(RefinementReportService.focusBlock(feature: nil, allFeatures: ["A", "B"]), "")

        let focus = RefinementReportService.focusBlock(feature: "Contract trigger", allFeatures: ["Intake", "Contract trigger"])
        XCTAssertTrue(focus.contains("ONE of them: \"Contract trigger\""))
        XCTAssertTrue(focus.contains("belong to Intake"))

        var multi = input()
        multi.feature = "Contract trigger"
        multi.allFeatures = ["Intake", "Contract trigger"]
        XCTAssertTrue(RefinementReportService.userPrompt(for: multi).contains("FOCUS"))
        XCTAssertFalse(RefinementReportService.userPrompt(for: input()).contains("FOCUS"))
    }

    func testSpeakerDotsSkipPeopleWhoBarelySpoke() {
        let talkers = RefinementSpeakers.talkers([("Carlos", 600), ("Me", 300), ("Liran", 80), ("Paras", 20)])
        XCTAssertEqual(talkers.map(\.0), ["Carlos", "Me", "Liran"], "Paras said 2% of the words")
        XCTAssertEqual(talkers[0].1, 0.6, accuracy: 0.0001)
        XCTAssertTrue(RefinementSpeakers.talkers([(String, Int)]()).isEmpty)
    }

    func testSpeakerDotsLeaveOutUnnamedVoices() {
        let talkers = RefinementSpeakers.attributedTalkers([
            (.other("Carlos"), 400), (.numbered(2), 300), (.unidentified, 200), (.me, 100),
        ])
        XCTAssertEqual(talkers.map(\.0), [.other("Carlos"), .me])
        XCTAssertEqual(talkers[0].1, 0.4, accuracy: 0.0001, "share is of everything said, unnamed voices included")
    }

    // MARK: - Citations

    func testCitationParsingReadsStampsAndSpans() {
        let found = RefinementCitation.parse(in: "[7:52] 'x'; [20:36]-[21:26] Carlos; 7:01–7:10 and 1:02:07")
        XCTAssertEqual(found, [
            RefinementCitation(start: 472, end: nil),
            RefinementCitation(start: 1236, end: 1286),
            RefinementCitation(start: 421, end: 430),
            RefinementCitation(start: 3727, end: nil),
        ])
        XCTAssertEqual(found[1].label, "20:36–21:26")
        XCTAssertEqual(RefinementCitation.parse(in: "75:03")[0].start, 4503, "minutes past 59, as the transcript writes them")
        XCTAssertTrue(RefinementCitation.parse(in: "Screen share 1: toggles, 9:75").isEmpty)
    }

    func testEvidenceIndexNumbersInReadingOrderAndSharesRepeatedMoments() throws {
        var content = try XCTUnwrap(RefinementReportService.parse(response: fullResponse))
        content.decisions[0].citations = ["0:12"]
        let index = RefinementEvidenceIndex(content)

        // Criterion 1 cites 0:12, criterion 2 cites 0:20; the decision reuses 0:12.
        XCTAssertEqual(index.numbers(for: .criterion(0)), [1])
        XCTAssertEqual(index.numbers(for: .criterion(1)), [2])
        XCTAssertEqual(index.numbers(for: .decision(0)), [1], "a moment cited twice keeps one number")
        XCTAssertEqual(index.entry(1)?.supports.count, 2)
        XCTAssertEqual(index.entry(2)?.note, "[00:20] 'clear error'")
        XCTAssertTrue(index.numbers(for: .rejected(0)).isEmpty)
    }

    func testEvidenceWithoutAMomentIsKeptAsAnUncitedNote() throws {
        let content = try XCTUnwrap(RefinementReportService.parse(response: """
        {"intent": "x", "acceptance_criteria": [{"text": "Toggles work", "basis": "explicit", "evidence": "Screen share 1 shows the toggles"}]}
        """))
        let index = RefinementEvidenceIndex(content)
        XCTAssertTrue(index.entries.isEmpty)
        XCTAssertEqual(index.uncitedNotes.first?.note, "Screen share 1 shows the toggles")
    }

    func testExplicitCitationsDecode() throws {
        let content = try XCTUnwrap(RefinementReportService.parse(response: """
        {"intent": "x", "constraints": [{"text": "CDN cap", "source": null, "citations": ["3:10", "4:00-4:30"]}]}
        """))
        XCTAssertEqual(content.constraints.first?.citations, ["3:10", "4:00-4:30"])
        XCTAssertEqual(RefinementEvidenceIndex(content).numbers(for: .constraint(0)), [1, 2])
    }

    func testPassageStartsAtTheCitedLineAndFollowsOn() {
        let lines = [0, 30, 42, 50, 58, 90].map {
            RefinementPassage.Line(id: UUID(), startTime: TimeInterval($0), speaker: "A", text: "t\($0)")
        }
        let single = RefinementPassage.lines(for: RefinementCitation(start: 45, end: nil), in: lines)
        XCTAssertEqual(single.map(\.startTime), [42, 50, 58], "the line containing 0:45, then 20s of follow-on")

        let span = RefinementPassage.lines(for: RefinementCitation(start: 30, end: 90), in: lines)
        XCTAssertEqual(span.map(\.startTime), [30, 42, 50, 58, 90])

        XCTAssertTrue(RefinementPassage.lines(for: RefinementCitation(start: 5, end: nil), in: []).isEmpty)
    }

    // MARK: - List filter

    func testConfidenceLevelsFilterByScoreButKeepManualAdditions() {
        let scored = Meeting(title: "a", status: .completed)
        scored.refinementLikelihood = 0.7
        XCTAssertTrue(RefinementConfidence.possibly.includes(scored))
        XCTAssertTrue(RefinementConfidence.likely.includes(scored))
        XCTAssertFalse(RefinementConfidence.definitely.includes(scored))

        let added = Meeting(title: "b", status: .completed)
        added.refinementLikelihood = 0.1
        added.refinementOverride = true
        XCTAssertTrue(RefinementConfidence.definitely.includes(added))

        XCTAssertEqual(Meeting.refinementThreshold, RefinementConfidence.possibly.minimum)
    }

    // MARK: - Jira

    func testSiteNormalisationAcceptsWhatPeoplePaste() {
        let expected = URL(string: "https://acme.atlassian.net")
        XCTAssertEqual(JiraSettings.normalizedSite("acme"), expected)
        XCTAssertEqual(JiraSettings.normalizedSite("acme.atlassian.net"), expected)
        XCTAssertEqual(JiraSettings.normalizedSite(" https://acme.atlassian.net/jira/software/projects/UP/boards/1 "), expected)
        XCTAssertEqual(JiraSettings.normalizedSite("http://jira.acme.com"), URL(string: "https://jira.acme.com"))
        XCTAssertNil(JiraSettings.normalizedSite("   "))
    }

    func testCreateIssueBodyShape() throws {
        let body = JiraClient.createIssueBody(
            projectKey: "UP",
            issueType: "Story",
            summary: "Upload\nlimits",
            descriptionMarkdown: "## Intent\n\nCap it",
            labels: ["refinement"]
        )
        let fields = try XCTUnwrap(body["fields"] as? [String: Any])
        XCTAssertEqual((fields["project"] as? [String: String])?["key"], "UP")
        XCTAssertEqual((fields["issuetype"] as? [String: String])?["name"], "Story")
        XCTAssertEqual(fields["summary"] as? String, "Upload limits")
        XCTAssertEqual(fields["labels"] as? [String], ["refinement"])
        XCTAssertEqual((fields["description"] as? [String: Any])?["type"] as? String, "doc")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testJiraErrorMessageCombinesBothShapes() {
        let data = Data(#"{"errorMessages":["Bad request"],"errors":{"issuetype":"Specify a valid issue type"}}"#.utf8)
        XCTAssertEqual(JiraClient.errorMessage(from: data), "Bad request issuetype: Specify a valid issue type")
    }

    func testLabelsAreSplitAndMadeJiraSafe() {
        XCTAssertEqual(JiraTicketSheet.labels(from: " refinement, needs review ,, "), ["refinement", "needs-review"])
    }

    func testBrowseURL() {
        XCTAssertEqual(
            JiraClient.browseURL(site: URL(string: "https://acme.atlassian.net")!, key: "UP-7").absoluteString,
            "https://acme.atlassian.net/browse/UP-7"
        )
    }

    // MARK: - ADF

    func testADFBlocks() throws {
        let blocks = JiraADF.blocks("""
        ## Intent

        Cap uploads
        at 10MB.

        - one
          - nested
        - two

        ---
        """)
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["heading", "paragraph", "bulletList", "rule"])
        XCTAssertEqual((blocks[0]["attrs"] as? [String: Int])?["level"], 2)

        let paragraph = try XCTUnwrap(blocks[1]["content"] as? [[String: Any]])
        XCTAssertEqual(paragraph.first?["text"] as? String, "Cap uploads at 10MB.")

        let items = try XCTUnwrap(blocks[2]["content"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        let firstItem = try XCTUnwrap(items[0]["content"] as? [[String: Any]])
        XCTAssertEqual(firstItem.last?["type"] as? String, "bulletList", "indented item nests under the one above")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(JiraADF.document(fromMarkdown: "## Intent\n\n- a\n  - b")))
    }

    func testADFInlineMarksAndSnakeCase() {
        let nodes = JiraADF.inline("**EXPLICIT** — keep max_upload_size _as is_.")
        XCTAssertEqual(nodes.map { $0["text"] as? String }, ["EXPLICIT", " — keep max_upload_size ", "as is", "."])
        XCTAssertEqual((nodes[0]["marks"] as? [[String: String]])?.first?["type"], "strong")
        XCTAssertNil(nodes[1]["marks"])
        XCTAssertEqual((nodes[2]["marks"] as? [[String: String]])?.first?["type"], "em")
        XCTAssertTrue(JiraADF.inline("").isEmpty, "no empty text nodes")
    }
}
