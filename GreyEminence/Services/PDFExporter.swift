import Foundation
import AppKit

/// Renders a markdown string to a PDF on disk. Used to export rubric
/// section instructions as a shareable file the interviewer can hand
/// to the candidate.
enum PDFExporter {
    /// US-Letter at 72 DPI with half-inch margins.
    private static let pageSize = NSSize(width: 612, height: 792)
    private static let margin: CGFloat = 36

    /// Generate PDF data for the given markdown. Falls back to plain
    /// text rendering if `AttributedString(markdown:)` rejects the input.
    /// AppKit view rendering must run on the main actor.
    @MainActor
    static func pdfData(forMarkdown markdown: String, title: String? = nil) -> Data? {
        let attributed = makeAttributedString(forMarkdown: markdown, title: title)

        let textView = NSTextView(frame: NSRect(
            x: margin,
            y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        ))
        textView.textStorage?.setAttributedString(attributed)
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = .white

        // Size the view to fit the rendered text, capped to the page.
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let height = max(used.height + margin * 2, pageSize.height)
        let containerFrame = NSRect(
            x: 0,
            y: 0,
            width: pageSize.width,
            height: height
        )

        let container = NSView(frame: containerFrame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        textView.frame = NSRect(
            x: margin,
            y: margin,
            width: pageSize.width - margin * 2,
            height: height - margin * 2
        )
        container.addSubview(textView)
        return container.dataWithPDF(inside: container.bounds)
    }

    /// Save markdown as a PDF. Surfaces an `NSSavePanel` so the user
    /// picks the destination. Returns the chosen URL on success.
    @MainActor
    @discardableResult
    static func saveMarkdownAsPDF(
        _ markdown: String,
        suggestedFilename: String,
        title: String? = nil
    ) -> URL? {
        guard let data = pdfData(forMarkdown: markdown, title: title) else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sanitize(suggestedFilename)
        panel.title = "Save Section Instructions"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static func makeAttributedString(forMarkdown markdown: String, title: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()

        if let title, !title.isEmpty {
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            result.append(NSAttributedString(string: title + "\n\n", attributes: titleAttrs))
        }

        let body: NSAttributedString
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full
        )
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            // Convert SwiftUI AttributedString → NSAttributedString.
            body = NSAttributedString(parsed)
        } else {
            body = NSAttributedString(
                string: markdown,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.black
                ]
            )
        }
        result.append(body)
        return result
    }

    private static func sanitize(_ name: String) -> String {
        name.sanitizedForFilename()
    }
}
