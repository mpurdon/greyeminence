import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One detected diagram: build it, read it, fix it, export it.
struct DiagramDetailView: View {
    let topic: DiagramTopic
    /// Opens the meeting, at a transcript line when one is given.
    var onOpenMeeting: (Meeting, UUID?) -> Void

    private var store: DiagramStore { .shared }
    private var meeting: Meeting { topic.meeting }
    private var diagram: StoredDiagram? { store.diagram(for: topic) }
    private var isGenerating: Bool { store.isGenerating(topic) }

    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false
    @State private var selectedID: String?
    @State private var lines: [RefinementPassage.Line] = []
    @State private var confirmRegenerate = false
    @State private var exportMessage: String?
    @State private var zoom: CGFloat = 1
    /// Bumped to fit the diagram to the pane — on opening, and from Fit.
    @State private var fitRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let diagram, !isGenerating {
                VStack(spacing: 0) {
                    if store.error(for: topic) != nil || exportMessage != nil {
                        banners.padding(10)
                        Divider()
                    }
                    // A flow runs down, so its overview sits beside it. A
                    // timeline runs across and reads as a page — summary,
                    // chart, what's undated, risks — with the details of
                    // a selected deliverable beside it.
                    if diagram.kind == .timeline {
                        HStack(spacing: 0) {
                            drawing(diagram)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if selectedID != nil {
                                Divider()
                                sidebar(diagram)
                                    .frame(width: 320)
                            }
                        }
                    } else {
                        HStack(spacing: 0) {
                            drawing(diagram)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            sidebar(diagram)
                                .frame(width: 320)
                        }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        banners
                        if isGenerating { generating } else { emptyState }
                    }
                    .padding(20)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: "\(meeting.id)-\(meeting.segments.count)-\(meeting.transcriptionModel ?? "")") {
            lines = RefinementPassage.lines(for: meeting)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(topic.signal.kind.label.uppercased(), systemImage: topic.signal.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DiagramStyle.tint(topic.signal.kind))
                Text(diagram?.title ?? topic.signal.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Button(meeting.title) { onOpenMeeting(meeting, nil) }
                        .buttonStyle(.link)
                    Text("·")
                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                    if let diagram, !isGenerating {
                        Text("·")
                        Text("drawn \(diagram.generatedAt.formatted(date: .abbreviated, time: .omitted))\(diagram.editedAt == nil ? "" : ", edited")")
                            .foregroundStyle(.tertiary)
                            .help("\(AIPricing.modelLabel(diagram.modelIdentifier)), \(diagram.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if developerToolsEnabled {
                    HStack(spacing: 4) {
                        Text(topic.diagramID)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        CopyButton(content: topic.diagramID, help: "Copy diagram ID", font: .caption2)
                    }
                }
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if isGenerating {
                Button("Cancel") { store.cancel(topic) }
            } else if diagram != nil {
                Button {
                    if diagram?.editedAt != nil { confirmRegenerate = true } else { store.generate(topic) }
                } label: {
                    Label("Redraw", systemImage: "arrow.clockwise")
                }
                .help("Draw it again from the transcript. Replaces this diagram.")
                .confirmationDialog("Redraw this diagram?", isPresented: $confirmRegenerate) {
                    Button("Redraw and Discard Edits", role: .destructive) { store.generate(topic) }
                } message: {
                    Text("A new drawing replaces this one, along with your changes to it.")
                }
            }
            if let diagram, !isGenerating {
                Menu {
                    Button("Copy as Mermaid") { copyMermaid(diagram) }
                    Divider()
                    Button("Export PDF…") { export(diagram, as: .pdf) }
                    Button("Export PNG…") { export(diagram, as: .png) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .help("Mermaid pastes into Jira, Confluence and GitHub, which draw it")
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func drawing(_ diagram: StoredDiagram) -> some View {
        if let flow = diagram.flow {
            let layout = FlowDiagramLayout(flow)
            ZStack(alignment: .bottomTrailing) {
                ZoomableCanvas(contentSize: layout.size, zoom: $zoom, fitRequest: fitRequest) {
                    FlowCanvas(flow: flow, layout: layout, selectedNodeID: selectedID, onSelect: { selectedID = $0 })
                        .frame(width: layout.size.width, height: layout.size.height)
                }
                zoomControls
                    .padding(12)
            }
            .onAppear { fitRequest += 1 }
        } else if let timeline = diagram.timeline {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let summary = diagram.summary {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 820, alignment: .leading)
                    }
                    TimelineDiagramView(
                        timeline: timeline, meetingDate: meeting.date, selectedItemID: selectedID, onSelect: { selectedID = $0 },
                        onSetDate: setDate, onIgnore: setIgnored
                    )
                    if !diagram.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RISKS AND ASSUMPTIONS")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(diagram.notes, id: \.self) { note in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    Text(note)
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: 820, alignment: .leading)
                    }
                    Text("Click a deliverable to see where it was said or to change it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sidebar(_ diagram: StoredDiagram) -> some View {
        DiagramSidebar(
            topic: topic,
            diagram: diagram,
            selectedID: $selectedID,
            lines: lines,
            onOpenLine: { onOpenMeeting(meeting, $0) }
        )
    }

    /// The date you gave something the meeting left undated: exact, since
    /// you said it, with the meeting's phrase kept.
    private func setDate(_ itemID: String, _ date: Date) {
        store.edit(topic) { stored in
            guard let index = stored.timeline?.items.firstIndex(where: { $0.id == itemID }) else { return }
            stored.timeline?.items[index].due = TimelineDiagram.string(from: date)
            stored.timeline?.items[index].confidence = "exact"
        }
    }

    private func setIgnored(_ itemID: String, _ ignored: Bool) {
        store.edit(topic) { stored in
            guard let index = stored.timeline?.items.firstIndex(where: { $0.id == itemID }) else { return }
            stored.timeline?.items[index].isIgnored = ignored ? true : nil
        }
        if ignored, selectedID == itemID { selectedID = nil }
    }

    /// Zoom out, the level (click for 100%), zoom in, and fit. ⌘−, ⌘0 and
    /// ⌘+ do the same; pinch works too.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                zoom = max(zoom / 1.25, ZoomableCanvas<EmptyView>.minZoom)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help("Zoom out (⌘−)")
            Button {
                zoom = 1
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 40)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Actual size (⌘0)")
            Button {
                zoom = min(zoom * 1.25, ZoomableCanvas<EmptyView>.maxZoom)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .keyboardShortcut("=", modifiers: .command)
            .help("Zoom in (⌘+)")
            Divider().frame(height: 16)
            Button {
                fitRequest += 1
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .help("Fit the whole diagram")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    @ViewBuilder
    private var banners: some View {
        if let error = store.error(for: topic) {
            NoticeBanner(error, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                Button("Try Again") { store.generate(topic) }
                Button("Dismiss") { store.dismissError(for: topic) }
            }
        }
        if let exportMessage {
            NoticeBanner(exportMessage, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                Button("Dismiss") { self.exportMessage = nil }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button {
                    store.generate(topic)
                } label: {
                    Label("Draw \(topic.signal.kind.label)", systemImage: topic.signal.kind.systemImage)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(meeting.segments.isEmpty)
                Text(meeting.segments.isEmpty
                     ? "This meeting has no transcript."
                     : topic.signal.kind == .flow
                        ? "Draws the steps and decisions the meeting walked through, each tied to where it was said."
                        : "Places the deliverables the meeting committed to on a timeline, with relative dates worked out from the meeting date.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = meeting.latestInsight?.summary, !summary.isEmpty {
                AISummarySection(summary: summary)
            }
        }
    }

    private var generating: some View {
        WorkingCard(title: "Drawing from the transcript…", caption: "A long meeting can take a minute or two.")
    }

    // MARK: - Export

    private func copyMermaid(_ diagram: StoredDiagram) {
        Self.copy(diagram.flow.map(DiagramMermaid.flow) ?? diagram.timeline.map(DiagramMermaid.timeline) ?? "")
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ diagram: StoredDiagram, as format: DiagramExporter.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .pdf ? .pdf : .png]
        panel.nameFieldStringValue = ExportFilename.suggested(
            title: diagram.title ?? topic.signal.title,
            date: meeting.date,
            suffix: diagram.kind.rawValue,
            fileExtension: format == .pdf ? "pdf" : "png"
        )
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagramExporter.write(diagram, meeting: meeting, format: format, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// Beside the diagram: an overview until you pick a step or deliverable,
/// then that one — what it is, an editor for it, and where it was said.
private struct DiagramSidebar: View {
    let topic: DiagramTopic
    let diagram: StoredDiagram
    @Binding var selectedID: String?
    let lines: [RefinementPassage.Line]
    let onOpenLine: (UUID) -> Void

    @State private var isEditing = false
    private var store: DiagramStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let id = selectedID, let node = diagram.flow?.nodes.first(where: { $0.id == id }) {
                    selectionHeader
                    if isEditing { nodeEditor(node) } else { nodeSummary(node) }
                    evidence(node.citations)
                } else if let id = selectedID, let item = diagram.timeline?.items.first(where: { $0.id == id }) {
                    selectionHeader
                    if isEditing { itemEditor(item) } else { itemSummary(item) }
                    evidence(item.citations)
                } else {
                    overview
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .onChange(of: selectedID) { isEditing = false }
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        sectionTitle("Overview")
        if let summary = diagram.summary {
            Text(summary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(counts)
            .font(.caption)
            .foregroundStyle(.secondary)
        if !diagram.notes.isEmpty {
            Divider()
            sectionTitle(diagram.kind == .flow ? "Left open" : "Risks and assumptions")
            ForEach(diagram.notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: diagram.kind == .flow ? "questionmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(note)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Divider()
        Text(diagram.kind == .flow
             ? "Click a step to see where it was said or to change it. Mouse wheel, pinch or ⌘± to zoom; drag or two-finger scroll to move around."
             : "Click a deliverable to see where it was said or to change it.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var counts: String {
        if let flow = diagram.flow {
            let decisions = flow.nodes.filter { $0.kind == .decision }.count
            let steps = flow.nodes.count - decisions
            return "\(steps) step\(steps == 1 ? "" : "s") · \(decisions) decision\(decisions == 1 ? "" : "s")"
        }
        let timeline = diagram.timeline
        let dated = timeline?.dated.count ?? 0
        let undated = timeline?.undated.count ?? 0
        return "\(dated) dated · \(undated) without a date"
    }

    // MARK: Selection

    private var selectionHeader: some View {
        HStack {
            Button {
                selectedID = nil
            } label: {
                Label("Overview", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                .controlSize(.small)
        }
    }

    private func nodeSummary(_ node: FlowDiagram.Node) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kindLabel(node.kind).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(node.label)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let actor = node.actor?.nonEmpty {
                Label(actor, systemImage: "person")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = node.note?.nonEmpty {
                Text(note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func itemSummary(_ item: TimelineDiagram.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let owner = item.owner?.nonEmpty {
                Label(owner, systemImage: "person")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Label(dateLine(item), systemImage: "calendar")
                .font(.callout)
            if let said = item.dateText?.nonEmpty {
                Text("Said as “\(said)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let after = (item.dependsOn ?? []).compactMap { id in diagram.timeline?.items.first { $0.id == id }?.name }
            if !after.isEmpty {
                Text("After: \(after.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dateLine(_ item: TimelineDiagram.Item) -> String {
        let format = { (date: Date) in date.formatted(date: .abbreviated, time: .omitted) }
        let estimate = item.isEstimated ? " (estimated)" : ""
        switch (item.startDate, item.dueDate) {
        case let (start?, due?): return "\(format(start)) – \(format(due))\(estimate)"
        case let (nil, due?): return "Due \(format(due))\(estimate)"
        case let (start?, nil): return "Starts \(format(start))\(estimate)"
        case (nil, nil): return "No date given"
        }
    }

    private func kindLabel(_ kind: FlowDiagram.NodeKind) -> String {
        switch kind {
        case .start: "Start"
        case .step: "Step"
        case .decision: "Decision"
        case .end: "End"
        }
    }

    // MARK: Editors

    private func nodeEditor(_ node: FlowDiagram.Node) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    fieldLabel("Label")
                    TextField("What happens", text: nodeBinding(node, \.label), axis: .vertical)
                }
                GridRow {
                    fieldLabel("Kind")
                    Picker("", selection: nodeBinding(node, \.kind)) {
                        ForEach(FlowDiagram.NodeKind.allCases, id: \.self) { Text(kindLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    fieldLabel("Who")
                    TextField("Person, team or system", text: nodeBinding(node, \.actor).orEmpty)
                }
                GridRow {
                    fieldLabel("Note")
                    TextField("Detail worth keeping", text: nodeBinding(node, \.note).orEmpty, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .textFieldStyle(.roundedBorder)
            Button("Delete Step", role: .destructive) {
                store.edit(topic) { stored in
                    stored.flow?.nodes.removeAll { $0.id == node.id }
                    stored.flow?.edges.removeAll { $0.from == node.id || $0.to == node.id }
                }
                selectedID = nil
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .font(.caption)
        }
    }

    private func itemEditor(_ item: TimelineDiagram.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    fieldLabel("Name")
                    TextField("Deliverable", text: itemBinding(item, \.name), axis: .vertical)
                }
                GridRow {
                    fieldLabel("Owner")
                    TextField("Person or team", text: itemBinding(item, \.owner).orEmpty)
                }
                GridRow {
                    fieldLabel("Start")
                    dateField(item, \.start)
                }
                GridRow {
                    fieldLabel("Due")
                    dateField(item, \.due)
                }
                GridRow {
                    fieldLabel("")
                    Toggle("Milestone", isOn: Binding(
                        get: { item.isMilestone == true },
                        set: { value in editItem(item.id) { $0.isMilestone = value } }
                    ))
                }
            }
            .textFieldStyle(.roundedBorder)
            Button("Delete", role: .destructive) {
                store.edit(topic) { $0.timeline?.items.removeAll { $0.id == item.id } }
                selectedID = nil
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .font(.caption)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    /// A date you can turn on and off; a date you set is exact.
    private func dateField(_ item: TimelineDiagram.Item, _ keyPath: WritableKeyPath<TimelineDiagram.Item, String?>) -> some View {
        let id = item.id
        let current = item[keyPath: keyPath].flatMap(TimelineDiagram.date(from:))
        return HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { current != nil },
                set: { on in
                    editItem(id) { item in
                        item[keyPath: keyPath] = on ? TimelineDiagram.string(from: current ?? .now) : nil
                        if on { item.confidence = "exact" }
                    }
                }
            ))
            .labelsHidden()
            if let current {
                DatePicker("", selection: Binding(
                    get: { current },
                    set: { date in
                        editItem(id) { item in
                            item[keyPath: keyPath] = TimelineDiagram.string(from: date)
                            item.confidence = "exact"
                        }
                    }
                ), displayedComponents: .date)
                .labelsHidden()
            } else {
                Text("None").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func editNode(_ id: String, _ change: @escaping (inout FlowDiagram.Node) -> Void) {
        store.edit(topic) { stored in
            guard let index = stored.flow?.nodes.firstIndex(where: { $0.id == id }) else { return }
            change(&stored.flow!.nodes[index])
        }
    }

    private func editItem(_ id: String, _ change: @escaping (inout TimelineDiagram.Item) -> Void) {
        store.edit(topic) { stored in
            guard let index = stored.timeline?.items.firstIndex(where: { $0.id == id }) else { return }
            change(&stored.timeline!.items[index])
        }
    }

    private func nodeBinding<Value>(_ node: FlowDiagram.Node, _ keyPath: WritableKeyPath<FlowDiagram.Node, Value>) -> Binding<Value> {
        Binding(get: { node[keyPath: keyPath] }, set: { value in editNode(node.id) { $0[keyPath: keyPath] = value } })
    }

    private func itemBinding<Value>(_ item: TimelineDiagram.Item, _ keyPath: WritableKeyPath<TimelineDiagram.Item, Value>) -> Binding<Value> {
        Binding(get: { item[keyPath: keyPath] }, set: { value in editItem(item.id) { $0[keyPath: keyPath] = value } })
    }

    // MARK: Evidence

    @ViewBuilder
    private func evidence(_ citations: [String]?) -> some View {
        let moments = (citations ?? []).flatMap(RefinementCitation.parse(in:))
        Divider()
        sectionTitle("Where it was said")
        if moments.isEmpty {
            Text("No transcript moment cited.").font(.caption).foregroundStyle(.tertiary)
        }
        ForEach(Array(moments.enumerated()), id: \.offset) { _, moment in
            let passage = RefinementPassage.lines(for: moment, in: lines)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(moment.label).font(.caption.monospacedDigit().weight(.semibold))
                    Spacer()
                    if let first = passage.first {
                        Button {
                            onOpenLine(first.id)
                        } label: {
                            Label("Open in meeting", systemImage: "arrow.up.forward.app")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Open the meeting at this moment")
                    }
                }
                ForEach(Array(TranscriptExcerpt.merge(passage).enumerated()), id: \.offset) { _, excerpt in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(excerpt.speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(excerpt.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A speaker's consecutive transcript lines as one passage. Transcripts
/// arrive as short fragments; read one per line, a sentence is in pieces.
struct TranscriptExcerpt: Equatable {
    let speaker: String
    let text: String

    static func merge(_ lines: [RefinementPassage.Line]) -> [TranscriptExcerpt] {
        var result: [TranscriptExcerpt] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = result.last, last.speaker == line.speaker {
                result[result.count - 1] = TranscriptExcerpt(speaker: last.speaker, text: last.text + " " + text)
            } else {
                result.append(TranscriptExcerpt(speaker: line.speaker, text: text))
            }
        }
        return result
    }
}

private extension Binding where Value == String? {
    /// An optional text field: empty text is no value.
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.nonEmpty })
    }
}
