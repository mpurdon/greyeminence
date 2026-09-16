import XCTest
@testable import Grey_Eminence

/// Pure tests for the AI task tidy-up: response parsing (which must survive
/// what a model actually returns), decision resolution (which must never
/// delete an item something else folds into), and the safety cap.
final class TaskTriageTests: XCTestCase {

    private typealias Decision = TaskTriageService.Decision

    // MARK: - Parsing

    func testParsesEveryActionShape() {
        let response = """
        {"decisions":[
          {"id":"T1","action":"keep","priority":"high"},
          {"id":"T2","action":"duplicate","of":"T1"},
          {"id":"T3","action":"remove","reason":"not a task"},
          {"id":"T4","action":"duplicate","of":"C2"}
        ]}
        """
        let decisions = TaskTriageService.parse(response: response)
        XCTAssertEqual(decisions, [
            Decision(index: 0, action: .keep(.high)),
            Decision(index: 1, action: .duplicate(of: .pending(0))),
            Decision(index: 2, action: .remove(reason: "not a task")),
            Decision(index: 3, action: .duplicate(of: .completed(1))),
        ])
    }

    func testParseToleratesFencesCaseAndMissingPriority() {
        let response = """
        ```json
        {"decisions":[{"id":"t1","action":"Keep","priority":"HIGH"},{"id":"T2","action":"keep"}]}
        ```
        """
        let decisions = TaskTriageService.parse(response: response)
        XCTAssertEqual(decisions, [
            Decision(index: 0, action: .keep(.high)),
            Decision(index: 1, action: .keep(.medium)),
        ])
    }

    func testParseDropsMalformedEntriesButNotTheWholeResponse() {
        let response = """
        {"decisions":[
          {"id":"T1","action":"keep","priority":"low"},
          {"id":"X9","action":"keep"},
          {"id":"T2","action":"archive"},
          {"id":"T3","action":"duplicate"},
          {"action":"remove"}
        ]}
        """
        XCTAssertEqual(TaskTriageService.parse(response: response), [
            Decision(index: 0, action: .keep(.low)),
        ])
    }

    func testParseReturnsNilWithoutDecisionsArray() {
        XCTAssertNil(TaskTriageService.parse(response: "I could not rate these."))
        XCTAssertNil(TaskTriageService.parse(response: "{\"items\":[]}"))
    }

    // MARK: - Resolution

    func testResolveSortsDecisionsIntoThePlan() {
        let plan = TaskTriageService.resolve([
            Decision(index: 0, action: .keep(.high)),
            Decision(index: 1, action: .duplicate(of: .pending(0))),
            Decision(index: 2, action: .remove(reason: "agenda line")),
            Decision(index: 3, action: .duplicate(of: .completed(0))),
        ], pendingCount: 4, completedCount: 1)

        XCTAssertEqual(plan.priorities, [0: .high])
        XCTAssertEqual(plan.merges, [1: 0])
        XCTAssertEqual(plan.removals, [2: "agenda line"])
        XCTAssertEqual(plan.closures, [3: 0])
        XCTAssertEqual(plan.deletionCount, 3)
    }

    func testResolveIgnoresOutOfRangeIndices() {
        let plan = TaskTriageService.resolve([
            Decision(index: 5, action: .remove(reason: "")),
            Decision(index: 0, action: .duplicate(of: .pending(7))),
            Decision(index: 1, action: .duplicate(of: .completed(3))),
        ], pendingCount: 2, completedCount: 1)
        XCTAssertEqual(plan, TaskTriageService.Plan())
    }

    func testResolveFlattensDuplicateChains() {
        // T3 → T2 → T1 (kept): both fold into T1, never into each other.
        let plan = TaskTriageService.resolve([
            Decision(index: 0, action: .keep(.medium)),
            Decision(index: 1, action: .duplicate(of: .pending(0))),
            Decision(index: 2, action: .duplicate(of: .pending(1))),
        ], pendingCount: 3, completedCount: 0)
        XCTAssertEqual(plan.merges, [1: 0, 2: 0])
    }

