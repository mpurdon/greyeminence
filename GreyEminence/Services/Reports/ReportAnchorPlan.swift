import Foundation

/// Which captured screenshot belongs beside which summary section.
///
/// Cached on disk next to the meeting's audio and frames rather than in
/// SwiftData: the plan is derived data that can always be recomputed, and
/// keeping it out of the store avoids a schema version bump — and with it the
/// downgrade-wipe hazard that costs real rows when an older build launches.
struct ReportAnchorPlan: Codable, Sendable, Equatable {
    /// Bump whenever the anchoring prompt or the figure-*selection* logic
    /// changes. Without this the only thing that expires a cached plan is a
    /// new insight, so a prompt improvement would never reach any meeting
    /// already exported — and worse, a selection change means the cached
    /// anchors name frames the report no longer carries, which
    /// `applyingAnchors` drops silently, leaving a report with no links and
    /// no explanation.
    ///
    /// History:
    ///  1. initial
    ///  2. prompt rejects camera/gallery frames; selection scores content
    ///  3. every screenshot gets a caption, not only anchored ones
    ///  4. captions name on-screen content, never the call; wider observation
    ///     budget so the specifics survive into the prompt
    ///  5. pick only the few that carry the story; unpicked ones are not
    ///     printed, and captions tie the picture to its section
    ///  6. each candidate carries the transcript around its capture; the
    ///     model matches on the conversation and favours screenshots that
    ///     give a section context; the candidate pool is topped up beyond
    ///     key moments
    static let currentVersion = 6

    /// Missing in v1 files, which is intentional: decoding fails, the cache
    /// misses, and the plan is recomputed. Self-correcting rather than a
    /// migration.
    var version: Int = currentVersion

    /// The insight this plan was computed against. Regenerating a meeting's
    /// analysis produces a new insight, which invalidates the plan — the
    /// sections it refers to no longer exist.
    var insightID: UUID
    var anchors: [Anchor]
    var createdAt: Date
    var modelIdentifier: String

    struct Anchor: Codable, Sendable, Equatable {
        /// Index into `ReportModel.sections`, or nil when the screenshot
        /// evidences nothing in particular. Those still get a caption — a
        /// picture in the appendix with no explanation is just as useless as
        /// one with no link.
        var sectionIndex: Int?
        /// `ScreenShareFrame.id`.
        var frameID: UUID
        var caption: String
    }

    /// Plans computed for a different insight, or by an older planner, are
    /// stale and must not be used.
    func isValid(forInsight id: UUID) -> Bool {
        insightID == id && version == Self.currentVersion
    }
}

extension ReportModel {

    /// Keep only the summary sections the user ticked.
    ///
    /// Must run AFTER anchoring: the cached plan's `sectionIndex` values index
    /// into the full section list, so filtering first would silently attach
    /// figures to the wrong headings.
    ///
    /// A screenshot that was tied to a dropped section loses that tie rather
    /// than keeping it — a cross-reference to a section no longer in the
    /// document is a dead link in the PDF with nothing to show for it.
    func keepingSections(_ ids: Set<Int>) -> ReportModel {
        var result = self
        result.sections = sections.filter { ids.contains($0.id) }

        func retie(_ figure: Figure) -> Figure {
            guard let index = figure.sectionIndex, !ids.contains(index) else { return figure }
            var figure = figure
            figure.sectionIndex = nil
            figure.sectionTitle = nil
            return figure
        }
        result.shareSessions = shareSessions.map { session in
            var session = session
            session.figures = session.figures.map(retie)
            return session
        }
        return result
    }

    /// Keep at most `limit` appendix screenshots, spread across the meeting.
    ///
    /// The no-plan path: with nothing tying pictures to sections, printing
    /// them all turns a summary into a contact sheet. Spread by time rather
    /// than taking the first few, so the ones kept still cover the meeting.
    func keepingBestFigures(limit: Int) -> ReportModel {
        let all = shareSessions.flatMap(\.figures).sorted { $0.timestamp < $1.timestamp }
        guard all.count > limit else { return self }

        let step = Double(all.count) / Double(limit)
        let keep = Set((0..<limit).map { all[Int((Double($0) * step).rounded(.down))].id })

        var result = self
        result.shareSessions = shareSessions.map { session in
            var session = session
            session.figures = session.figures.filter { keep.contains($0.id) }
            return session
        }
        return result
    }

    /// Attach anchored figures to the sections they evidence.
    ///
    /// `figuresAtEnd` decides where they physically print: inside the section
    /// (the default — the figure sits with the prose) or collected in a
    /// Figures appendix, the classic formal-report arrangement where evidence
    /// lives at the back and the text refers to it. Either way the figure
    /// records which section it belongs to, so the renderer can cross-link
    /// them in both directions.
    ///
    /// Pure, so the placement logic is testable without an AI call. Anchors
    /// that name a section or frame that no longer exists are dropped rather
    /// than throwing — a stale or hallucinated identifier should cost one
    /// figure, never the whole export.
    /// `keepsUnpicked` prints the screenshots the plan did not choose, in the
    /// appendix. Off by default: this is a summary, and a back-of-report dump
    /// of everything captured is length without story. The full set is always
    /// in the app.
    func applyingAnchors(
        _ plan: ReportAnchorPlan,
        figuresAtEnd: Bool = false,
        keepsUnpicked: Bool = false
    ) -> ReportModel {
        var result = self

        let available = Dictionary(
            shareSessions.flatMap(\.figures).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Captions apply to every screenshot the plan mentions, anchored or
        // not — the point is that a reader can tell what they are looking at
        // and why it is in the document.
        var captions: [UUID: String] = [:]
        for anchor in plan.anchors {
            let caption = anchor.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !caption.isEmpty else { continue }
            captions[anchor.frameID] = caption
        }
        func captioned(_ figure: Figure) -> Figure {
            guard let caption = captions[figure.id] else { return figure }
            var figure = figure
            figure.caption = caption
            return figure
        }

        var claimed = Set<UUID>()
        var annotated: [UUID: Figure] = [:]
        var bySection: [Int: [Figure]] = [:]
        for anchor in plan.anchors {
            guard let sectionIndex = anchor.sectionIndex,
                  sections.indices.contains(sectionIndex) else { continue }
            guard let base = available[anchor.frameID] else { continue }
            // One figure cannot illustrate two sections; the first anchor wins.
            guard claimed.insert(anchor.frameID).inserted else { continue }
            var figure = captioned(base)
            figure.sectionIndex = sectionIndex
            figure.sectionTitle = sections[sectionIndex].title
            annotated[figure.id] = figure
            bySection[sectionIndex, default: []].append(figure)
        }

        if figuresAtEnd {
            // Picked screenshots print at the back; their sections link
            // forward to them.
            result.shareSessions = shareSessions.map { session in
                var session = session
                session.figures = session.figures.compactMap { figure in
                    if let anchored = annotated[figure.id] { return anchored }
                    return keepsUnpicked ? captioned(figure) : nil
                }
                return session
            }
            return result
        }

        for (index, figures) in bySection {
            result.sections[index].figures = figures.sorted { $0.timestamp < $1.timestamp }
        }

        // Screenshots the plan passed over are dropped rather than piled into
        // an appendix: they made the report long without making it clearer.
        result.shareSessions = shareSessions.map { session in
            var session = session
            session.figures = keepsUnpicked
                ? session.figures.filter { !claimed.contains($0.id) }.map(captioned)
                : []
            return session
        }
        return result
    }
}
