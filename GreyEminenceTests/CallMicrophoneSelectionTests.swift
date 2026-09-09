import XCTest
@testable import Grey_Eminence

/// The recorder follows the call app's microphone. Pure policy over the
/// holders the detector reports — no Core Audio here.
@MainActor
final class CallMicrophoneSelectionTests: XCTestCase {

    private let yeti = MeetingDetectionService.InputDevice(uid: "LogiGamingAudio:Yeti", name: "Yeti Stereo Microphone")
    private let builtIn = MeetingDetectionService.InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")

    private func holder(
        _ bundleID: String?,
        device: MeetingDetectionService.InputDevice? = nil,
        pid: pid_t = 501
    ) -> MeetingDetectionService.MicHolder {
        .init(pid: pid, bundleID: bundleID, appName: MeetingAppRegistry.displayName(for: bundleID), inputDevice: device)
    }

    func testTheCallAppsMicrophoneIsChosen() {
        let holders = [holder("com.microsoft.teams2", device: yeti)]
        XCTAssertEqual(MeetingDetectionService.captureDevice(for: holders), yeti)
    }

    func testNothingListeningMeansTheSettingsChoiceApplies() {
        XCTAssertNil(MeetingDetectionService.captureDevice(for: []))
    }

    func testAHolderWithoutAReportedDeviceFallsThroughToOneThatHasOne() {
        // Teams is the call, but reported no device this poll; Discord is idle
        // in a channel on the same Yeti. Better the Yeti than the laptop mic.
        let holders = [
            holder("com.microsoft.teams2", device: nil, pid: 1),
            holder("com.hnc.Discord", device: yeti, pid: 2),
        ]
        XCTAssertEqual(MeetingDetectionService.captureDevice(for: holders), yeti)
    }

    func testTheCallWinsOverAnIdleAppOnADifferentMicrophone() {
        // Discord sits in a channel on the built-in mic; the Teams call is on
        // the Yeti. The call is what is being recorded.
        let holders = [
            holder("com.hnc.Discord", device: builtIn, pid: 1),
            holder("com.microsoft.teams2", device: yeti, pid: 2),
        ]
        XCTAssertEqual(MeetingDetectionService.captureDevice(for: holders), yeti)
    }

    func testUnknownAppWithADeviceStillCounts() {
        let holders = [holder("com.example.newmeetingapp", device: yeti)]
        XCTAssertEqual(MeetingDetectionService.captureDevice(for: holders), yeti)
    }

    func testHoldersWithoutAnyDeviceYieldNothing() {
        let holders = [holder("com.microsoft.teams2"), holder("com.hnc.Discord", pid: 2)]
        XCTAssertNil(MeetingDetectionService.captureDevice(for: holders))
    }

    func testFollowingTheCallMicrophoneIsOnByDefaultAndCanBeTurnedOff() {
        let defaults = UserDefaults(suiteName: "CallMicrophoneSelectionTests")!
        defaults.removePersistentDomain(forName: "CallMicrophoneSelectionTests")
        XCTAssertTrue(MeetingDetectionService.followsCallMicrophone(in: defaults), "an unset key means on")
        defaults.set(false, forKey: MeetingDetectionService.followCallMicrophoneKey)
        XCTAssertFalse(MeetingDetectionService.followsCallMicrophone(in: defaults))
        defaults.removePersistentDomain(forName: "CallMicrophoneSelectionTests")
    }
}