    func testResolveChainEndingInCompletedBecomesClosure() {
        let plan = TaskTriageService.resolve([
            Decision(index: 0, action: .duplicate(of: .completed(0))),
            Decision(index: 1, action: .duplicate(of: .pending(0))),
        ], pendingCount: 2, completedCount: 1)
        XCTAssertEqual(plan.closures, [0: 0, 1: 0])
        XCTAssertTrue(plan.merges.isEmpty)
    }

    func testResolveKeepsDuplicateWhoseCanonicalIsRemoved() {
        // Folding into something that is itself deleted would lose the item
        // twice over — the conservative reading is to leave it alone.
        let plan = TaskTriageService.resolve([
            Decision(index: 0, action: .remove(reason: "noise")),
            Decision(index: 1, action: .duplicate(of: .pending(0))),
        ], pendingCount: 2, completedCount: 0)
        XCTAssertEqual(plan.removals, [0: "noise"])
        XCTAssertTrue(plan.merges.isEmpty)
        XCTAssertNil(plan.priorities[1])
    }

    func testResolveBreaksCyclesAndSelfReferences() {
        let plan = TaskTriageService.resolve([
            Decision(index: 0, action: .duplicate(of: .pending(1))),
            Decision(index: 1, action: .duplicate(of: .pending(0))),
            Decision(index: 2, action: .duplicate(of: .pending(2))),
        ], pendingCount: 3, completedCount: 0)
        XCTAssertEqual(plan, TaskTriageService.Plan())
    }

    func testResolveDuplicateOfUnmentionedItemStillMerges() {
        // The model skipped T1 entirely but folded T2 into it — T1 survives
        // unrated, so the merge is safe.
        let plan = TaskTriageService.resolve([
            Decision(index: 1, action: .duplicate(of: .pending(0))),
        ], pendingCount: 2, completedCount: 0)
        XCTAssertEqual(plan.merges, [1: 0])
    }

    func testLaterDecisionForSameIdWins() {
        let plan = TaskTriageService.resolve([
            Decision(index: 0, action: .remove(reason: "")),
            Decision(index: 0, action: .keep(.low)),
        ], pendingCount: 1, completedCount: 0)
        XCTAssertEqual(plan.priorities, [0: .low])
        XCTAssertTrue(plan.removals.isEmpty)
    }

    // MARK: - Safety cap

    func testDeletionCapHasAFloorForSmallListsAndAShareForLarge() {
        XCTAssertEqual(TaskTriageService.deletionCap(for: 1), 5)
        XCTAssertEqual(TaskTriageService.deletionCap(for: 8), 5)
        XCTAssertEqual(TaskTriageService.deletionCap(for: 10), 6)
        XCTAssertEqual(TaskTriageService.deletionCap(for: 100), 60)
    }

    // MARK: - Rendering

    func testRenderPendingNumbersItemsAndReportsAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rendered = TaskTriageService.renderPending([
            .init(text: "Send the \"deck\" to Priya", assignee: "Matthew", meetingTitle: "Weekly sync", meetingDate: now.addingTimeInterval(-3 * 86_400), createdAt: now.addingTimeInterval(-3 * 86_400)),
            .init(text: "Look into\nit", createdAt: now),
        ], now: now)
        let lines = rendered.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("T1 | \"Send the 'deck' to Priya\" | assignee: Matthew | from: \"Weekly sync\" ("))
        XCTAssertTrue(lines[0].hasSuffix("| age: 3d"))
        XCTAssertEqual(lines[1], "T2 | \"Look into it\" | assignee: unassigned | age: 0d")
    }

    func testRenderEmptyListsSayNone() {
        XCTAssertEqual(TaskTriageService.renderPending([], now: .now), "(none)")
        XCTAssertEqual(TaskTriageService.renderCompleted([]), "(none)")
    }

    // MARK: - Report

    func testSummaryMentionsOnlyWhatHappened() {
        var report = TaskTriageService.Report(evaluated: 4, high: 1, medium: 2, low: 1)
        XCTAssertEqual(report.summary, "4 tasks rated (1 high, 2 medium, 1 low)")
        report.merged = 1
        report.removed = 2
        report.deletionsHeld = 0
        XCTAssertEqual(report.summary, "4 tasks rated (1 high, 2 medium, 1 low), 1 duplicate merged, 2 marked Won't Do")
        XCTAssertEqual(TaskTriageService.Report(skipped: true).summary, "No open tasks to tidy.")
    }
}
