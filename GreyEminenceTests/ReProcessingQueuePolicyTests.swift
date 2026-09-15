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

    // MARK: - Status bar detail

    private func job(_ phase: ReProcessingState, done: Int = 0, total: Int = 0, warmingUp: Bool = false) -> ReProcessingQueue.RunningJob {
        var job = ReProcessingQueue.RunningJob(id: UUID(), title: "t", phase: phase)
        job.chunksDone = done
        job.chunksTotal = total
        job.isWarmingUp = warmingUp
        return job
    }

    /// A 12-minute Neural Engine compile before the first chunk looked like a
    /// hang on 2026-09-14, and the cancel that followed looked ignored.
    func testWarmUpIsNamedWhileNoChunkHasFinished() {
        XCTAssertTrue(job(.transcribing, total: 18, warmingUp: true).detailText.contains("Neural Engine"))
        XCTAssertTrue(job(.cancelling, warmingUp: true).detailText.contains("can't be interrupted"))
    }

    /// Once the first chunk lands, warm-up is cleared (see
    /// `updateTranscriptionProgress` / `jobTick`), so progress shows.
    func testChunkProgressShowsOnceWarmUpClears() {
        let text = job(.transcribing, done: 3, total: 18, warmingUp: false).detailText
        XCTAssertTrue(text.contains("3/18 chunks (16%)"), text)
        XCTAssertFalse(text.contains("Neural Engine"))
    }

    func testOtherPhasesUseTheirStepDescription() {
        XCTAssertEqual(job(.analyzing).detailText, ReProcessingState.analyzing.stepDescription)
        XCTAssertEqual(job(.cancelling).detailText, ReProcessingState.cancelling.stepDescription)
        XCTAssertEqual(job(.transcribing).detailText, ReProcessingState.transcribing.stepDescription, "inside the grace period, nothing special")
    }

}
