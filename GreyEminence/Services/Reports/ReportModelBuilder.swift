import Foundation

/// Snapshots a `Meeting` into a `ReportModel`.
///
/// This is the only place in the report pipeline that touches SwiftData, so
/// it is the only place that has to be `@MainActor`. Frame images are read
/// and downscaled here too, so the resulting model is genuinely standalone.
@MainActor
enum ReportModelBuilder {

    /// Pixel budget per embedded figure. A Letter page's content column is
    /// roughly 470pt wide, so ~1.2MP is comfortably past what print resolves
    /// while keeping a ten-figure report to a few megabytes.
    static let figurePixelBudget = 1_200_000

    /// How many figures a single share session offers the anchoring pass.
    /// This is the candidate pool, not what prints: the plan picks from it,
    /// and the no-plan path trims to `ReportExportService.unplannedFigureLimit`.
    /// Wide enough that a diagram discussed between two key moments is still
    /// on offer; beyond this the anchoring prompt pays for pictures the
    /// recap already judged forgettable.
    static let maxFiguresPerSession = 8

    /// How far either side of a key moment to look for a frame worth
    /// printing. Wide enough to skip past a cut to someone's camera, narrow
    /// enough that the picture still illustrates that moment.
    static let keyMomentWindow: TimeInterval = 45

    static func build(
        from meeting: Meeting,
        storage: StorageManager = .shared,
        includeTranscript: Bool = false
    ) -> ReportModel {
        let insight = meeting.latestInsight

        return ReportModel(
            meta: meta(for: meeting),
            sections: sections(from: insight),
            actionItems: meeting.actionItems.map {
                ReportModel.ActionItem(
                    text: $0.text,
                    assignee: $0.displayAssignee,
                    isCompleted: $0.isCompleted
                )
            },
            followUpQuestions: insight?.followUpQuestions ?? [],
            topics: insight?.topics ?? [],
            shareSessions: shareSessions(for: meeting, storage: storage),
            transcript: includeTranscript ? transcript(for: meeting) : []
        )
    }

    // MARK: - Meta

    private static func meta(for meeting: Meeting) -> ReportModel.Meta {
        ReportModel.Meta(
            // `title` is the name the app shows and the user can edit;
            // `generatedTitle` is a stash that `applyGeneratedTitle` only
            // promotes into `title` when the meeting isn't calendar-linked.
            // Reading the stash instead would export a calendar meeting under
            // an AI name it never displays, and would ignore a manual rename
            // entirely — the report must be titled whatever the meeting is
            // called at the moment you export it.
            title: meeting.title,
            date: meeting.date,
            duration: meeting.formattedDuration,
            attendees: meeting.presentAttendees.map(\.name).sorted(),
            sourceApp: MeetingAppRegistry.displayName(
                for: meeting.sourceAppBundleID,
                fallback: meeting.sourceAppName
            ),
            generatedAt: .now
        )
    }

    // MARK: - Sections

    /// Summaries are stored as JSON `[SummarySection]` by the current
    /// analysis pipeline, but older meetings hold a flat markdown string.
    /// Those still deserve a report, so they become one untitled section.
    /// Section ids and titles, without doing any of the expensive work.
    ///
    /// The export picker lists these, and the ids it hands back index into
    /// the model the builder produces — so both must come from one place or a
    /// legacy flat-string summary would be numbered differently in the picker
    /// than in the report. Reads no images, so it is cheap enough for a view.
    static func sectionTitles(for meeting: Meeting) -> [(id: Int, title: String)] {
        sections(from: meeting.latestInsight).map { ($0.id, $0.title) }
    }

    private static func sections(from insight: MeetingInsight?) -> [ReportModel.Section] {
        guard let summary = insight?.summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        guard let parsed = SummarySection.parse(summary) else {
            return [
                ReportModel.Section(
                    id: 0,
                    title: "Summary",
                    intro: summary,
                    points: [],
                    figures: []
                )
            ]
        }

        return parsed.enumerated().map { index, section in
            ReportModel.Section(
                id: index,
                title: section.title,
                intro: section.intro,
                points: section.points.map {
                    ReportModel.Point(label: $0.label, detail: $0.detail)
                },
                figures: []
            )
        }
    }

    // MARK: - Share sessions & figures

