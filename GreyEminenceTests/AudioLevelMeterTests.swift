import XCTest
@testable import Grey_Eminence

/// The meter is what lets the capture loops stay off the main actor, and
/// the backlog arithmetic is what would have named the 2026-09-10 loss.
final class AudioLevelMeterTests: XCTestCase {

    func testLevelsAndCountsAccumulateWithoutTouchingTheMainActor() {
        let meter = AudioLevelMeter()
        meter.recordMic(level: 0.2)
        meter.recordSystem(level: 0.0001)
        meter.recordSystem(level: 0.05)
        let snapshot = meter.snapshot
        XCTAssertEqual(snapshot.micLevel, 0.2)
        XCTAssertEqual(snapshot.systemLevel, 0.05)
        XCTAssertEqual(snapshot.micConsumed, 1)
        XCTAssertEqual(snapshot.systemConsumed, 2)
    }

    func testSystemActivityIsOnlyNotedAboveTheFloor() {
        let meter = AudioLevelMeter()
        meter.recordSystem(level: 0.0001)
        XCTAssertNil(meter.snapshot.lastSystemActivity, "room tone is not activity")
        meter.recordSystem(level: 0.01)
        XCTAssertNotNil(meter.snapshot.lastSystemActivity)
    }

    func testResetClearsEverything() {
        let meter = AudioLevelMeter()
        meter.recordMic(level: 0.3)
        meter.recordSystem(level: 0.3)
        meter.reset()
        XCTAssertEqual(meter.snapshot, AudioLevelMeter.Snapshot())
    }

    /// 512-frame buffers at 48 kHz: the shape of the system tap.
    func testBacklogSecondsFromTheSystemTapsBufferShape() {
        let nineMinutes = 9 * 60 * 48000 / 512
        let seconds = AudioLevelMeter.backlogSeconds(buffers: nineMinutes, framesPerBuffer: 512, sampleRate: 48000)
        XCTAssertEqual(seconds, 540, accuracy: 0.5)
        XCTAssertGreaterThan(seconds, AudioLevelMeter.backlogWarningSeconds)
    }

    func testBacklogNeverGoesNegativeAndAHealthyLoopIsQuiet() {
        XCTAssertEqual(AudioLevelMeter.backlog(delivered: 100, consumed: 103), 0)
        let healthy = AudioLevelMeter.backlogSeconds(buffers: AudioLevelMeter.backlog(delivered: 1000, consumed: 998), framesPerBuffer: 512, sampleRate: 48000)
        XCTAssertLessThan(healthy, AudioLevelMeter.backlogWarningSeconds)
        XCTAssertEqual(AudioLevelMeter.backlogSeconds(buffers: 5, framesPerBuffer: 512, sampleRate: 0), 0)
    }

    /// Concurrent writers from two loops must not lose counts.
    func testConcurrentRecordingIsSafe() async {
        let meter = AudioLevelMeter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { for _ in 0..<1000 { meter.recordSystem(level: 0.1) } }
                group.addTask { for _ in 0..<1000 { meter.recordMic(level: 0.1) } }
            }
        }
        XCTAssertEqual(meter.snapshot.systemConsumed, 4000)
        XCTAssertEqual(meter.snapshot.micConsumed, 4000)
    }
}
