import XCTest
@testable import Grey_Eminence

/// The suggested filename for a saved segment clip. Pure string work.
final class SegmentAudioClipTests: XCTestCase {

    func testFilenameCarriesMeetingMomentAndSpeaker() {
        let name = SegmentAudioPlayer.clipFilename(meetingTitle: "Design Review", segmentStart: 754, speaker: "Speaker 2")
        XCTAssertEqual(name, "Design Review \u{2014} 12m34s Speaker 2.m4a")
    }

    func testHoursAppearOnlyWhenNeeded() {
        XCTAssertTrue(SegmentAudioPlayer.clipFilename(meetingTitle: "M", segmentStart: 3725, speaker: "Me").contains("1h02m05s"))
        XCTAssertTrue(SegmentAudioPlayer.clipFilename(meetingTitle: "M", segmentStart: 5, speaker: "Me").contains("0m05s"))
    }

    /// The default meeting title is "Meeting 2026-09-14, 3:42 PM" — a colon
    /// Finder would render as a slash — and titles can contain paths' slashes.
    func testFilesystemHostileCharactersAreReplaced() {
        let name = SegmentAudioPlayer.clipFilename(meetingTitle: "Meeting 2026-09-14, 3:42 PM / sync", segmentStart: 0, speaker: "Me")
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.dropLast(4).contains("/"))
        XCTAssertTrue(name.hasSuffix(".m4a"))
    }

    func testVeryLongTitlesAreTruncated() {
        let name = SegmentAudioPlayer.clipFilename(meetingTitle: String(repeating: "x", count: 500), segmentStart: 0, speaker: "Me")
        XCTAssertLessThanOrEqual(name.count, 204)
    }
}
