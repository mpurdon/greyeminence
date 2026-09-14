import CoreGraphics
import ImageIO
import XCTest
@testable import Grey_Eminence

/// Pure, offline tests for frame triage (dHash, keep rule, visual-only
/// change detection, scaling), share-session grouping, and Teams window
/// scoring. No ScreenCaptureKit, no SwiftData.
final class ScreenFrameTriageTests: XCTestCase {

    // MARK: - Test images

    /// Solid-color image.
    private func solidImage(gray: UInt8, width: Int = 64, height: Int = 48) -> CGImage {
        image(width: width, height: height) { _, _ in gray }
    }

    /// Horizontal gradient — every row has monotone left-to-right increase.
    private func gradientImage(width: Int = 64, height: Int = 48, reversed: Bool = false) -> CGImage {
        image(width: width, height: height) { x, _ in
            let v = UInt8(min(255, x * 256 / width))
            return reversed ? 255 - v : v
        }
    }

    /// Top-half white, bottom-half black.
    private func splitImage(width: Int = 64, height: Int = 48) -> CGImage {
        image(width: width, height: height) { _, y in y < height / 2 ? 255 : 0 }
    }

    private func image(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = pixel(x, y)
            }
        }
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        return context.makeImage()!
    }

    // MARK: - dHash

    func testDHashIsStableForIdenticalImages() {
        let a = ScreenFrameTriage.dHash(gradientImage())
        let b = ScreenFrameTriage.dHash(gradientImage())
        XCTAssertEqual(a, b)
    }

    func testDHashOfSolidImageIsZero() {
        // No pixel is brighter than its right neighbor in a solid image.
        XCTAssertEqual(ScreenFrameTriage.dHash(solidImage(gray: 128)), 0)
    }

    func testDHashDiffersForOppositeGradients() {
        let a = ScreenFrameTriage.dHash(gradientImage())
        let b = ScreenFrameTriage.dHash(gradientImage(reversed: true))
        // A reversed gradient flips every comparison — distance should be large.
        XCTAssertGreaterThanOrEqual(ScreenFrameTriage.hammingDistance(a, b), 32)
    }

    func testDHashRobustToScale() {
        // Same content at different resolutions should hash identically —
        // that's the point of the 9×8 downscale.
        let small = ScreenFrameTriage.dHash(gradientImage(width: 64, height: 48))
        let large = ScreenFrameTriage.dHash(gradientImage(width: 640, height: 480))
        XCTAssertLessThanOrEqual(ScreenFrameTriage.hammingDistance(small, large), 4)
    }

    // MARK: - Hamming distance

    func testHammingDistance() {
        XCTAssertEqual(ScreenFrameTriage.hammingDistance(0, 0), 0)
        XCTAssertEqual(ScreenFrameTriage.hammingDistance(0b1011, 0b0010), 2)
        XCTAssertEqual(ScreenFrameTriage.hammingDistance(UInt64.max, 0), 64)
    }

    // MARK: - Keep rule

    func testFirstFrameIsAlwaysKept() {
        XCTAssertTrue(ScreenFrameTriage.shouldKeep(hash: 0, lastKeptHash: nil, threshold: 8))
    }

    func testUnchangedFrameIsDropped() {
        XCTAssertFalse(ScreenFrameTriage.shouldKeep(hash: 42, lastKeptHash: 42, threshold: 8))
    }

    func testSmallChangeBelowThresholdIsDropped() {
        // 3 bits differ, threshold 8.
        XCTAssertFalse(ScreenFrameTriage.shouldKeep(hash: 0b0111, lastKeptHash: 0, threshold: 8))
    }

    func testLargeChangeIsKept() {
        XCTAssertTrue(ScreenFrameTriage.shouldKeep(hash: 0xFF, lastKeptHash: 0, threshold: 8))
    }

    // MARK: - Visual-only change

    func testIdenticalOCRIsVisualOnly() {
        let text = "line one\nline two\nline three"
        XCTAssertTrue(ScreenFrameTriage.isVisualOnlyChange(previousOCR: text, currentOCR: text))
    }

    func testMostlyIdenticalOCRIsVisualOnly() {
        // 20 shared lines, 0 changed — then 20 shared + 1 new = 20/21 ≈ 0.952.
        let base = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let extended = base + "\nnew line"
        XCTAssertTrue(ScreenFrameTriage.isVisualOnlyChange(previousOCR: base, currentOCR: extended))
    }

    func testDifferentOCRIsRealChange() {
        XCTAssertFalse(ScreenFrameTriage.isVisualOnlyChange(
            previousOCR: "slide one\nrevenue overview",
            currentOCR: "slide two\ncost breakdown"
        ))
    }

    func testTextAppearingIsRealChange() {
        XCTAssertFalse(ScreenFrameTriage.isVisualOnlyChange(previousOCR: nil, currentOCR: "hello"))
        XCTAssertFalse(ScreenFrameTriage.isVisualOnlyChange(previousOCR: "hello", currentOCR: nil))
    }

    func testNoTextEitherSideIsVisualOnly() {
        XCTAssertTrue(ScreenFrameTriage.isVisualOnlyChange(previousOCR: nil, currentOCR: nil))
    }

    // MARK: - Share-ended placeholder

    func testPlaceholderDetectedFromTypicalOCR() {
        // What Vision reads off the real Teams placeholder: title bar,
        // message, button.
        let ocr = "Shared content | Future Systems Weekly\nContent sharing has ended\nDismiss"
        XCTAssertTrue(ScreenFrameTriage.isShareEndedPlaceholder(ocrText: ocr))
    }

    func testPlaceholderCaseInsensitive() {
        XCTAssertTrue(ScreenFrameTriage.isShareEndedPlaceholder(ocrText: "CONTENT SHARING HAS ENDED"))
    }

    func testDocumentQuotingPhraseIsNotPlaceholder() {
        // A busy screen that merely contains the phrase must not end the
        // session — the placeholder heuristic requires a nearly-empty screen.
        let doc = (1...10).map { "Meaningful document line number \($0)" }
            .joined(separator: "\n") + "\nContent sharing has ended"
        XCTAssertFalse(ScreenFrameTriage.isShareEndedPlaceholder(ocrText: doc))
    }

    func testNormalContentIsNotPlaceholder() {
        XCTAssertFalse(ScreenFrameTriage.isShareEndedPlaceholder(ocrText: "Q3 Roadmap\nAuth GA Nov"))
        XCTAssertFalse(ScreenFrameTriage.isShareEndedPlaceholder(ocrText: nil))
        XCTAssertFalse(ScreenFrameTriage.isShareEndedPlaceholder(ocrText: "   "))
    }

    // MARK: - Scaling

    func testScaledSizeLeavesSmallImagesAlone() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertEqual(ScreenFrameTriage.scaledSize(for: size, targetPixelCount: 1_150_000), size)
    }

    func testScaledSizeDownscalesLargeImagesPreservingAspect() {
        let scaled = ScreenFrameTriage.scaledSize(
            for: CGSize(width: 3840, height: 2160),
            targetPixelCount: 1_150_000
        )
        XCTAssertLessThanOrEqual(scaled.width * scaled.height, 1_150_000)
        XCTAssertEqual(scaled.width / scaled.height, 3840.0 / 2160.0, accuracy: 0.01)
    }

    // MARK: - downscaledJPEG

    private func jpegData(width: Int, height: Int) -> Data {
        let cgImage = image(width: width, height: height) { x, _ in UInt8((x * 7) % 256) }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func pixelSize(of jpeg: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: w, height: h)
    }

    func testDownscaledJPEGStaysUnderPixelBudget() {
        let original = jpegData(width: 1600, height: 1200)
        let scaled = ScreenFrameTriage.downscaledJPEG(original, targetPixelCount: 600_000)
        let size = pixelSize(of: scaled)!
        XCTAssertLessThanOrEqual(size.width * size.height, 600_000)
        XCTAssertEqual(size.width / size.height, 1600.0 / 1200.0, accuracy: 0.05)
        XCTAssertLessThan(scaled.count, original.count)
    }

    func testDownscaledJPEGLeavesSmallImagesUntouched() {
        let original = jpegData(width: 640, height: 480)
        let scaled = ScreenFrameTriage.downscaledJPEG(original, targetPixelCount: 600_000)
        XCTAssertEqual(scaled, original)
    }

    func testDownscaledJPEGReturnsOriginalOnGarbage() {
        let garbage = Data("not a jpeg".utf8)
        XCTAssertEqual(ScreenFrameTriage.downscaledJPEG(garbage, targetPixelCount: 600_000), garbage)
    }

    // MARK: - Share sessions

    @MainActor
    func testSessionsGroupAndOrderFrames() {
        let sessionA = UUID(), sessionB = UUID()
        let frames = [
            makeFrame(session: sessionB, sequence: 0, timestamp: 300),
            makeFrame(session: sessionA, sequence: 0, timestamp: 10),
            makeFrame(session: sessionA, sequence: 1, timestamp: 40),
            makeFrame(session: sessionB, sequence: 1, timestamp: 360),
            makeFrame(session: sessionA, sequence: 2, timestamp: 90),
        ]
        let sessions = ShareSession.sessions(from: frames)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, sessionA)
        XCTAssertEqual(sessions[0].startTime, 10)
        XCTAssertEqual(sessions[0].endTime, 90)
        XCTAssertEqual(sessions[0].frameCount, 3)
        XCTAssertEqual(sessions[1].id, sessionB)
        XCTAssertEqual(sessions[1].frameCount, 2)
    }

    @MainActor
    func testSessionsEmptyInput() {
        XCTAssertTrue(ShareSession.sessions(from: []).isEmpty)
    }

    @MainActor
    private func makeFrame(session: UUID, sequence: Int, timestamp: TimeInterval) -> ScreenShareFrame {
        ScreenShareFrame(
            sessionID: session,
            sequence: sequence,
            timestamp: timestamp,
            imagePath: "frames/test/\(sequence).jpg"
        )
    }

    // MARK: - Teams window scoring

    func testTeamsShareWindowScoresAboveAutoThreshold() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Carlos is presenting",
            bundleID: "com.microsoft.teams2",
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )
        XCTAssertGreaterThanOrEqual(score, 100)
    }

    func testMainTeamsWindowIsNeverAutoSelected() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Architecture Braintrust | Microsoft Teams",
            bundleID: "com.microsoft.teams2",
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        XCTAssertGreaterThan(score, 0)   // still a picker candidate
        XCTAssertLessThan(score, 100)    // but never auto-captured
    }

    func testUnbrandedTeamsWindowIsAutoSelectable() {
        // The pop-out often carries just the shared content's name.
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Q3 Roadmap.pptx",
            bundleID: "com.microsoft.teams2",
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )
        XCTAssertGreaterThanOrEqual(score, 100)
    }

    func testNonTeamsWindowScoresZero() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "is presenting",
            bundleID: "com.google.Chrome",
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )
        XCTAssertEqual(score, 0)
    }

    func testTinyWindowScoresZero() {
        // The Teams sharing control strip is small — must never be captured.
        let score = ScreenShareCaptureService.scoreWindow(
            title: "is presenting",
            bundleID: "com.microsoft.teams2",
            frame: CGRect(x: 0, y: 0, width: 400, height: 80)
        )
        XCTAssertEqual(score, 0)
    }

    func testUntitledTeamsWindowIsNeverAutoSelected() {
        // Share overlays and placeholder windows often carry no title —
        // they must stay picker-only (a blank capture is worse than none).
        let score = ScreenShareCaptureService.scoreWindow(
            title: "",
            bundleID: "com.microsoft.teams2",
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 100)
    }

    func testClassicTeamsBundleAlsoRecognized() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Screen sharing",
            bundleID: "com.microsoft.teams",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )
        XCTAssertGreaterThanOrEqual(score, 100)
    }

    // MARK: - Discord window scoring

    private static let discord = "com.hnc.Discord"
    private static let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// The primary Discord auto-capture path: a stream popped out into its own
    /// window, so Discord now has two windows and this one isn't the main one.
    func testDiscordPopOutWindowScoresAboveAutoThreshold() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Ada's stream",
            bundleID: Self.discord,
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900),
            context: .init(sameAppWindowCount: 2, displayFrames: [Self.display])
        )
        XCTAssertGreaterThanOrEqual(score, 100)
    }

    /// A window titled like the pop-out but with no second window is just the
    /// main app — auto-capturing it would frame the chat and member list.
    func testDiscordSingleWindowIsNeverAutoSelected() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "#engineering | Acme - Discord",
            bundleID: Self.discord,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            context: .init(sameAppWindowCount: 1, displayFrames: [Self.display])
        )
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 100)
    }

    /// Two windows where this one *is* the main window: the pop-out is the
    /// other one, so this must stay picker-only.
    func testDiscordMainWindowStaysPickerOnlyEvenWithTwoWindows() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "#engineering | Acme - Discord",
            bundleID: Self.discord,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            context: .init(sameAppWindowCount: 2, displayFrames: [Self.display])
        )
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 100)
    }

    /// Fullscreening the stream is the other way to get a chrome-free view.
    func testDiscordFullscreenWindowScoresAboveAutoThreshold() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Ada Lovelace",
            bundleID: Self.discord,
            frame: Self.display,
            context: .init(sameAppWindowCount: 1, displayFrames: [Self.display])
        )
        XCTAssertGreaterThanOrEqual(score, 100)
    }

    /// A fullscreened Discord *chat* window is an ordinary thing to have on
    /// screen. The fullscreen rule must not override the main-window penalty,
    /// or auto-capture screenshots the channel sidebar and member list.
    func testDiscordFullscreenMainWindowStaysPickerOnly() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "#engineering | Acme - Discord",
            bundleID: Self.discord,
            frame: Self.display,
            context: .init(sameAppWindowCount: 1, displayFrames: [Self.display])
        )
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 100)
    }

    /// Teams has no fullscreen rule — a maximized Teams main window must not
    /// start auto-capturing.
    func testFullscreenRuleDoesNotApplyToTeams() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Chat | Microsoft Teams",
            bundleID: "com.microsoft.teams2",
            frame: Self.display,
            context: .init(sameAppWindowCount: 1, displayFrames: [Self.display])
        )
        XCTAssertLessThan(score, 100)
    }

    /// Apps with no profile stay invisible to auto-detect, however many
    /// windows they have open.
    func testUnprofiledAppScoresZeroRegardlessOfContext() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Some Document",
            bundleID: "com.google.Chrome",
            frame: Self.display,
            context: .init(sameAppWindowCount: 3, displayFrames: [Self.display])
        )
        XCTAssertEqual(score, 0)
    }

    func testIsFullscreenToleratesMenuBarAndDock() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Full width, shortened by the menu bar — still "fullscreen".
        XCTAssertTrue(ScreenShareCaptureService.isFullscreen(
            CGRect(x: 0, y: 0, width: 1920, height: 1035), in: [display]
        ))
        // A half-width window is not.
        XCTAssertFalse(ScreenShareCaptureService.isFullscreen(
            CGRect(x: 0, y: 0, width: 960, height: 1080), in: [display]
        ))
        XCTAssertFalse(ScreenShareCaptureService.isFullscreen(
            CGRect(x: 0, y: 0, width: 1920, height: 1080), in: []
        ))
    }

    // MARK: - Zoom window scoring

    private static let zoom = "us.zoom.xos"

    /// The reported bug: a Zoom pop-out was invisible to the picker, and even
    /// once visible Zoom had no profile at all, so it could never be
    /// auto-captured. A second, distinctly-titled window is the pop-out.
    func testZoomPopOutWindowScoresAboveAutoThreshold() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Ada's screen share",
            bundleID: Self.zoom,
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900),
            context: .init(sameAppWindowCount: 2, displayFrames: [Self.display])
        )
        XCTAssertGreaterThanOrEqual(score, 100)
    }

    /// Zoom's meeting window is titled exactly "Zoom". Whenever nobody is
    /// sharing it is a gallery of faces, so auto-capturing it would spend the
    /// frame budget on video thumbnails — it stays picker-only.
    func testZoomMeetingWindowIsNeverAutoSelected() {
        for title in ["Zoom", "Zoom Meeting", "Zoom Workplace"] {
            let score = ScreenShareCaptureService.scoreWindow(
                title: title,
                bundleID: Self.zoom,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                context: .init(sameAppWindowCount: 2, displayFrames: [Self.display])
            )
            XCTAssertGreaterThan(score, 0, "\(title) should stay a picker candidate")
            XCTAssertLessThan(score, 100, "\(title) must never be auto-captured")
        }
    }

    /// The exact-title rule must not swallow pop-outs that merely *contain*
    /// the chrome title — the whole reason exact matching exists.
    func testZoomTitleContainingMeetingNameIsStillAutoSelectable() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Zoom Meeting — Ada's screen",
            bundleID: Self.zoom,
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900),
            context: .init(sameAppWindowCount: 2, displayFrames: [Self.display])
        )
        XCTAssertGreaterThanOrEqual(score, 100)
    }

    /// Zoom pins auxiliary windows above the normal window level, and the
    /// floating video window is one of them — small enough that the size floor
    /// keeps it out regardless of how it scores.
    func testZoomFloatingVideoWindowIsNotACandidate() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "zoom floating video window",
            bundleID: Self.zoom,
            frame: CGRect(x: 0, y: 0, width: 244, height: 139),
            context: .init(sameAppWindowCount: 3, displayFrames: [Self.display])
        )
        XCTAssertEqual(score, 0)
    }

    /// Even at an adequate size the floating window is chrome, not content.
    func testZoomFloatingVideoWindowIsNeverAutoSelected() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "zoom floating video window",
            bundleID: Self.zoom,
            frame: CGRect(x: 0, y: 0, width: 900, height: 600),
            context: .init(sameAppWindowCount: 3, displayFrames: [Self.display])
        )
        XCTAssertLessThan(score, 100)
    }

    /// Teams' share-border overlay is titled "Microsoft Teams". It is back in
    /// the candidate list now that elevated layers are allowed, so the
    /// main-window rule is the only thing keeping it out of auto-capture —
    /// this is the regression the `windowLayer == 0` filter used to cover.
    func testTeamsShareBorderOverlayStaysPickerOnly() {
        let score = ScreenShareCaptureService.scoreWindow(
            title: "Microsoft Teams",
            bundleID: "com.microsoft.teams2",
            frame: Self.display,
            context: .init(sameAppWindowCount: 3, displayFrames: [Self.display])
        )
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, 100)
    }

    // MARK: - Per-app share-ended phrases

    func testDiscordPlaceholderUsesDiscordPhrases() {
        let ocr = "The stream has ended"
        XCTAssertTrue(ScreenFrameTriage.isShareEndedPlaceholder(
            ocrText: ocr, phrases: ShareAppProfiles.discord.shareEndedPhrases
        ))
        // Teams' phrase list must not match Discord's placeholder.
        XCTAssertFalse(ScreenFrameTriage.isShareEndedPlaceholder(
            ocrText: ocr, phrases: ShareAppProfiles.teams.shareEndedPhrases
        ))
    }

    func testShareEndedDefaultsToTeamsPhrases() {
        XCTAssertTrue(ScreenFrameTriage.isShareEndedPlaceholder(
            ocrText: "Content sharing has ended"
        ))
    }

    // MARK: - Placeholder cooldown

    private func candidate(_ id: CGWindowID, title: String) -> WindowCandidate {
        WindowCandidate(
            id: id, title: title, appName: "Microsoft Teams", bundleID: "com.microsoft.teams2",
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), score: 160
        )
    }

    /// Teams tears the placeholder pop-out down and puts it back between
    /// polls. The ignore must survive the window's absence, or the next poll
    /// adopts the replacement and the cycle repeats every few seconds.
    func testPlaceholderIgnoreSurvivesTheWindowVanishingDuringCooldown() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let ignores: [CGWindowID: ScreenShareCaptureService.PlaceholderIgnore] = [
            42: .init(title: "Shared content | Daily | Microsoft Teams", at: t0)
        ]
        let live = ScreenShareCaptureService.liveIgnores(ignores, candidates: [], now: t0.addingTimeInterval(30), cooldown: 60)
        XCTAssertEqual(live.count, 1)
    }

    func testPlaceholderIgnoreIsDroppedAfterCooldownOnceTheWindowIsGone() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let title = "Shared content | Daily | Microsoft Teams"
        let ignores: [CGWindowID: ScreenShareCaptureService.PlaceholderIgnore] = [42: .init(title: title, at: t0)]
        let later = t0.addingTimeInterval(61)
        XCTAssertTrue(ScreenShareCaptureService.liveIgnores(ignores, candidates: [], now: later, cooldown: 60).isEmpty)
        XCTAssertEqual(
            ScreenShareCaptureService.liveIgnores(ignores, candidates: [candidate(42, title: title)], now: later, cooldown: 60).count,
            1, "still there under the same title — still the placeholder"
        )
        XCTAssertTrue(
            ScreenShareCaptureService.liveIgnores(ignores, candidates: [candidate(42, title: "Shared content | Other")], now: later, cooldown: 60).isEmpty,
            "retitled — re-evaluate"
        )
    }

    /// The replacement window has a fresh ID; the title is what carries over.
    func testAReplacementWindowWithTheSameTitleIsSuppressed() {
        let title = "Shared content | Daily | Microsoft Teams"
        let replacement = candidate(43, title: title)
        XCTAssertTrue(ScreenShareCaptureService.isSuppressed(replacement, ignoredWindows: [:], endedTitles: [title: Date()]))
        XCTAssertFalse(ScreenShareCaptureService.isSuppressed(candidate(43, title: "Shared content | Other"), ignoredWindows: [:], endedTitles: [title: Date()]))
        XCTAssertTrue(ScreenShareCaptureService.isSuppressed(candidate(42, title: "anything"), ignoredWindows: [42: .init(title: "x", at: Date())], endedTitles: [:]))
    }
}
