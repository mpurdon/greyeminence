import XCTest
@testable import Grey_Eminence

/// A recording is bound to the app whose call it is and ends when that app
/// lets go of the microphone — however the recording was started. Drives the
/// detector's poll with synthetic holders; no Core Audio here.
@MainActor
final class MeetingAutoStopTests: XCTestCase {

    private let yeti = MeetingDetectionService.InputDevice(uid: "LogiGamingAudio:Yeti", name: "Yeti Stereo Microphone")
    private let builtIn = MeetingDetectionService.InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")

    private var detector: MeetingDetectionService!
    private var clock: Date!
    private var stopRequests = 0
    private var deviceChanges: [MeetingDetectionService.MicHolder] = []

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSince1970: 1_000_000)
        stopRequests = 0
        deviceChanges = []
        detector = MeetingDetectionService(pollsAutomatically: false)
        detector.now = { [unowned self] in self.clock }
        detector.onStopRequested = { [unowned self] in self.stopRequests += 1 }
        detector.onSourceDeviceChanged = { [unowned self] in self.deviceChanges.append($0) }
        detector.enable(currentlyRecording: false)
    }

    override func tearDown() {
        detector.disable()
        detector = nil
        super.tearDown()
    }

    private func holder(
        _ bundleID: String?,
        device: MeetingDetectionService.InputDevice? = nil,
        pid: pid_t = 501
    ) -> MeetingDetectionService.MicHolder {
        .init(pid: pid, bundleID: bundleID, appName: MeetingAppRegistry.displayName(for: bundleID), inputDevice: device)
    }

    private func teams(on device: MeetingDetectionService.InputDevice? = nil) -> MeetingDetectionService.MicHolder {
        holder("com.microsoft.teams2.modulehost", device: device, pid: 100)
    }

    private func discord(on device: MeetingDetectionService.InputDevice? = nil) -> MeetingDetectionService.MicHolder {
        holder("com.hnc.Discord.helper.Renderer", device: device, pid: 200)
    }

    /// Polls every 5s for `seconds`, advancing the clock, with `holders` on the mic.
    private func poll(_ holders: [MeetingDetectionService.MicHolder], for seconds: TimeInterval) {
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            clock = clock.addingTimeInterval(5)
            elapsed += 5
            detector.apply(holders)
        }
    }

    // MARK: - Binding

    func testAManualRecordingDuringACallIsBoundToThatCall() {
        detector.noteStart(holders: [teams(on: yeti)])
        XCTAssertEqual(detector.mode, .tracking)
        XCTAssertEqual(detector.trackedHolder, teams(on: yeti))
    }

    func testASoloRecordingTracksNothing() {
        detector.noteStart(holders: [])
        XCTAssertEqual(detector.mode, .passive)
        XCTAssertNil(detector.trackedHolder)
    }

    /// Discord parked in a channel while a Teams call runs: the recording is
    /// of the Teams call, so that is what it is bound to.
    func testTheCallWinsOverAnIdleAppForBinding() {
        detector.noteStart(holders: [discord(on: yeti), teams(on: yeti)])
        XCTAssertEqual(detector.trackedHolder?.bundleID, "com.microsoft.teams2.modulehost")
    }

    // MARK: - Stopping

    func testRecordingStopsSixtySecondsAfterTheCallAppReleasesTheMic() {
        detector.noteStart(holders: [teams(on: yeti)])
        poll([teams(on: yeti)], for: 600)
        XCTAssertEqual(stopRequests, 0)

        poll([], for: 55)
        XCTAssertEqual(stopRequests, 0, "still inside the stop debounce")
        poll([], for: 10)
        XCTAssertEqual(stopRequests, 1)
    }

    /// The failure mode this replaces: a Teams call that ends while Discord
    /// still sits in a voice channel used to keep the recording alive forever.
    func testAnotherAppStillOnTheMicDoesNotKeepTheRecordingAlive() {
        detector.noteStart(holders: [discord(on: yeti), teams(on: yeti)])
        poll([discord(on: yeti), teams(on: yeti)], for: 300)
        poll([discord(on: yeti)], for: 65)
        XCTAssertEqual(stopRequests, 1)
    }

    /// Teams opens the built-in microphone first and moves to the chosen one
    /// a few seconds later. Same app, same call — follow it, don't stop.
    func testTheCallSwitchingMicrophonesIsFollowedNotEnded() {
        detector.noteStart(holders: [teams(on: builtIn)])
        poll([teams(on: yeti)], for: 120)
        XCTAssertEqual(stopRequests, 0)
        XCTAssertEqual(detector.trackedHolder?.inputDevice, yeti, "tracked device follows the app")
        XCTAssertEqual(deviceChanges.map(\.inputDevice), [yeti], "the recorder is told once, not every poll")
    }

    /// A poll that reports the app without a device (Core Audio has nothing
    /// to say this tick) keeps the last known microphone.
    func testATransientlyMissingDeviceKeepsTheLastKnownOne() {
        detector.noteStart(holders: [teams(on: yeti)])
        poll([teams(on: nil)], for: 10)
        XCTAssertEqual(detector.trackedHolder?.inputDevice, yeti)
        XCTAssertTrue(deviceChanges.isEmpty)
    }

    /// Discord idling on the built-in mic is not the call; its device is
    /// not what the recorder should follow.
    func testAnotherAppsDeviceChangeIsIgnored() {
        detector.noteStart(holders: [teams(on: yeti), discord(on: yeti)])
        poll([teams(on: yeti), discord(on: builtIn)], for: 10)
        XCTAssertTrue(deviceChanges.isEmpty)
    }

    func testABriefDropoutDoesNotStopTheRecording() {
        detector.noteStart(holders: [teams(on: yeti)])
        poll([], for: 40)
        poll([teams(on: yeti)], for: 10)
        poll([], for: 40)
        XCTAssertEqual(stopRequests, 0, "the debounce restarts when the app comes back")
    }

    /// The app may be relaunched between polls; bundle identity is what binds.
    func testTheSameAppUnderANewPidStillCounts() {
        detector.noteStart(holders: [teams(on: yeti)])
        let relaunched = holder("com.microsoft.teams2.modulehost", device: yeti, pid: 999)
        poll([relaunched], for: 120)
        XCTAssertEqual(stopRequests, 0)
    }

    func testAnUnnamedProcessIsTrackedByPid() {
        detector.noteStart(holders: [holder(nil, device: yeti, pid: 42)])
        poll([holder(nil, device: yeti, pid: 42)], for: 60)
        XCTAssertEqual(stopRequests, 0)
        poll([holder(nil, device: yeti, pid: 43)], for: 65)
        XCTAssertEqual(stopRequests, 1, "a different unnamed process is not the same call")
    }

    /// Nothing was on the mic when a solo recording began; an app that comes
    /// and goes during it is not this recording's call.
    func testASoloRecordingNeverAutoStops() {
        detector.noteStart(holders: [])
        poll([teams(on: yeti)], for: 60)
        poll([], for: 120)
        XCTAssertEqual(stopRequests, 0)
        XCTAssertEqual(detector.mode, .passive)
    }

    // MARK: - Re-arming

    func testStoppingClearsTheBindingAndReArms() {
        detector.noteStart(holders: [teams(on: yeti)])
        detector.noteStop(.auto)
        XCTAssertEqual(detector.mode, .armedForStart)
        XCTAssertNil(detector.trackedHolder)
    }
}
