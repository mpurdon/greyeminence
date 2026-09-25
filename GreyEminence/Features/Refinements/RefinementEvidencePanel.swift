import SwiftUI

/// The rationale's sources, in the inspector slot where Ask shows its
/// snippets. Evidence lists every cited moment, numbered to match the chips,
/// with the transcript lines behind it; Transcript shows the whole meeting
/// with cited lines marked. A chip selects its number, and whichever view
/// is showing scrolls to it.
struct RefinementEvidencePanel: View {
    let sources: RefinementEvidenceSources
    @Binding var selected: Int?
    /// Opens the meeting itself at a transcript line.
    var onOpenLine: (UUID) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case evidence = "Evidence"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .evidence

    private var index: RefinementEvidenceIndex { sources.index }
    private var passages: [Int: [RefinementPassage.Line]] { sources.passages }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch mode {
            case .evidence: evidenceList
            case .transcript: transcriptList
            }
        }
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Sources")
                    .font(.subheadline.weight(.semibold))
                Text("\(index.entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Evidence

    private var evidenceList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if index.entries.isEmpty && index.uncitedNotes.isEmpty {
                        Text("This report names no transcript moments. Regenerate it to get citations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(index.entries) { entry in
                        evidenceCard(entry, passage: passages[entry.id] ?? [])
                            .id(entry.id)
                    }
                    if !index.uncitedNotes.isEmpty {
                        Text("NOT TIED TO A MOMENT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.horizontal, 4)
                        ForEach(Array(index.uncitedNotes.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 4) {
                                supportsLine(item.ref, item.text)
                                Text(item.note)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: selected) { _, number in scroll(proxy, to: number) }
            .onAppear { scroll(proxy, to: selected) }
        }
    }

    private func evidenceCard(_ entry: RefinementEvidenceIndex.Entry, passage: [RefinementPassage.Line]) -> some View {
        let isSelected = selected == entry.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(entry.id)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 20, minHeight: 16)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                Text(entry.citation.label)
                    .font(.caption.monospacedDigit().weight(.medium))
                Spacer()
                Button {
                    selected = entry.id
                    mode = .transcript
                } label: {
                    Label("In transcript", systemImage: "text.alignleft")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Show this passage in the full transcript")
                if let first = passage.first {
                    Button {
                        onOpenLine(first.id)
                    } label: {
                        Label("Open in meeting", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Open the meeting at this passage")
                }
            }
            ForEach(Array(entry.supports.enumerated()), id: \.offset) { _, support in
                supportsLine(support.ref, support.text)
            }
            if let note = entry.note {
                Text(note)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if passage.isEmpty {
                Text("No transcript line at \(entry.citation.label).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(passage) { line in transcriptLine(line, highlighted: false) }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = entry.id }
        .textSelection(.enabled)
    }

    private func supportsLine(_ ref: RefinementItemRef, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(ref.kindLabel.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(RefinementStyle.tint)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(2)
        }
    }

    // MARK: - Transcript

    private var transcriptList: some View {
        let selectedLines = Set((selected.flatMap { passages[$0] } ?? []).map(\.id))

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sources.lines) { line in
                        let numbers = sources.numbersByLine[line.id] ?? []
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            transcriptLine(line, highlighted: selectedLines.contains(line.id))
                            Spacer(minLength: 0)
                            if !numbers.isEmpty {
                                Button {
                                    selected = numbers[0]
                                } label: {
                                    Text(numbers.map(String.init).joined(separator: ","))
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            selectedLines.contains(line.id) ? Color.accentColor.opacity(0.14)
                                : numbers.isEmpty ? Color.clear : Color.accentColor.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .id(line.id)
                        .contextMenu {
                            Button("Open in Meeting") { onOpenLine(line.id) }
                        }
                        .onTapGesture(count: 2) { onOpenLine(line.id) }
                        .help("Double-click to open the meeting here")
                    }
                }
                .padding(8)
            }
            .onChange(of: selected) { _, number in scrollTranscript(proxy, to: number) }
            .onAppear { scrollTranscript(proxy, to: selected) }
        }
    }

    private func transcriptLine(_ line: RefinementPassage.Line, highlighted: Bool) -> some View {
        (
            Text(ReportModelBuilder.timestampLabel(line.startTime) + "  ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            + Text(line.speaker + ": ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            + Text(line.text)
                .font(.caption)
                .foregroundStyle(.primary)
        )
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    // MARK: - Scrolling

    private func scroll(_ proxy: ScrollViewProxy, to number: Int?) {
        guard let number else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(number, anchor: .top) }
        }
    }

    private func scrollTranscript(_ proxy: ScrollViewProxy, to number: Int?) {
        guard let number, let first = passages[number]?.first else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(first.id, anchor: .center) }
        }
    }
}
