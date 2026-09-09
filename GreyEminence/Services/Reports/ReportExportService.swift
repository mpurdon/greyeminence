import AppKit
import Foundation

/// Ties the report pipeline together: snapshot a meeting, render it, ask the
/// user where to put the PDF, write it.
@MainActor
enum ReportExportService {

    /// How many screenshots a report may carry when there is no anchoring
    /// plan to choose them. Small on purpose: unplaced pictures are the ones
    /// that make a summary long without making it clearer.
    static let unplannedFigureLimit = 3

    enum ExportError: LocalizedError {
        case nothingToReport

        var errorDescription: String? {
            switch self {
            case .nothingToReport:
                "This meeting has no summary, action items or shared screens to report on yet."
            }
        }
    }

    /// Build and save a PDF for `meeting`. Returns the chosen URL, or nil if
    /// the user cancelled the save panel.
    @discardableResult
    static func exportPDF(
        for meeting: Meeting,
        options: ReportExportOptions
    ) async throws -> URL? {
        let template = options.template
        var report = ReportModelBuilder.build(
            from: meeting,
            includeTranscript: template.includesTranscript
        )
        guard !report.isEmpty else { throw ExportError.nothingToReport }

        // Ask before rendering: a cancelled save should not have cost the
        // user a few seconds of layout and a pile of base64.
        guard let destination = savePanelURL(for: report.meta, template: template) else { return nil }

        if template.includesFigures {
            if let plan = await anchorPlan(for: meeting, report: report) {
                report = report.applyingAnchors(
                    plan,
                    figuresAtEnd: template.figuresAtEnd,
                    keepsUnpicked: template.includesUnpickedFigures
                )
            } else {
                // No plan — AI unconfigured, offline, or unparseable. Without
                // one, nothing can be tied to a section, so fall back to a
                // handful of the most content-bearing screenshots rather than
                // every one the builder gathered.
                report = report.keepingBestFigures(limit: Self.unplannedFigureLimit)
            }
        }

        // Last, so the anchoring above still sees the full section list its
        // cached plan was computed against.
        report = report.keepingSections(options.sectionIDs)

        let html = ReportHTMLRenderer.render(report, template: template)
        try await ReportPDFRenderer.writePDF(html: html, to: destination)

        LogManager.send(
            "Exported report: \"\(report.meta.title)\" (\(report.sections.count) sections, \(report.allFigures.count) figures, template \(template.id))",
            category: .general,
            meetingID: meeting.id
        )
        // A report with no pictures is the most confusing possible outcome, so
        // say which of the several reasons it was.
        if template.includesFigures && report.allFigures.isEmpty {
            LogManager.send(
                "Report has no figures: \(figureDiagnosis(for: meeting))",
                category: .general,
                level: .warning,
                meetingID: meeting.id
            )
        }
        return destination
    }

    /// Why a report came out with no pictures. Checked in the order the
    /// pipeline would have failed, so the first true statement is the cause.
    private static func figureDiagnosis(for meeting: Meeting) -> String {
        let frames = meeting.screenFrames
        guard !frames.isEmpty else {
            return "this meeting captured no screen-share frames"
        }
        let missing = frames.filter { frame in
            let url = StorageManager.shared.frameURL(for: meeting.id, relativePath: frame.imagePath)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        if missing.count == frames.count {
            return "all \(frames.count) frame image(s) are missing from disk — the recording folder may have been purged"
        }
        if !missing.isEmpty {
            return "\(missing.count) of \(frames.count) frame image(s) are missing from disk"
        }
        return "\(frames.count) frame(s) exist and are readable — this is unexpected, please report it"
    }

    /// Cached anchoring plan, computed on first export of a given analysis.
    ///
    /// Every failure path here returns nil and the report still exports, with
    /// its figures in the appendix — an unreachable API or an unreadable
    /// response should cost placement, never the document.
    private static func anchorPlan(for meeting: Meeting, report: ReportModel) async -> ReportAnchorPlan? {
        guard let insight = meeting.latestInsight else { return nil }
        guard !report.sections.isEmpty else { return nil }

        let candidates = figureCandidates(for: meeting, report: report)
        guard !candidates.isEmpty else { return nil }

        if let cached = StorageManager.shared.loadReportAnchorPlan(
            for: meeting.id, insightID: insight.id
        ) {
            return cached
        }

        // Double optional: the factory throws on a bad config and returns nil
        // when AI is simply not set up. Both mean "no anchoring, export anyway".
        guard let client = try? await AIClientFactory.makeClient() else { return nil }

        let outlines = report.sections.map { section in
            ReportComposerService.SectionOutline(
                index: section.id,
                title: section.title,
                pointLabels: section.points.map(\.label)
            )
        }

        do {
            let plan = try await ReportComposerService(client: client).anchors(
                sections: outlines,
                frames: candidates,
                insightID: insight.id,
                meetingID: meeting.id
            )
            StorageManager.shared.saveReportAnchorPlan(plan, for: meeting.id)
            return plan
        } catch {
            LogManager.send(
                "Figure anchoring skipped: \(error.localizedDescription)",
                category: .general,
                level: .warning,
                meetingID: meeting.id
            )
            return nil
        }
    }

    /// Only frames the report actually carries can be anchored, so the
    /// catalogue is drawn from the built model rather than from every frame
    /// the meeting captured.
    private static func figureCandidates(
        for meeting: Meeting,
        report: ReportModel
    ) -> [ReportComposerService.FrameCandidate] {
        let present = Set(report.allFigures.map(\.id))
        let byID = Dictionary(
            meeting.screenFrames.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Frame timestamps and segment times share the meeting clock, so the
        // words spoken around a capture are a plain window over the segments.
        let transcript = meeting.segments.map {
            ReportComposerService.TranscriptLine(
                startTime: $0.startTime,
                speaker: $0.speaker.displayName,
                text: $0.text
            )
        }
        return report.allFigures.compactMap { figure in
            let frame = byID[figure.id]
            guard present.contains(figure.id) else { return nil }
            return ReportComposerService.FrameCandidate(
                id: figure.id,
                formattedTimestamp: figure.formattedTimestamp,
                observation: frame?.observation ?? figure.caption,
                contentType: frame?.contentType?.rawValue,
                entities: frame?.keyEntities ?? [],
                transcriptExcerpt: ReportComposerService.transcriptExcerpt(
                    around: figure.timestamp,
                    in: transcript
                )
            )
        }
    }

    private static func savePanelURL(for meta: ReportModel.Meta, template: ReportTemplate) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFilename(for: meta, template: template)
        panel.title = "Export Meeting Report"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// "Architecture Braintrust — 2026-08-12 (TJ).pdf", with anything the
    /// file system would object to removed.
    ///
    /// The template tag is what lets you export the same meeting under every
    /// template into one folder and compare them side by side, instead of
    /// each export overwriting the last.
    static func suggestedFilename(for meta: ReportModel.Meta, template: ReportTemplate) -> String {
        let calendar = Calendar.current
        let day = String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: meta.date),
            calendar.component(.month, from: meta.date),
            calendar.component(.day, from: meta.date)
        )
        return sanitize("\(meta.title) — \(day) (\(template.code))") + ".pdf"
    }

    private static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?\"<>|*")
        return name.unicodeScalars
            .filter { !illegal.contains($0) }
            .map(String.init)
            .joined()
    }
}
