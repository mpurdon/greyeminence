import XCTest
@testable import Grey_Eminence

/// Policy pieces of the re-processing queue that cost real time when wrong
/// (2026-09-11: an 87-minute meeting transcribed twice, a resume from zero).
@MainActor
final class ReProcessingQueuePolicyTests: XCTestCase {

    func testOnlyTranscriptionYieldsToALiveRecording() {
        XCTAssertTrue(ReProcessingQueue.isYieldable(.queued))
        XCTAssertTrue(ReProcessingQueue.isYieldable(.transcribing))
        for phase in [ReProcessingState.correcting, .analyzing, .reindexing, .cancelling, .failed] {
            XCTAssertFalse(ReProcessingQueue.isYieldable(phase), "\(phase) is short and off the Neural Engine — let it finish")
        }
    }

    func testLiveLoadIsHealthyOnlyWhenBothBacklogsAreSmall() {
        typealias Load = RecordingViewModel.LiveLoad
        XCTAssertTrue(Load(audioBacklogSeconds: 0.1, recognitionBacklogSeconds: 0.5, secondsSinceStart: 200).isHealthy)
        XCTAssertFalse(Load(audioBacklogSeconds: 3, recognitionBacklogSeconds: 0, secondsSinceStart: 200).isHealthy, "the writer is behind")
        XCTAssertFalse(Load(audioBacklogSeconds: 0, recognitionBacklogSeconds: 2.5, secondsSinceStart: 200).isHealthy, "live recognition is behind")
    }

    func testBackgroundWorkWaitsOutTheModelLoadingWindow() {
        XCTAssertEqual(ReProcessingQueue.recordingGrace, 90)
    }

    func testRunningDuringRecordingsIsOnByDefault() {
        let defaults = UserDefaults(suiteName: "ReProcessingQueuePolicyTests")!
        defaults.removePersistentDomain(forName: "ReProcessingQueuePolicyTests")
        XCTAssertNil(defaults.object(forKey: ReProcessingQueue.runsDuringRecordingKey))
        XCTAssertTrue(ReProcessingQueue.runsDuringRecording || UserDefaults.standard.object(forKey: ReProcessingQueue.runsDuringRecordingKey) != nil)
    }
}
