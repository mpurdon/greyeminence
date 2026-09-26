import XCTest
@testable import Grey_Eminence

@MainActor
final class RefinementReviewTests: XCTestCase {
    private func content() -> RefinementReportContent {
        RefinementReportContent(
            intent: "Retain trusted-form certificates without blocking intake.",
            acceptanceCriteria: [
                .init(text: "Intake never waits on the retention call", basis: .emergent),
                .init(text: "Retention retried until it succeeds", basis: .explicit),
                .init(text: "Admins see a retention dashboard", basis: .inferred),
            ],
            decisions: [.init(decision: "Use the outbox pattern", basis: .explicit)],
            constraints: [.init(text: "Mongo transactions only")],
            reviewerNotes: ["The lead service owns the outbox"],
            openQuestions: [
                .init(question: "What retry backoff?", owner: "Liran"),
                .init(question: "Alert on permanent failure?"),
            ]
        )
    }

    private func report() -> RefinementReport {
        RefinementReport(content: content(), generatedAt: .now, modelIdentifier: "m", promptVersion: "v", transcriptFingerprint: "f")
    }

    // MARK: - Workflow

    func testWorkingOnANewReportPutsItInProgress() {
        var report = report()
        XCTAssertEqual(report.status, .new)
        report.editReview { $0.items[RefinementItemRef.criterion(0).key] = .init(priority: .must) }
        XCTAssertEqual(report.status, .inProgress)
    }

    func testAnEditThatChangesNothingIsNotAnEdit() {
        var report = report()
        report.editReview { _ in }
        XCTAssertEqual(report.status, .new)
        XCTAssertNil(report.review)
    }

    func testAcceptWriteVerify() {
        var report = report()
        report.acceptRationale()
        XCTAssertEqual(report.status, .accepted)
        report.verifySpec()
        XCTAssertEqual(report.status, .accepted, "nothing to verify before the spec is written")

        report.storeSpec(.init(intent: "Ship it", acceptanceCriteria: ["[Must] x"]), modelIdentifier: "m")
        XCTAssertFalse(report.specIsDraft)
        report.verifySpec()
        XCTAssertEqual(report.status, .verified)
        XCTAssertNotNil(report.review?.specVerifiedAt)
    }

    func testEditingAnAcceptedRationaleReopensItAndStalesTheSpec() {
        var report = report()
        report.acceptRationale()
        report.storeSpec(.init(intent: "Ship it"), modelIdentifier: "m")
        report.verifySpec()

        report.editReview { $0.items[RefinementItemRef.question(0).key] = .init(resolution: "Exponential, 5 tries") }
        XCTAssertFalse(report.isRationaleAccepted)
        XCTAssertEqual(report.review?.specIsStale, true)
        XCTAssertNil(report.review?.specVerifiedAt)
        XCTAssertEqual(report.status, .inProgress)

        report.verifySpec()
        XCTAssertEqual(report.status, .inProgress, "a stale spec can't be verified")
    }

    func testReopeningKeepsTheSpecButMarksItOutOfDate() {
        var report = report()
        report.acceptRationale()
        report.storeSpec(.init(intent: "Ship it"), modelIdentifier: "m")
        report.reopenRationale()
        XCTAssertEqual(report.status, .inProgress)
        XCTAssertEqual(report.review?.spec?.intent, "Ship it")
        XCTAssertEqual(report.review?.specIsStale, true)
    }

    func testAFiledReportStaysFiled() {
        var report = report()
        report.reviewStatus = .filed
        report.acceptRationale()
        XCTAssertEqual(report.status, .filed)
        report.editReview { $0.intent = "New intent" }
        XCTAssertEqual(report.status, .filed)
    }

    func testStatusesFrom052StillRead() throws {
        for (raw, status) in [("read", RefinementStatus.inProgress), ("approved", .verified), ("followUp", .followUp), ("someday", .inProgress)] {
            let decoded = try JSONDecoder().decode([RefinementStatus].self, from: Data("[\"\(raw)\"]".utf8))
            XCTAssertEqual(decoded, [status], raw)
        }
    }

    // MARK: - Progress

    func testProgressCountsWhatIsLeftToDo() {
        var review = RefinementReview()
        review.items[RefinementItemRef.criterion(0).key] = .init(priority: .must, note: "Hard requirement")
        review.items[RefinementItemRef.criterion(2).key] = .init(isLeftOut: true)
        review.items[RefinementItemRef.question(0).key] = .init(resolution: "Exponential")
        review.added.append(.init(section: .criteria, text: "Audit log entry per retry"))
        let progress = review.progress(of: content())
        XCTAssertEqual(progress.prioritized, 1)
        XCTAssertEqual(progress.needingPriority, 3, "criterion 1, the constraint, and the added criterion")
        XCTAssertEqual(progress.openQuestions, 1)
        XCTAssertEqual(progress.notes, 1)
        XCTAssertEqual(progress.leftOut, 1)
    }

    // MARK: - The reviewed rationale

