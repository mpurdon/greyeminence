import AppKit
import SwiftUI

/// A diagram as a file: the same native views, rendered at their natural
/// size on one page — a flow doesn't paginate — in light mode for paper and
/// white-page viewers.
@MainActor
enum DiagramExporter {
    enum Format { case pdf, png }

    enum ExportError: LocalizedError {
        case couldNotRender

        var errorDescription: String? { "Couldn't render the diagram." }
    }

    static let timelineWidth: CGFloat = 960

    static func write(_ diagram: StoredDiagram, meeting: Meeting, format: Format, to url: URL) throws {
        let layout = diagram.flow.map(FlowDiagramLayout.init)
        let renderer = ImageRenderer(content: page(diagram, layout: layout, meeting: meeting))
        let width = layout.map { max($0.size.width + 48, 480) } ?? timelineWidth + 48
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        switch format {
        case .png:
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else { throw ExportError.couldNotRender }
            try data.write(to: url, options: .atomic)
        case .pdf:
            var failed = false
            renderer.render { size, draw in
                var box = CGRect(origin: .zero, size: size)
                guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { failed = true; return }
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
                context.closePDF()
            }
            if failed { throw ExportError.couldNotRender }
        }
    }

    static func page(_ diagram: StoredDiagram, layout: FlowDiagramLayout?, meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(diagram.kind.label.uppercased(), systemImage: diagram.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DiagramStyle.tint(diagram.kind))
                Text(diagram.title ?? "")
                    .font(.title2.weight(.semibold))
                Text("\(meeting.title) · \(meeting.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let flow = diagram.flow, let layout {
                FlowCanvas(flow: flow, layout: layout)
                    .frame(width: layout.size.width, height: layout.size.height)
            } else if let timeline = diagram.timeline {
                TimelineDiagramView(timeline: timeline, meetingDate: meeting.date, showsToday: false)
                    .frame(width: timelineWidth)
            }
            if let summary = diagram.summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}
