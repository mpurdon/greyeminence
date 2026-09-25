import XCTest
@testable import Grey_Eminence

@MainActor
final class InstanceGuardTests: XCTestCase {
    func testTheDevelopmentBuildWins() {
        XCTAssertEqual(InstanceGuard.decide(me: .released, others: [.development], recording: false), .yieldToDevelopment)
        XCTAssertEqual(InstanceGuard.decide(me: .released, others: [.development], recording: true), .yieldToDevelopment,
                       "a released copy opening mid-call still gives way")
        XCTAssertEqual(InstanceGuard.decide(me: .development, others: [.released], recording: false), .offerToQuitReleased(isRecording: false))
        XCTAssertEqual(InstanceGuard.decide(me: .development, others: [.released], recording: true), .offerToQuitReleased(isRecording: true))
    }

    func testAloneOrAlongsideTheSameKindProceeds() {
        XCTAssertEqual(InstanceGuard.decide(me: .released, others: [], recording: false), .proceed)
        XCTAssertEqual(InstanceGuard.decide(me: .development, others: [.development], recording: false), .proceed)
        XCTAssertEqual(InstanceGuard.decide(me: .released, others: [.released], recording: false), .proceed)
    }

    func testTheTestHostKnowsItsBuild() {
        // Tests run a Debug build; a bundle without the key is a released one.
        XCTAssertEqual(InstanceGuard.build(of: .main), .development)
        XCTAssertEqual(InstanceGuard.build(of: nil), .released)
    }
}
