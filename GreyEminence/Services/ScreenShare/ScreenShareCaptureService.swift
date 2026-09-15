import CoreGraphics
import Foundation
import ImageIO
// @preconcurrency: CI's older SDK lacks Sendable annotations on
// SCShareableContent — without this the release build rejects every
// `try await SCShareableContent...` call from actor-isolated code.
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Events & value types

enum SessionEndReason: String, Sendable {
    case windowGone
    case recordingStopped
    case capReached
    /// The window showed Teams' "Content sharing has ended" placeholder.
    case shareEnded

    /// Human-readable phrase for the activity log.
    var logReason: String {
        switch self {
        case .windowGone: "the shared window closed or was no longer detected"
        case .recordingStopped: "the recording stopped"
        case .capReached: "the per-recording frame cap was reached"
        case .shareEnded: "the presenter ended the share (\"Content sharing has ended\")"
        }
    }
}

/// A window the picker can offer. `score` reflects the Teams pop-out
/// heuristics; the picker sorts by it and badges high scorers.
struct WindowCandidate: Sendable, Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let appName: String
    let bundleID: String
    let frame: CGRect
    let score: Int
    /// CoreGraphics window level. Purely diagnostic — it is logged so a window
    /// that fails to show up can be told apart from one that scored badly,
    /// which is exactly what went missing when Zoom's pop-out was invisible.
    var windowLayer: Int = 0
}

/// One frame that survived change detection, already written to disk.
struct KeptFrame: Sendable {
    let id: UUID
    let sessionID: UUID
    let sequence: Int
    let capturedAt: Date
    /// Relative to the meeting's recording directory.
    let relativeImagePath: String
    /// Retained so the analysis service can upload without re-reading disk.
    let jpegData: Data
    let dHash: UInt64
    let ocrText: String?
    let isVisualOnlyChange: Bool
    let windowTitle: String
}

enum ScreenCaptureEvent: Sendable {
    case sessionStarted(sessionID: UUID, windowTitle: String, appBundleID: String)
    case frameKept(KeptFrame)
    case frameDropped(sessionID: UUID)
    case sessionEnded(sessionID: UUID, reason: SessionEndReason)
    /// Emitted once per recording; capture goes inert afterwards.
    case permissionDenied
    /// Auto-detect found multiple plausible share windows; the UI can offer
    /// the picker. Sorted by score, best first.
    case candidatesChanged([WindowCandidate])
}

// MARK: - Capture service

