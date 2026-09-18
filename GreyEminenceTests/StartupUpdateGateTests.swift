import XCTest
@testable import Grey_Eminence

/// The launch gate must release on every answer the updater can give, never
/// release on a successful install, and never hang when nothing answers.
@MainActor
final class StartupUpdateGateTests: XCTestCase {

    private let fast: Duration = .milliseconds(50)
    private let never: Duration = .seconds(30)

    func testReturnsAtOnceWhenAlreadyDecided() async {
        let gate = StartupUpdateGate()
        gate.noUpdateFound()
        let outcome = await gate.waitForDecision(checkTimeout: never, choiceTimeout: never)
        XCTAssertEqual(outcome, .upToDate)
    }

    func testDebugBuildSkipReleasesImmediately() async {
        let gate = StartupUpdateGate()
        gate.checkSkipped()
        let outcome = await gate.waitForDecision(checkTimeout: never, choiceTimeout: never)
        XCTAssertEqual(outcome, .notChecked)
    }

    func testReleasesWhenAnswerArrivesWhileWaiting() async {
        let gate = StartupUpdateGate()
        let waiter = Task { await gate.waitForDecision(checkTimeout: never, choiceTimeout: never) }
        await Task.yield()
        gate.checkFailed()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .checkFailed)
    }

    func testCheckTimesOutWhenNothingAnswers() async {
        let gate = StartupUpdateGate()
        let outcome = await gate.waitForDecision(checkTimeout: fast, choiceTimeout: never)
        XCTAssertEqual(outcome, .timedOut)
    }

    func testUpdateFoundStopsTheCheckClockAndWaitsForTheChoice() async {
        let gate = StartupUpdateGate()
        gate.updateFound()
        let waiter = Task { await gate.waitForDecision(checkTimeout: fast, choiceTimeout: never) }
        // Well past the check timeout — the alert is up, so still waiting.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(gate.outcome)
        gate.userDeclinedUpdate()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .updateDeclined)
    }

    func testUnansweredAlertEventuallyReleases() async {
        let gate = StartupUpdateGate()
        gate.updateFound()
        let outcome = await gate.waitForDecision(checkTimeout: fast, choiceTimeout: fast)
        XCTAssertEqual(outcome, .timedOut)
    }

    func testInstallKeepsTheGateClosed() async {
        let gate = StartupUpdateGate()
        gate.updateFound()
        gate.userChoseInstall()
        let waiter = Task { await gate.waitForDecision(checkTimeout: fast, choiceTimeout: fast) }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(gate.outcome, "an install in progress must not start the launch sequence")
        // A failed install reopens it so the app is not stuck idle.
        gate.installFailed()
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .checkFailed)
    }

    func testDeferredUpdateReleases() async {
        let gate = StartupUpdateGate()
        gate.updateFound()
        gate.updateDeferred()
        let outcome = await gate.waitForDecision(checkTimeout: never, choiceTimeout: never)
        XCTAssertEqual(outcome, .notChecked)
    }

    func testFirstDecisionWins() async {
        let gate = StartupUpdateGate()
        gate.noUpdateFound()
        gate.checkFailed()
        gate.updateFound()
        XCTAssertEqual(gate.outcome, .upToDate)
    }

    func testChoiceEventsBeforeAnUpdateIsFoundAreIgnored() async {
        let gate = StartupUpdateGate()
        gate.userDeclinedUpdate()
        gate.userChoseInstall()
        XCTAssertNil(gate.outcome)
        gate.noUpdateFound()
        XCTAssertEqual(gate.outcome, .upToDate)
    }
}
