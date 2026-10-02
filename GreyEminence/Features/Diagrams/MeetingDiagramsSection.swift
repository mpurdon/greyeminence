import SwiftUI

/// Shows a diagram in the Diagrams view. `ContentView`, which owns the
/// selection, provides it; a meeting's Diagrams section calls it.
struct OpenDiagramAction: Sendable {
    let run: @MainActor @Sendable (DiagramTopic) -> Void

    @MainActor
    func callAsFunction(_ topic: DiagramTopic) { run(topic) }
}

private struct OpenDiagramKey: EnvironmentKey {
    static let defaultValue = OpenDiagramAction { _ in }
}

extension EnvironmentValues {
    var openDiagram: OpenDiagramAction {
        get { self[OpenDiagramKey.self] }
        set { self[OpenDiagramKey.self] = newValue }
    }
}

/// In a meeting's analysis: what it has to draw, one click from the
/// drawing. Add one by hand when the detection missed it.
struct MeetingDiagramsSection: View {
    let meeting: Meeting

    @Environment(\.openDiagram) private var openDiagram
    private var index: DiagramIndexStore { .shared }
    private var store: DiagramStore { .shared }

    var body: some View {
        let signals = index.signals(for: meeting.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Diagrams", systemImage: DiagramStyle.symbol)
                    .font(.headline)
                Spacer()
                if store.redetecting.contains(meeting.id) {
                    ProgressView().controlSize(.small)
                        .help("Looking for diagrams again")
                }
                Menu {
                    ForEach(DiagramKind.allCases) { kind in
                        Button("Add \(kind.label)") {
                            index.add(kind, title: "\(meeting.title) \(kind.label.lowercased())", for: meeting.id)
                        }
                    }
                    Divider()
                    Button("Detect and Redraw") { store.detectAgain(meeting) }
                        .disabled(store.redetecting.contains(meeting.id))
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Draw a flow or timeline the analysis didn't spot, or look for them all again")
            }
            if let error = store.detectionError(for: meeting) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if signals.isEmpty {
                Text("Nothing detected to draw.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(signals) { signal in
                let topic = DiagramTopic(meeting: meeting, signal: signal)
                Button {
                    openDiagram(topic)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: signal.kind.systemImage)
                            .foregroundStyle(DiagramStyle.tint(signal.kind))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(signal.title).font(.callout.weight(.medium))
                            Text(store.diagram(for: topic) == nil ? "\(signal.kind.label) · not drawn yet" : "\(signal.kind.label) · drawn")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