/// Watches for a popped-out Teams screen-share window during a recording and
/// periodically screenshots it. Owns all ScreenCaptureKit access, change
/// detection, OCR, and JPEG writing; emits `Sendable` events for the
/// recording view model to consume. No SwiftData, no AI — track 1 only.
actor ScreenShareCaptureService {

    struct Config: Sendable {
        var intervalSeconds: Double = ScreenShareSettings.defaultIntervalSeconds
        var autoDetect: Bool = true
        var changeThreshold: Int = ScreenShareSettings.defaultChangeThreshold
        var maxKeptFrames: Int = ScreenShareSettings.defaultMaxKeptFrames
        /// ~1.15 MP — Claude vision's cost/quality sweet spot; plenty for OCR.
        var targetPixelCount: Int = 1_150_000
        var jpegQuality: Double = 0.7
    }

    /// Per-app share-window heuristics live in `ShareAppProfiles` — data-driven
    /// so adapting to a Teams or Discord UI change is an edit there, not here.

    /// Facts about the wider window list that a single window can't reveal on
    /// its own, but which strongly indicate a share.
    struct ScoringContext: Sendable {
        /// How many windows the same app currently has on screen.
        var sameAppWindowCount: Int = 1
        /// Frames of the attached displays, for spotting a fullscreened window.
        var displayFrames: [CGRect] = []
    }

    private static let discoveryInterval: Double = 3.0
    /// Consecutive failed polls before the session is declared over
    /// (~6–10s grace for compositor hiccups and brief occlusion).
    private static let missedPollLimit = 2

    // MARK: State

    private var continuation: AsyncStream<ScreenCaptureEvent>.Continuation?
    private var loopTask: Task<Void, Never>?
    private var meetingID: UUID?
    private var config = Config()
    private var suspended = false
    private var permissionDenied = false
    private var frameCapReached = false

    /// Manual picker override; wins over auto-detect. `nil` = auto.
    private var manualWindowID: CGWindowID?
    private var currentWindowID: CGWindowID?
    private var currentSessionID: UUID?
    private var currentWindowTitle: String = ""
    /// Profile of the app owning the session's window, so share-ended
    /// detection uses that app's placeholder wording.
    private var currentProfile: ShareAppProfile?
    private var sequence = 0
    private var lastKeptHash: UInt64?
    private var lastKeptOCR: String?
    private var keptCount = 0
    private var missedPolls = 0
    private var lastCaptureAt: Date?
    private var lastReportedCandidateIDs: [CGWindowID] = []
    /// Placeholder sightings: each is "window `id` titled `title` showed the
    /// share-ended placeholder at `at`". Auto-detect skips a candidate that
    /// matches one for at least `placeholderCooldown` — matched on *either*
    /// id or title, because Teams tears the pop-out down and puts it back
    /// between polls under a fresh window id, and an id-only ignore was
    /// pruned the moment the window blinked out (15 sessions in 50 s on
    /// 2026-09-14, the UI flipping capturing/watching throughout). After the
    /// cooldown a sighting survives only while its exact window+title is
    /// still on screen. Manual selection always overrides.
    private var placeholderSightings: [PlaceholderIgnore] = []

    struct PlaceholderIgnore: Equatable, Sendable {
        let id: CGWindowID
        let title: String
        let at: Date
    }

    /// How long a window or title that showed the placeholder stays out of
    /// auto-detect no matter what the window server does with the window.
    static let placeholderCooldown: TimeInterval = 60

    // MARK: Lifecycle

    func start(meetingID: UUID, config: Config) -> AsyncStream<ScreenCaptureEvent> {
        stopInternal(reason: .recordingStopped)  // defensive: clear any stale run
        self.meetingID = meetingID
        self.config = config
        self.suspended = false
        self.permissionDenied = false
        self.frameCapReached = false
        self.manualWindowID = nil
        self.keptCount = 0
        self.placeholderSightings = []

        let (stream, continuation) = AsyncStream.makeStream(of: ScreenCaptureEvent.self)
        self.continuation = continuation
        loopTask = Task { await self.runLoop() }
        LogManager.send("Screen-share capture watching (interval \(Int(config.intervalSeconds))s)", category: .screen, meetingID: meetingID)
        return stream
    }

    func stop() {
        stopInternal(reason: .recordingStopped)
    }

    func suspend() {
        suspended = true
        LogManager.send("Screen-share capture suspended", category: .screen, meetingID: meetingID)
    }

    func resume() {
        suspended = false
        LogManager.send("Screen-share capture resumed", category: .screen, meetingID: meetingID)
    }

    /// Manual window selection from the picker. `nil` returns to auto-detect.
    func selectWindow(_ windowID: CGWindowID?) {
        manualWindowID = windowID
        if let windowID {
            // The user insisting on a window beats the placeholder ignore.
            placeholderSightings.removeAll { $0.id == windowID }
        }
        LogManager.send(
            windowID.map { "Manual window selected (id \($0))" } ?? "Returned to auto-detect",
            category: .screen,
            meetingID: meetingID
        )
        // Force re-evaluation: end the current session so the next poll
        // starts one on the newly selected window.
        if let sessionID = currentSessionID, windowID != currentWindowID {
            endSession(sessionID, reason: .windowGone)
        }
    }

    /// All plausible windows for the manual picker, best-scored first.
    func currentCandidates() async -> [WindowCandidate] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: false
        ) else { return [] }
        return Self.candidates(from: content.windows, displayFrames: content.displays.map(\.frame))
            .sorted { $0.score > $1.score }
    }

    /// Small one-off screenshot of a candidate window for the picker grid.
    func thumbnail(for windowID: CGWindowID, maxPixel: CGFloat = 400) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = min(1, maxPixel / max(window.frame.width, window.frame.height, 1))
        configuration.width = max(Int(window.frame.width * scale), 1)
        configuration.height = max(Int(window.frame.height * scale), 1)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func stopInternal(reason: SessionEndReason) {
        if let sessionID = currentSessionID {
            endSession(sessionID, reason: reason)
        }
        loopTask?.cancel()
        loopTask = nil
        continuation?.finish()
        continuation = nil
        meetingID = nil
    }

    // MARK: Main loop

    /// Single loop, 1s granularity: discovery every 3s, capture whenever the
    /// configured interval has elapsed while a window is selected. One place
    /// owns the state machine — no cross-task coordination.
    private func runLoop() async {
        var lastDiscoveryAt = Date.distantPast
        while !Task.isCancelled {
            if !suspended && !permissionDenied && !frameCapReached {
                let now = Date()
                if now.timeIntervalSince(lastDiscoveryAt) >= Self.discoveryInterval {
                    lastDiscoveryAt = now
                    await discoverWindow()
                }
                if currentWindowID != nil,
                   now.timeIntervalSince(lastCaptureAt ?? .distantPast) >= config.intervalSeconds {
                    lastCaptureAt = now
                    await captureFrame()
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Discovery

    private func discoverWindow() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            // Most common cause is TCC denial; SCK throws the same way for
            // transient failures, so only latch denial when we've never
            // captured anything (a mid-recording revoke also lands here).
            handleDiscoveryFailure(error)
            return
        }
        // The recording may have stopped while we were suspended on the
        // SCShareableContent fetch — a session started now would be a
        // zombie logged after "recording stopped".
        guard continuation != nil else { return }

        let candidates = Self.candidates(
            from: content.windows,
            displayFrames: content.displays.map(\.frame)
        )
        reportCandidatesIfChanged(candidates)

        let now = Date()
        placeholderSightings = Self.liveSightings(placeholderSightings, candidates: candidates, now: now)

        let selected: WindowCandidate?
        if let manualID = manualWindowID {
            selected = candidates.first { $0.id == manualID }
        } else if config.autoDetect {
            selected = candidates
                .filter { $0.score >= 100 && !Self.isSuppressed($0, by: placeholderSightings) }
                .max { $0.score < $1.score }
        } else {
            selected = nil
        }

        if let selected {
            missedPolls = 0
            if selected.id != currentWindowID {
                if let sessionID = currentSessionID {
                    endSession(sessionID, reason: .windowGone)
                }
                startSession(with: selected)
            }
        } else if currentWindowID != nil {
            missedPolls += 1
            if missedPolls >= Self.missedPollLimit, let sessionID = currentSessionID {
                endSession(sessionID, reason: .windowGone)
            }
        }
    }

    /// The sightings still worth keeping. Inside the cooldown, all of them —
    /// the window blinking out of the list is exactly the case the cooldown
    /// exists for. After it, only those whose exact window+title is still on
    /// screen; a closed or retitled window is no longer the screen that was
    /// blacklisted.
    static func liveSightings(
        _ sightings: [PlaceholderIgnore],
        candidates: [WindowCandidate],
        now: Date,
        cooldown: TimeInterval = placeholderCooldown
    ) -> [PlaceholderIgnore] {
        sightings.filter { sighting in
            if now.timeIntervalSince(sighting.at) < cooldown { return true }
            return candidates.contains { $0.id == sighting.id && $0.title == sighting.title }
        }
    }

    /// A candidate auto-detect must leave alone: within the cooldown a
    /// sighting suppresses any candidate sharing its window id or its title
    /// (the pop-out reappears under a new id but the same title); after the
    /// cooldown `liveSightings` has already dropped the stale ones, so an
    /// id-or-title match still means "this is the placeholder".
    static func isSuppressed(_ candidate: WindowCandidate, by sightings: [PlaceholderIgnore]) -> Bool {
        sightings.contains { $0.id == candidate.id || $0.title == candidate.title }
    }

    private func handleDiscoveryFailure(_ error: Error) {
        guard !permissionDenied else { return }
        permissionDenied = true
        if let sessionID = currentSessionID {
            endSession(sessionID, reason: .windowGone)
        }
        continuation?.yield(.permissionDenied)
        LogManager.send("Screen-share capture disabled: \(error.localizedDescription)", category: .screen, level: .warning, meetingID: meetingID)
    }

    private func startSession(with candidate: WindowCandidate) {
        let sessionID = UUID()
        currentSessionID = sessionID
        currentWindowID = candidate.id
        currentWindowTitle = candidate.title
        currentProfile = ShareAppProfiles.profile(for: candidate.bundleID)
        sequence = 0
        lastKeptHash = nil
        lastKeptOCR = nil
        missedPolls = 0
        lastCaptureAt = nil  // capture immediately on the next tick
        continuation?.yield(.sessionStarted(
            sessionID: sessionID,
            windowTitle: candidate.title,
            appBundleID: candidate.bundleID
        ))
        LogManager.send("Share session started: \"\(candidate.title)\" (\(candidate.appName), window \(candidate.id))", category: .screen, meetingID: meetingID)
    }

    private func endSession(_ sessionID: UUID, reason: SessionEndReason) {
        currentSessionID = nil
        currentWindowID = nil
        currentWindowTitle = ""
        currentProfile = nil
        missedPolls = 0
        continuation?.yield(.sessionEnded(sessionID: sessionID, reason: reason))
        LogManager.send("Screen capture stopped: \(reason.logReason)", category: .screen, meetingID: meetingID)
    }

    private func reportCandidatesIfChanged(_ candidates: [WindowCandidate]) {
        let plausible = candidates.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        let ids = plausible.map(\.id)
        guard ids != lastReportedCandidateIDs else { return }
        lastReportedCandidateIDs = ids
        continuation?.yield(.candidatesChanged(plausible))
        // Spike diagnostics: log what each app exposes so the title heuristics
        // can be tuned from real data (remove once patterns are confirmed).
        // The layer is here because a pop-out that never appears is the hard
        // failure to diagnose — Zoom's sat above the normal level unseen.
        for candidate in plausible {
            LogManager.send(
                "Share candidate: \"\(candidate.title)\" (\(candidate.appName), \(Int(candidate.frame.width))×\(Int(candidate.frame.height)), layer \(candidate.windowLayer), score \(candidate.score))",
                category: .screen,
                meetingID: meetingID
            )
        }
    }

    // MARK: Scoring (pure — unit-tested via scoreWindow)

    /// `displayFrames` comes from the same `SCShareableContent` the windows
    /// came from — no separate display query, and no reach for `NSScreen`,
    /// which is MainActor-isolated and unreachable from this actor.
    static func candidates(
        from windows: [SCWindow],
        displayFrames: [CGRect]
    ) -> [WindowCandidate] {
        let displays = displayFrames
        // Eligible windows first, so the per-app window counts below reflect
        // what the user can actually see rather than hidden helper windows.
        let eligible = windows.compactMap { window -> (SCWindow, SCRunningApplication)? in
            guard let app = window.owningApplication else { return nil }
            // Real, visible windows only — this drops hidden Electron helper
            // windows and the desktop's own negative-layer surfaces.
            //
            // We deliberately do NOT require `windowLayer == 0`. That check
            // was added on 2026-07-16 to shut out Teams' red screen-share
            // border (a full-screen transparent overlay that captures blank),
            // but it also hides every window an app pins above the normal
            // level — and Zoom pins plenty: its floating video window sits at
            // layer 26 (measured 2026-08-12), and its popped-out shared
            // content never reached the picker at all. The Teams overlay is
            // titled "Microsoft Teams", so the main-window scoring rule
            // already keeps it picker-only; that is the check doing the real
            // work here, and it costs us nothing on elevated windows.
            guard window.isOnScreen, window.windowLayer >= 0 else { return nil }
            // Windows failing the size floor are never candidates at all.
            guard window.frame.width >= 300, window.frame.height >= 200 else { return nil }
            return (window, app)
        }

        var windowCounts: [String: Int] = [:]
        for (_, app) in eligible {
            windowCounts[app.bundleIdentifier, default: 0] += 1
        }

        return eligible.map { window, app in
            let title = window.title ?? ""
            let context = ScoringContext(
                sameAppWindowCount: windowCounts[app.bundleIdentifier] ?? 1,
                displayFrames: displays
            )
            return WindowCandidate(
                id: window.windowID,
                title: title,
                appName: app.applicationName,
                bundleID: app.bundleIdentifier,
                frame: window.frame,
                score: scoreWindow(
                    title: title,
                    bundleID: app.bundleIdentifier,
                    frame: window.frame,
                    context: context
                ),
                windowLayer: window.windowLayer
            )
        }
    }

    /// Heuristic score for "is this window the shared content".
    /// ≥100 auto-captures; 1–99 shows in the picker as plausible; 0 is
    /// picker-only filler.
    ///
    /// Apps with no profile score 0 — they stay manually selectable but are
    /// never auto-captured, which is how unknown apps have always behaved.
    static func scoreWindow(
        title: String,
        bundleID: String,
        frame: CGRect,
        context: ScoringContext = ScoringContext()
    ) -> Int {
        guard frame.width >= 300, frame.height >= 200 else { return 0 }
        guard let profile = ShareAppProfiles.profile(for: bundleID) else { return 0 }

        let lower = title.lowercased().trimmingCharacters(in: .whitespaces)
        let isMainWindow = lower.isEmpty
            || profile.mainWindowPatterns.contains(where: { lower.contains($0) })
            || profile.mainWindowExactTitles.contains(lower)
        var score = 60  // any adequately-sized window of a known app is plausible

        if profile.shareTitlePatterns.contains(where: { lower.contains($0) }) {
            score += 100
        } else if profile.secondaryWindowIsShare
                    && context.sameAppWindowCount >= 2
                    && !isMainWindow {
            // A second, differently-titled window of an app that pops its
            // share out — this is the Discord pop-out.
            score += 100
        } else if profile.fullscreenIsShare
                    && !isMainWindow
                    && isFullscreen(frame, in: context.displayFrames) {
            // The !isMainWindow guard matters as much here as in the branch
            // above: a fullscreened Discord *chat* window is an ordinary thing
            // to have on screen, and capturing it would screenshot the channel
            // sidebar and member list — exactly what the profile exists to avoid.
            score += 100
        } else if isMainWindow {
            // The main meeting/chat window, or an untitled window (overlays,
            // placeholders) — plausible for the picker, never auto-selected.
            score -= 40
        } else {
            // Known app with an unrecognized real title: the pop-out content
            // window often carries just the shared app/monitor name, so an
            // unbranded title is itself a share signal.
            score += 40
        }
        return score
    }

    /// True when the window covers a whole display, within a tolerance that
    /// absorbs the menu bar, Dock, and rounding.
    static func isFullscreen(_ frame: CGRect, in displayFrames: [CGRect]) -> Bool {
        displayFrames.contains { display in
            abs(frame.width - display.width) <= 2
                && abs(frame.height - display.height) <= 80
                && frame.width > 0
        }
    }

    // MARK: Capture

    private func captureFrame() async {
        guard let windowID = currentWindowID,
              let sessionID = currentSessionID,
              let meetingID else { return }

        // Fresh SCWindow each time — stale references go invalid when the
        // window server recycles state.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            missedPolls += 1
            if missedPolls >= Self.missedPollLimit {
                endSession(sessionID, reason: .windowGone)
            }
            return
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let pixelSize = ScreenFrameTriage.scaledSize(
            for: CGSize(width: window.frame.width * 2, height: window.frame.height * 2),
            targetPixelCount: config.targetPixelCount
        )
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.showsCursor = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            missedPolls += 1
            LogManager.send("Frame capture failed: \(error.localizedDescription)", category: .screen, level: .warning, meetingID: meetingID)
            if missedPolls >= Self.missedPollLimit {
                endSession(sessionID, reason: .windowGone)
            }
            return
        }
        missedPolls = 0

        let hash = ScreenFrameTriage.dHash(image)
        let distance = lastKeptHash.map { ScreenFrameTriage.hammingDistance(hash, $0) }
        guard ScreenFrameTriage.shouldKeep(hash: hash, lastKeptHash: lastKeptHash, threshold: config.changeThreshold) else {
            continuation?.yield(.frameDropped(sessionID: sessionID))
            LogManager.send("Frame dropped: unchanged (Δ\(distance ?? 0) < \(config.changeThreshold))", category: .screen, meetingID: meetingID)
            return
        }

        var ocrText: String?
        do {
            ocrText = try await ScreenFrameTriage.recognizeText(in: image)
        } catch {
            LogManager.send("Frame OCR failed (keeping frame without text): \(error.localizedDescription)", category: .screen, level: .warning, meetingID: meetingID)
        }

        // Teams leaves a "Content sharing has ended" placeholder in the
        // pop-out after the presenter stops. That's the end of the share,
        // not content: drop the frame, close the session, and ignore this
        // window until it closes or its title changes.
        if ScreenFrameTriage.isShareEndedPlaceholder(
            ocrText: ocrText,
            phrases: currentProfile?.shareEndedPhrases ?? ScreenFrameTriage.shareEndedPhrases
        ) {
            placeholderSightings.append(PlaceholderIgnore(id: windowID, title: currentWindowTitle, at: Date()))
            continuation?.yield(.frameDropped(sessionID: sessionID))
            LogManager.send("Share-ended placeholder detected (\"\(currentWindowTitle)\", window \(windowID)) — frame dropped, session closed, not re-adopting this window or title for \(Int(Self.placeholderCooldown))s", category: .screen, meetingID: meetingID)
            endSession(sessionID, reason: .shareEnded)
            return
        }

        let visualOnly = lastKeptHash != nil
            && ScreenFrameTriage.isVisualOnlyChange(previousOCR: lastKeptOCR, currentOCR: ocrText)

        guard let jpeg = Self.encodeJPEG(image, quality: config.jpegQuality) else {
            LogManager.send("Frame JPEG encode failed", category: .screen, level: .warning, meetingID: meetingID)
            return
        }

        let relativePath: String
        do {
            relativePath = try StorageManager.shared.writeFrame(
                jpeg, meetingID: meetingID, sessionID: sessionID, sequence: sequence
            )
        } catch {
            LogManager.send("Frame write failed: \(error.localizedDescription)", category: .screen, level: .error, meetingID: meetingID)
            return
        }

        let frame = KeptFrame(
            id: UUID(),
            sessionID: sessionID,
            sequence: sequence,
            capturedAt: Date(),
            relativeImagePath: relativePath,
            jpegData: jpeg,
            dHash: hash,
            ocrText: ocrText,
            isVisualOnlyChange: visualOnly,
            windowTitle: currentWindowTitle
        )
        sequence += 1
        keptCount += 1
        lastKeptHash = hash
        lastKeptOCR = ocrText
        continuation?.yield(.frameKept(frame))
        LogManager.send(
            "Frame kept #\(frame.sequence) (Δ\(distance.map(String.init) ?? "first"), \(jpeg.count / 1024) KB, OCR \(ocrText?.count ?? 0) chars\(visualOnly ? ", visual-only" : ""))",
            category: .screen,
            meetingID: meetingID
        )

        if keptCount >= config.maxKeptFrames {
            frameCapReached = true
            endSession(sessionID, reason: .capReached)
            LogManager.send("Frame cap reached (\(keptCount)) — capture stopped for this recording", category: .screen, level: .warning, meetingID: meetingID)
        }
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
