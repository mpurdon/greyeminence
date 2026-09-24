import AppKit
import SwiftUI

/// Writes a refinement report to PDF using the same SwiftUI blocks the app
/// shows, so the export looks like the screen rather than like a second,
/// hand-maintained rendition of it.
///
/// `ImageRenderer` draws each block into a PDF context as vectors. Blocks
/// are measured at the page's content width and packed onto US Letter
/// pages whole — page breaks only fall between blocks.
@MainActor
enum RefinementPDFExporter {
    enum Scope {
        case full
        case specOnly
    }

    enum ExportError: LocalizedError {
        case couldNotCreateFile

        var errorDescription: String? {
            "Couldn't create the PDF file."
        }
    }

    static let pageSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 44
    static let footerHeight: CGFloat = 22

    static var contentWidth: CGFloat { pageSize.width - margin * 2 }
    static var contentHeight: CGFloat { pageSize.height - margin * 2 - footerHeight }

    static func write(
        _ report: RefinementReport,
        scope: Scope,
        feature: String,
        meeting: Meeting,
        to url: URL
    ) throws {
        let title = RefinementReportLayout.titleBlock(
            feature: feature,
            meetingTitle: meeting.title,
            date: meeting.date,
            duration: meeting.formattedDuration,
            kind: scope == .full ? "Refinement report" : "Refinement spec",
            generated: "Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(RefinementReportService.modelLabel(report.modelIdentifier))"
        )

        var blocks = [title]
        let specSpacing = RefinementReportLayout.sectionSpacing
        switch scope {
        case .full:
            blocks += RefinementReportLayout.sectionBlocks(report.content).map {
                RefinementBlock(id: $0.id, spacingBefore: $0.id == 0 ? 16 : $0.spacingBefore, view: $0.view)
            }
            // The spec is what gets handed on, so it opens its own page.
            var spec = specBlocks(report.content.spec, spacingBefore: specSpacing)
            if !spec.isEmpty { spec[0].startsNewPage = true }
            blocks += spec
        case .specOnly:
            blocks += specBlocks(report.content.spec, spacingBefore: 16)
        }

        try render(blocks, footer: "\(feature) — \(meeting.date.formatted(date: .abbreviated, time: .omitted))", to: url)
    }

    // MARK: - Layout

    /// The spec as one card when it fits on a page, otherwise as a run of
    /// cards split at its sub-headings.
    private static func specBlocks(_ spec: RefinementReportContent.Spec, spacingBefore: CGFloat) -> [RefinementBlock] {
        let whole = RefinementBlock(id: 10_000, spacingBefore: spacingBefore, view: AnyView(RefinementSpecCard(spec: spec)))
        if measure(whole.view).height <= contentHeight { return [whole] }
        return RefinementSpecCard.Part.allCases.enumerated().map { index, part in
            RefinementBlock(
                id: 10_001 + index,
                spacingBefore: index == 0 ? spacingBefore : 8,
                view: AnyView(RefinementSpecCard(spec: spec, parts: [part], showsTitle: index == 0))
            )
        }
    }

    private struct Placement {
        let renderer: ImageRenderer<AnyView>
        let size: CGSize
        let y: CGFloat
        let scale: CGFloat
    }

    private static func render(_ blocks: [RefinementBlock], footer: String, to url: URL) throws {
        var pages: [[Placement]] = [[]]
        var cursor: CGFloat = 0

        for block in blocks {
            let renderer = makeRenderer(block.view, width: contentWidth)
            let size = measure(renderer)
            // Anything taller than a page is shrunk to fit rather than cut.
            let scale = size.height > contentHeight ? contentHeight / size.height : 1
            let height = size.height * scale
            let spacing = pages[pages.count - 1].isEmpty ? 0 : block.spacingBefore

            let overflows = cursor + spacing + height > contentHeight
            if overflows || block.startsNewPage, !pages[pages.count - 1].isEmpty {
                pages.append([])
                cursor = 0
                pages[pages.count - 1].append(Placement(renderer: renderer, size: size, y: 0, scale: scale))
                cursor = height
            } else {
                pages[pages.count - 1].append(Placement(renderer: renderer, size: size, y: cursor + spacing, scale: scale))
                cursor += spacing + height
            }
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ExportError.couldNotCreateFile
        }

        for (index, page) in pages.enumerated() {
            context.beginPDFPage(nil)
            for placement in page {
                let height = placement.size.height * placement.scale
                context.saveGState()
                // PDF space is bottom-up; `y` counts down from the top margin.
                context.translateBy(x: margin, y: pageSize.height - margin - placement.y - height)
                context.scaleBy(x: placement.scale, y: placement.scale)
                placement.renderer.render { _, draw in draw(context) }
                context.restoreGState()
            }
            drawFooter("\(footer)    Page \(index + 1) of \(pages.count)", in: context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func drawFooter(_ text: String, in context: CGContext) {
        let renderer = makeRenderer(AnyView(
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        ), width: contentWidth)
        let size = measure(renderer)
        context.saveGState()
        context.translateBy(x: margin, y: margin - size.height + 6)
        renderer.render { _, draw in draw(context) }
        context.restoreGState()
    }

    /// Light appearance regardless of the app's: a PDF is read on paper
    /// and in viewers with white pages.
    private static func makeRenderer(_ view: AnyView, width: CGFloat) -> ImageRenderer<AnyView> {
        let renderer = ImageRenderer(content: AnyView(
            view
                .frame(width: width, alignment: .leading)
                .environment(\.colorScheme, .light)
        ))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer
    }

    private static func measure(_ view: AnyView) -> CGSize {
        measure(makeRenderer(view, width: contentWidth))
    }

    private static func measure(_ renderer: ImageRenderer<AnyView>) -> CGSize {
        var measured = CGSize.zero
        renderer.render { size, _ in measured = size }
        return measured
    }
}
