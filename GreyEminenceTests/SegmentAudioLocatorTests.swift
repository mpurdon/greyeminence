import XCTest
@testable import Grey_Eminence

/// Chunk arithmetic for segment playback. Chunk lengths are injected, so
/// these pin the boundary behaviour without touching audio files.
final class SegmentAudioLocatorTests: XCTestCase {

    private let chunks = (0..<4).map { URL(fileURLWithPath: "/audio/mic.part00\($0).m4a") }
    /// 10 s, 10 s, 10 s, 10 s laid end to end.
    private func tenSeconds(_ url: URL) -> TimeInterval { 10 }

    func testWindowInsideOneChunkYieldsOneSlice() {
        let slices = SegmentAudioLocator.slices(covering: 12...15, chunks: chunks, length: tenSeconds)
        XCTAssertEqual(slices, [.init(url: chunks[1], start: 2, end: 5)])
    }

    func testWindowAcrossAChunkBoundaryYieldsBothPartsInOrder() {
        let slices = SegmentAudioLocator.slices(covering: 18...23, chunks: chunks, length: tenSeconds)
        XCTAssertEqual(slices, [
            .init(url: chunks[1], start: 8, end: 10),
            .init(url: chunks[2], start: 0, end: 3),
        ])
        XCTAssertEqual(slices.map(\.duration).reduce(0, +), 5, accuracy: 0.001)
    }

    func testWindowBeyondTheRecordingIsEmpty() {
        XCTAssertTrue(SegmentAudioLocator.slices(covering: 50...55, chunks: chunks, length: tenSeconds).isEmpty)
        XCTAssertTrue(SegmentAudioLocator.slices(covering: 1...2, chunks: [], length: tenSeconds).isEmpty)
    }

    func testWindowRunningPastTheEndIsClippedToWhatExists() {
        let slices = SegmentAudioLocator.slices(covering: 38...45, chunks: chunks, length: tenSeconds)
        XCTAssertEqual(slices, [.init(url: chunks[3], start: 8, end: 10)])
    }

    /// The same timeline re-processing uses: an unreadable chunk still costs
    /// its (fallback) length, so everything after it stays in place.
    func testUnevenChunkLengthsShiftLaterSlices() {
        let lengths: [URL: TimeInterval] = [chunks[0]: 8, chunks[1]: 12, chunks[2]: 9, chunks[3]: 10]
        let slices = SegmentAudioLocator.slices(covering: 21...25, chunks: chunks, length: { lengths[$0]! })
        // 0–8, 8–20, 20–29: the window sits in chunk 2 at 1…5.
        XCTAssertEqual(slices, [.init(url: chunks[2], start: 1, end: 5)])
    }

    func testZeroLengthChunkIsSkippedWithoutAdvancingTheClock() {
        let lengths: [URL: TimeInterval] = [chunks[0]: 10, chunks[1]: 0, chunks[2]: 10, chunks[3]: 10]
        let slices = SegmentAudioLocator.slices(covering: 12...14, chunks: chunks, length: { lengths[$0]! })
        XCTAssertEqual(slices, [.init(url: chunks[2], start: 2, end: 4)])
    }

    func testWindowPadsBothEndsAndAppliesTheMeetingOffset() {
        let window = SegmentAudioLocator.window(segmentStart: 100, segmentEnd: 103, offset: 500)
        XCTAssertEqual(window.lowerBound, 600 - SegmentAudioLocator.padding, accuracy: 0.001)
        XCTAssertEqual(window.upperBound, 603 + SegmentAudioLocator.padding, accuracy: 0.001)
    }

    func testWindowNeverStartsBeforeZeroAndNeverCollapses() {
        let atStart = SegmentAudioLocator.window(segmentStart: 0.1, segmentEnd: 0.1, offset: 0)
        XCTAssertEqual(atStart.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(atStart.upperBound - atStart.lowerBound, SegmentAudioLocator.minimumDuration)
        // An end before its start (a mangled segment) still plays something.
        let inverted = SegmentAudioLocator.window(segmentStart: 30, segmentEnd: 20, offset: 0)
        XCTAssertGreaterThan(inverted.upperBound, inverted.lowerBound)
    }

    @MainActor
    func testSpeakerTrackFollowsWhoWasTalking() {
        XCTAssertEqual(SegmentAudioPlayer.sources(for: .speaker, isMe: true), [.mic])
        XCTAssertEqual(SegmentAudioPlayer.sources(for: .speaker, isMe: false), [.system])
        XCTAssertEqual(SegmentAudioPlayer.sources(for: .both, isMe: true), [.mic, .system])
        XCTAssertEqual(SegmentAudioPlayer.sources(for: .system, isMe: true), [.system])
    }
}