    private static func shareSessions(
        for meeting: Meeting,
        storage: StorageManager
    ) -> [ReportModel.ShareSession] {
        let frames = meeting.screenFrames
        guard !frames.isEmpty else { return [] }

        let sessions = ShareSession.sessions(from: frames)
        let framesBySession = Dictionary(grouping: frames, by: \.sessionID)
        let summariesBySession = Dictionary(
            uniqueKeysWithValues: meeting.sessionSummaries.map { ($0.sessionID, $0) }
        )

        // A missing `ShareSessionSummary` must NOT drop the session: synthesis
        // is a separate AI pass that may never have run, have failed, or
        // postdate the recording. It contributes the narrative and the key
        // moments; the screenshots exist either way, and dropping them was
        // why a meeting full of captured frames exported with no figures at
        // all. Same reasoning as `ObsidianExportService.sharedContentSection`,
        // which falls back to per-frame lines for exactly this case.
        return sessions.compactMap { session -> ReportModel.ShareSession? in
            let summary = summariesBySession[session.id]
            let sessionFrames = (framesBySession[session.id] ?? [])
                .sorted { $0.timestamp < $1.timestamp }

            let figures = figures(
                forKeyMoments: summary?.keyMoments ?? [],
                in: sessionFrames,
                meetingID: meeting.id,
                storage: storage
            )
            // Nothing to say and nothing to show — then there is no session.
            guard !figures.isEmpty || summary?.narrative.isEmpty == false else { return nil }

            return ReportModel.ShareSession(
                id: session.id,
                windowTitle: session.windowTitle,
                startLabel: timestampLabel(session.startTime),
                endLabel: timestampLabel(session.endTime),
                narrative: summary?.narrative ?? "",
                keyMoments: (summary?.keyMoments ?? []).map {
                    ReportModel.KeyMoment(
                        label: $0.label,
                        formattedTimestamp: timestampLabel($0.timestamp)
                    )
                },
                figures: figures
            )
        }
    }