    func testReviewedRationaleIsWhatTheSpecIsWrittenFrom() {
        var review = RefinementReview()
        review.intent = "Retain certificates reliably."
        review.items[RefinementItemRef.criterion(0).key] = .init(priority: .must, note: "Hard requirement")
        review.items[RefinementItemRef.criterion(1).key] = .init(priority: .should, editedText: "Retention retried with backoff")
        review.items[RefinementItemRef.criterion(2).key] = .init(isLeftOut: true)
        review.items[RefinementItemRef.question(0).key] = .init(resolution: "Exponential, 5 tries")
        review.added.append(.init(section: .criteria, text: "Audit log entry per retry", review: .init(priority: .could)))
        review.added.append(.init(section: .constraints, text: "Removed later", review: .init(isLeftOut: true)))

        let text = RefinementReportMarkdown.rationale(content(), review: review)
        XCTAssertTrue(text.contains("## 1. Intent\n\nRetain certificates reliably."))
        XCTAssertTrue(text.contains("**[Must]** **EMERGENT** — Intake never waits on the retention call\n  - **Reviewer note:** Hard requirement"))
        XCTAssertTrue(text.contains("**[Should]** **EXPLICIT** — Retention retried with backoff"))
        XCTAssertFalse(text.contains("dashboard"), "left out")
        XCTAssertTrue(text.contains("**[Could]** **ADDED IN REVIEW** — Audit log entry per retry"))
        XCTAssertFalse(text.contains("Removed later"))
        XCTAssertTrue(text.contains("What retry backoff? _(owner: Liran)_\n  - **Resolved:** Exponential, 5 tries"))
        XCTAssertTrue(text.contains("Alert on permanent failure?\n  - **Unresolved**"))
    }

    func testTheSpecPromptCarriesTheReviewAndItsRules() {
        let prompt = AIPromptTemplates.refinementSpecPrompt(feature: "Certificate retention", rationale: "RATIONALE-BODY")
        XCTAssertTrue(prompt.contains("\"Certificate retention\""))
        XCTAssertTrue(prompt.contains("RATIONALE-BODY"))
        XCTAssertTrue(prompt.contains("never bring back anything"))
        XCTAssertFalse(prompt.contains("{{"))
    }

    func testTheFirstPassNoLongerWritesASpec() {
        let prompt = AIPromptTemplates.defaultText(for: .refinementReport)
        XCTAssertFalse(prompt.contains("\"spec\""))
    }

    func testSpecResponseParses() {
        let spec = RefinementSpecService.parse(response: """
        ```json
        {"intent":"Retain certificates reliably.","acceptance_criteria":["[Must] Intake never waits"],"decisions":["Outbox"],"constraints":[],"open_questions":["Alert on permanent failure?"]}
        ```
        """)
        XCTAssertEqual(spec?.acceptanceCriteria, ["[Must] Intake never waits"])
        XCTAssertEqual(spec?.openQuestions, ["Alert on permanent failure?"])
        XCTAssertNil(RefinementSpecService.parse(response: #"{"intent":"","acceptance_criteria":[]}"#), "an empty spec is a failed one")
    }

    func testExportsUseTheReviewedSpecOverTheDraft() {
        var report = report()
        report.content.spec = .init(intent: "Draft intent")
        XCTAssertEqual(report.effectiveSpec.intent, "Draft intent")
        XCTAssertTrue(report.specIsDraft)
        report.acceptRationale()
        report.storeSpec(.init(intent: "Reviewed intent"), modelIdentifier: "m")
        XCTAssertEqual(report.effectiveSpec.intent, "Reviewed intent")
        XCTAssertTrue(RefinementReportMarkdown.sections(report).contains("Reviewed intent"))
        XCTAssertFalse(RefinementReportMarkdown.sections(report).contains("Draft from the first pass"))
    }

    // MARK: - Priority board

    func testBucketsFileAndReadBack() {
        var review = RefinementItemReview()
        XCTAssertEqual(RefinementBucket(review), .unsorted)
        for bucket in RefinementBucket.allCases {
            bucket.apply(to: &review)
            XCTAssertEqual(RefinementBucket(review), bucket, bucket.label)
        }
        RefinementBucket.must.apply(to: &review)
        XCTAssertEqual(review.priority, .must)
        XCTAssertFalse(review.isLeftOut)
        RefinementBucket.ignore.apply(to: &review)
        XCTAssertTrue(review.isLeftOut, "Ignore keeps it out of the spec")
        XCTAssertNil(review.priority)
        RefinementBucket.unsorted.apply(to: &review)
        XCTAssertEqual(review, RefinementItemReview(), "back to To sort is back to untouched")
    }

    func testDragPayloadsRoundTrip() {
        let id = UUID()
        for target in [RefinementReviewTarget.item(.criterion(3)), .item(.constraint(0)), .added(id), .intent] {
            XCTAssertEqual(RefinementReviewTarget(payload: target.payload), target)
        }
        XCTAssertNil(RefinementReviewTarget(payload: "item:bogus:1"))
        XCTAssertNil(RefinementReviewTarget(payload: "some text dragged in from elsewhere"))
    }
}
