import SwiftUI
import AppKit

/// Small button that copies a string to the pasteboard and briefly shows a
/// checkmark for confirmation. Pass `label` to render "Copy …" alongside the
/// icon; omit it for icon-only.
struct CopyButton: View {
    let content: () -> String
    var label: String? = nil
    var help: String? = nil
    var font: Font = .caption

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    init(
        content: @autoclosure @escaping () -> String,
        label: String? = nil,
        help: String? = nil,
        font: Font = .caption
    ) {
        self.content = content
        self.label = label
        self.help = help
        self.font = font
    }

    init(
        label: String? = nil,
        help: String? = nil,
        font: Font = .caption,
        content: @escaping () -> String
    ) {
        self.content = content
        self.label = label
        self.help = help
        self.font = font
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content(), forType: .string)
            withAnimation { copied = true }
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled {
                    await MainActor.run { withAnimation { copied = false } }
                }
            }
        } label: {
            icon
        }
        .buttonStyle(.plain)
        .help(help ?? label ?? "Copy")
        .onDisappear { resetTask?.cancel() }
    }

    @ViewBuilder
    private var icon: some View {
        if copied {
            Label("Copied", systemImage: "checkmark")
                .foregroundStyle(.green)
                .font(font)
        } else if let label {
            Label(label, systemImage: "doc.on.doc")
                .font(font)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "doc.on.doc")
                .font(font)
                .foregroundStyle(.secondary)
        }
    }
}
