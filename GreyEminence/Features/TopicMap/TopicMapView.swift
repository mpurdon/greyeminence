import SwiftUI
import SwiftData

enum TopicMapSort: String, CaseIterable {
    case mentions
    case recent

    var label: String {
        switch self {
        case .mentions: "Mentions"
        case .recent: "Recent"
        }
    }
}

struct TopicMapView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var insights: [MeetingInsight]
    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]
    @Bindable var viewModel: TopicMapViewModel
    @State private var canvasSize: CGSize = .zero
    @State private var isReanalyzing = false
    @State private var reanalyzeProgress: (current: Int, total: Int)?
    @AppStorage("topicMapSort") private var sortOrder: TopicMapSort = .mentions
    var onMeetingSelected: ((Meeting) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Group {
                if insights.isEmpty {
                    ContentUnavailableView(
                        "No Meetings",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Record and analyze meetings to build your topic map")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.nodes.isEmpty {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "No Topics Yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Topics will appear after meetings are analyzed by AI")
                        )
                        if meetingsNeedingAnalysis > 0 {
                            if isReanalyzing, let progress = reanalyzeProgress {
                                VStack(spacing: 6) {
                                    ProgressView(value: Double(progress.current), total: Double(progress.total))
                                        .frame(width: 200)
                                    Text("Analyzing \(progress.current)/\(progress.total) meetings...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Button {
                                    Task { await batchReanalyze() }
                                } label: {
                                    Label("Analyze \(meetingsNeedingAnalysis) Meeting\(meetingsNeedingAnalysis == 1 ? "" : "s")", systemImage: "brain")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isReanalyzing)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    graphContent
                }
            }
            .onAppear {
                canvasSize = size
                rebuildIfNeeded()
                applyPendingFocus()
            }
            .onChange(of: size) { _, newSize in
                canvasSize = newSize
            }
            .onChange(of: insights.count) {
                rebuildIfNeeded()
            }
            .onChange(of: viewModel.isSimulating) { _, simulating in
                if !simulating { applyPendingFocus() }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search topics")
    }

    @ViewBuilder
    private var graphContent: some View {
        HStack(spacing: 0) {
            topicSidebar
                .frame(width: 220)
            Divider()
            ZStack(alignment: .topTrailing) {
                graphCanvas
                controlButtons
            }

            if viewModel.selectedNode != nil {
                Divider()
                TopicDetailPanel(
                    viewModel: viewModel,
                    onMeetingSelected: onMeetingSelected
                )
                .frame(width: 280)
            }
        }
    }

    private var rankedNodes: [TopicNode] {
        switch sortOrder {
        case .mentions:
            return viewModel.nodes.sorted { $0.meetingCount > $1.meetingCount }
        case .recent:
            return viewModel.nodes.sorted {
                ($0.lastMeetingDate ?? .distantPast) > ($1.lastMeetingDate ?? .distantPast)
            }
        }
    }

    private var maxMeetingCount: Int {
        viewModel.nodes.map(\.meetingCount).max() ?? 1
    }

    private var topicSidebar: some View {
        VStack(spacing: 0) {
            Picker("Sort", selection: $sortOrder) {
                ForEach(TopicMapSort.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rankedNodes) { node in
                        topicRow(node)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func topicRow(_ node: TopicNode) -> some View {
        let isSelected = node.id == viewModel.selectedTopicID
        let isHovered = node.id == viewModel.hoveredTopicID

        Button {
            viewModel.selectedTopicID = (viewModel.selectedTopicID == node.id) ? nil : node.id
        } label: {
            HStack(spacing: 6) {
                Text("\(node.meetingCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)

                GeometryReader { geo in
                    let fraction = CGFloat(node.meetingCount) / CGFloat(max(maxMeetingCount, 1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(isSelected || isHovered ? 1.0 : 0.55))
                        .frame(width: max(fraction * geo.size.width, 4))
                }
                .frame(height: 10)

                Text(node.label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) :
                isHovered ? Color.secondary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            viewModel.hoveredTopicID = hovering ? node.id : nil
        }
    }

    private var graphCanvas: some View {
        Canvas { context, size in
            // Apply zoom/pan
            context.translateBy(x: viewModel.offset.x, y: viewModel.offset.y)
            context.scaleBy(x: viewModel.scale, y: viewModel.scale)

            // Draw edges
            for edge in viewModel.edges {
                guard edge.sourceIndex < viewModel.nodes.count,
                      edge.targetIndex < viewModel.nodes.count else { continue }
                let from = viewModel.nodes[edge.sourceIndex].position
                let to = viewModel.nodes[edge.targetIndex].position
                let opacity = viewModel.edgeOpacity(for: edge)
                guard opacity > 0.01 else { continue }

                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(
                    path,
                    with: .color(.primary.opacity(opacity)),
                    lineWidth: viewModel.edgeWidth(for: edge)
                )
            }

            // Draw nodes
            for node in viewModel.nodes {
                let opacity = viewModel.nodeOpacity(for: node)
                guard opacity > 0.01 else { continue }

                let rect = CGRect(
                    x: node.position.x - node.radius,
                    y: node.position.y - node.radius,
                    width: node.radius * 2,
                    height: node.radius * 2
                )

                let isSelected = node.id == viewModel.selectedTopicID
                let isHovered = node.id == viewModel.hoveredTopicID
                let isConnected = viewModel.isConnectedToSelected(node.id)
                    || viewModel.isConnectedToHovered(node.id)

                // Glow ring for selected
                if isSelected {
                    let ringRect = rect.insetBy(dx: -4, dy: -4)
                    context.fill(
                        Circle().path(in: ringRect),
                        with: .color(.accentColor.opacity(0.25))
                    )
                }

                // Node fill — monochrome with emphasis on focus cluster
                let fillColor: Color
                if isSelected {
                    fillColor = .accentColor
                } else if isHovered {
                    fillColor = .primary
                } else if isConnected {
                    fillColor = .primary.opacity(0.7)
                } else {
                    fillColor = .secondary
                }

                context.fill(
                    Circle().path(in: rect),
                    with: .color(fillColor.opacity(opacity))
                )

                // Label — only show for hovered, selected, connected nodes, or large nodes when zoomed
                let showLabel = isSelected || isHovered || isConnected
                    || (viewModel.scale > 1.5 && node.meetingCount >= 3)
                if showLabel {
                    let weight: Font.Weight = (isSelected || isHovered) ? .semibold : .regular
                    let labelOpacity = (isSelected || isHovered) ? 1.0 : 0.7
                    let labelText = Text(node.label)
                        .font(.system(size: max(9, 10 / viewModel.scale), weight: weight))
                        .foregroundColor(.primary.opacity(labelOpacity * opacity))
                    let labelPoint = CGPoint(
                        x: node.position.x,
                        y: node.position.y + node.radius + 4
                    )
                    context.draw(labelText, at: labelPoint, anchor: .top)
                }
            }
        }
        .background(Color.clear)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    viewModel.updateZoom(value.magnification, anchor: value.startAnchor.applying(canvasSize))
                }
                .onEnded { _ in
                    viewModel.endZoom()
                }
        )
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    viewModel.updatePan(translation: value.translation)
                }
                .onEnded { _ in
                    viewModel.endPan()
                }
        )
        .onTapGesture { location in
            viewModel.handleTap(at: location)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                viewModel.hoveredTopicID = viewModel.topicAt(point: point)
            case .ended:
                viewModel.hoveredTopicID = nil
            }
        }
    }

    private var controlButtons: some View {
        VStack(spacing: 6) {
            Button {
                rebuildIfNeeded()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .help("Refresh topics from meetings")

            Button {
                viewModel.resetView(canvasSize: canvasSize)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.bordered)
            .help("Reset zoom & pan")

            if viewModel.isSimulating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            }

            Divider()
                .frame(width: 20)

            // Density controls
            VStack(spacing: 2) {
                Text("Nodes")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Stepper("\(viewModel.maxNodeCount)", value: $viewModel.maxNodeCount, in: 10...200, step: 10)
                    .font(.system(size: 9))
                    .labelsHidden()
                Text("\(viewModel.maxNodeCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: viewModel.maxNodeCount) {
                rebuildIfNeeded()
            }

            VStack(spacing: 2) {
                Text("Links")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Stepper("\(viewModel.minEdgeWeight)", value: $viewModel.minEdgeWeight, in: 1...10)
                    .font(.system(size: 9))
                    .labelsHidden()
                Text("\u{2265}\(viewModel.minEdgeWeight)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: viewModel.minEdgeWeight) {
                rebuildIfNeeded()
            }

            Text("\(viewModel.nodes.count) / \(viewModel.edges.count)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func rebuildIfNeeded() {
        guard canvasSize.width > 0 && canvasSize.height > 0 else { return }
        let topicInsights = insights.filter { !$0.topics.isEmpty }
        guard !topicInsights.isEmpty else { return }
        viewModel.buildGraph(from: topicInsights, canvasSize: canvasSize)
    }

    private func applyPendingFocus() {
        guard let topic = viewModel.pendingFocusTopic,
              !viewModel.nodes.isEmpty,
              canvasSize.width > 0 else { return }
        viewModel.pendingFocusTopic = nil
        // Small delay so the canvas has rendered at least once
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            viewModel.focusOnTopic(topic, canvasSize: canvasSize)
        }
    }

    /// Meetings that have transcript segments but no insight with topics.
    private var meetingsNeedingAnalysis: Int {
        let meetingsWithTopics = Set(
            insights.filter { !$0.topics.isEmpty }.compactMap { $0.meeting?.id }
        )
        return allMeetings.filter { !$0.segments.isEmpty && !meetingsWithTopics.contains($0.id) }.count
    }

    @MainActor
    private func batchReanalyze() async {
        guard !isReanalyzing else { return }
        isReanalyzing = true
        defer {
            isReanalyzing = false
            reanalyzeProgress = nil
            rebuildIfNeeded()
        }

        guard let client = try? await AIClientFactory.makeClient() else { return }

        let meetingsWithTopics = Set(
            insights.filter { !$0.topics.isEmpty }.compactMap { $0.meeting?.id }
        )
        let toAnalyze = allMeetings.filter { !$0.segments.isEmpty && !meetingsWithTopics.contains($0.id) }

        reanalyzeProgress = (0, toAnalyze.count)

        for (i, meeting) in toAnalyze.enumerated() {
            reanalyzeProgress = (i + 1, toAnalyze.count)

            let service = AIIntelligenceService(client: client, meetingID: meeting.id)
            let snapshots: [SegmentSnapshot] = meeting.segments
                .sorted { $0.startTime < $1.startTime }
                .map { SegmentSnapshot(speaker: $0.speaker, text: $0.text, formattedTimestamp: $0.formattedTimestamp, isFinal: $0.isFinal) }

            guard !snapshots.isEmpty else { continue }

            do {
                // Seed with first pass, then final
                _ = try await service.analyze(segments: snapshots)
                guard let result = try await service.performFinalAnalysis(segments: snapshots) else {
                    continue
                }

                if let title = result.title, !title.isEmpty {
                    meeting.title = title
                }

                let insight = MeetingInsight(
                    summary: result.summary,
                    followUpQuestions: result.followUps,
                    topics: result.topics,
                    rawLLMResponse: result.rawResponse,
                    modelIdentifier: client.modelIdentifier,
                    promptVersion: AIPromptTemplates.promptVersion
                )
                insight.meeting = meeting
                modelContext.insert(insight)

                for item in result.actionItems {
                    let action = ActionItem(text: item.text, assignee: item.assignee)
                    action.meeting = meeting
                    modelContext.insert(action)
                }

                PersistenceGate.save(
                    modelContext,
                    site: "TopicMapView.batchReanalyze",
                    meetingID: meeting.id
                )
            } catch {
                continue
            }
        }
    }
}

// Helper to convert UnitPoint to CGPoint given a size
private extension UnitPoint {
    func applying(_ size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}