    /// Pick one frame per key moment — the frame nearest that moment in time.
    ///
    /// Key moments are what the synthesis pass already judged worth
    /// remembering, so this is a real signal rather than "every Nth frame".
    /// It is a stand-in for the AI anchoring pass, which will place figures
    /// against summary sections instead of against their own session.
    private static func figures(
        forKeyMoments moments: [ShareSessionSummary.KeyMoment],
        in frames: [ScreenShareFrame],
        meetingID: UUID,
        storage: StorageManager
    ) -> [ReportModel.Figure] {
        guard !frames.isEmpty else { return [] }

        var used = Set<UUID>()
        var result: [ReportModel.Figure] = []

        for moment in moments {
            guard result.count < maxFiguresPerSession else { break }
            // The best-looking frame *near* the moment, not simply the
            // nearest: the closest frame in time is often a cut to the
            // speaker's camera, which illustrates nothing. Widen only if the
            // window turns up nothing at all.
            let candidates = frames.filter { !used.contains($0.id) }
            let nearby = candidates.filter {
                abs($0.timestamp - moment.timestamp) <= keyMomentWindow
            }
            let pool = nearby.isEmpty ? candidates : nearby
            guard let frame = pool.max(by: { lhs, rhs in
                let left = contentScore(lhs), right = contentScore(rhs)
                guard left == right else { return left < right }
                // Same quality — take the one closest to the moment.
                return abs(lhs.timestamp - moment.timestamp) > abs(rhs.timestamp - moment.timestamp)
            }) else { break }

            used.insert(frame.id)
            guard let data = imageData(for: frame, meetingID: meetingID, storage: storage) else {
                continue
            }
            result.append(
                ReportModel.Figure(
                    id: frame.id,
                    timestamp: frame.timestamp,
                    formattedTimestamp: frame.formattedTimestamp,
                    // The frame's own observation, NOT `moment.label`. A key
                    // moment describes what was happening in the meeting
                    // ("early discussion of the design workflow"); the caption
                    // has to describe the picture. Using the label produced
                    // captions about the call while the screenshot showed the
                    // document being reviewed — and the mismatch got worse
                    // once selection started hunting for the best content
                    // frame near the moment rather than the nearest one.
                    caption: shortCaption(for: frame),
                    imageData: data,
                    windowTitle: frame.windowTitle
                )
            )
        }

        // Key moments are what the recap judged memorable, but the anchoring
        // pass matches screenshots to the conversation and can only choose
        // from what it is offered. Top the pool up with the most
        // content-bearing frames spread across the rest of the session, so a
        // diagram discussed between two key moments is still a candidate.
        // With no key moments at all — synthesis never ran, or found none —
        // this is the whole selection, and a share that is nothing but video
        // still illustrates itself rather than vanishing.
        let remainingSlots = maxFiguresPerSession - result.count
        if remainingSlots > 0 {
            let unused = frames.filter { !used.contains($0.id) }
            let pool = result.isEmpty ? unused : unused.filter { contentScore($0) > 0 }
            for frame in representativeFrames(from: pool, limit: remainingSlots) {
                guard let data = imageData(for: frame, meetingID: meetingID, storage: storage) else {
                    continue
                }
                result.append(
                    ReportModel.Figure(
                        id: frame.id,
                        timestamp: frame.timestamp,
                        formattedTimestamp: frame.formattedTimestamp,
                        caption: shortCaption(for: frame),
                        imageData: data,
                        windowTitle: frame.windowTitle
                    )
                )
            }
        }

        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// How much a frame looks like *content* rather than a video call.
    ///
    /// Evenly-spaced sampling alone picks a lot of useless pictures: when the
    /// captured window is the meeting window rather than a popped-out share,
    /// most frames are a gallery of faces, which tells a reader nothing. The
    /// two signals that separate content from camera feed are the content
    /// type the vision pass assigned, and how much text OCR found — slides,
    /// code and dashboards are dense with text; faces are not.
    ///
    /// Deliberately a score, not a filter: a share that genuinely contains
    /// nothing but video should still illustrate itself rather than vanish.
    static func contentScore(_ frame: ScreenShareFrame) -> Int {
        var score = 0
        switch frame.contentType {
        case .slide, .document, .diagram: score += 40
        case .code, .terminal, .dashboard: score += 35
        case .video: score -= 45
        case .other, nil: break
        }
        // A still lifted from playing video is the same problem by another name.
        if frame.isVisualOnlyChange { score -= 30 }
        // Text density, capped so a wall of transcript cannot outweigh type.
        score += min((frame.ocrText?.count ?? 0) / 40, 30)
        if frame.observation?.isEmpty == false { score += 10 }
        return score
    }

    /// Up to `limit` frames: the most content-bearing one from each of
    /// `limit` equal slices of the session.
    ///
    /// Bucketing by time and then picking the best within each bucket keeps
    /// both properties that matter — coverage of the session's arc, and
    /// pictures worth printing. Sorting purely by score would return four
    /// near-identical frames of the same slide; sorting purely by time
    /// returns four pictures of people's faces.
    static func representativeFrames(
        from frames: [ScreenShareFrame],
        limit: Int
    ) -> [ScreenShareFrame] {
        guard limit > 0 else { return [] }
        let ordered = frames.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count > limit else { return ordered }

        let bucketSize = Double(ordered.count) / Double(limit)
        var picked: [ScreenShareFrame] = []
        var used = Set<UUID>()
        for bucket in 0..<limit {
            let start = Int((Double(bucket) * bucketSize).rounded(.down))
            let end = min(Int((Double(bucket + 1) * bucketSize).rounded(.down)), ordered.count)
            guard start < end else { continue }
            let best = ordered[start..<end]
                .filter { !used.contains($0.id) }
                .max { lhs, rhs in
                    let left = contentScore(lhs), right = contentScore(rhs)
                    // Ties break toward the earlier frame: the first view of a
                    // slide beats the same slide with a cursor moved.
                    return left == right ? lhs.timestamp > rhs.timestamp : left < right
                }
            if let best {
                used.insert(best.id)
                picked.append(best)
            }
        }
        return picked
    }

    /// A caption's worth of the frame's observation.
    ///
    /// `ScreenShareFrame.observation` is a 100–250 word paragraph — the vision
    /// pass is deliberately detailed so the final analysis has something to
    /// work with. Printed raw under a screenshot it is a wall of text, so take
    /// the first sentence and cap it. This is the fallback; when the
    /// anchoring pass runs it writes a real caption that names the topic.
    static func shortCaption(for frame: ScreenShareFrame) -> String {
        let observation = (frame.observation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observation.isEmpty else {
            return frame.windowTitle ?? "Shared screen"
        }
        // First sentence, if there is a sensible one.
        var caption = observation
        if let end = observation.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            let sentence = String(observation[..<end]).trimmingCharacters(in: .whitespaces)
            if sentence.count >= 20 { caption = sentence }
        }
        if caption.count > captionCap {
            let clipped = String(caption.prefix(captionCap))
            // Cut at a word boundary rather than mid-word.
            let boundary = clipped.lastIndex(of: " ").map { String(clipped[..<$0]) } ?? clipped
            caption = boundary.trimmingCharacters(in: .whitespaces) + "…"
        }
        return caption
    }

    /// Roughly two printed lines at figure-caption size.
    static let captionCap = 140

    /// Reads the frame off disk and downscales it. A frame whose file is
    /// missing — purged, or lost to a schema downgrade — is skipped rather
    /// than failing the whole export.
    private static func imageData(
        for frame: ScreenShareFrame,
        meetingID: UUID,
        storage: StorageManager
    ) -> Data? {
        let url = storage.frameURL(for: meetingID, relativePath: frame.imagePath)
        guard let raw = try? Data(contentsOf: url), !raw.isEmpty else { return nil }
        return ScreenFrameTriage.downscaledJPEG(raw, targetPixelCount: figurePixelBudget)
    }

    // MARK: - Transcript

    private static func transcript(for meeting: Meeting) -> [ReportModel.TranscriptLine] {
        meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .map {
                ReportModel.TranscriptLine(
                    speaker: $0.speaker.displayName,
                    formattedTimestamp: $0.formattedTimestamp,
                    text: $0.text
                )
            }
    }

    // MARK: - Helpers

    /// "m:ss", the same rendering `ScreenShareFrame` and `TranscriptSegment`
    /// use, so a timestamp in the report matches one in the app.
    /// `nonisolated` — pure formatting, and tests should not need the main
    /// actor to build a fixture.
    nonisolated static func timestampLabel(_ time: TimeInterval) -> String {
        String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }
}
