import SwiftUI
import SwiftData

struct TopicMapView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var insights: [MeetingInsight]
    @Query(sort: \Meeting.date, order: .reverse) private var allMeetings: [Meeting]
    @State private var viewModel = TopicMapViewModel()
    @State private var canvasSize: CGSize = .zero
    @State private var isReanalyzing = false
    @State private var reanalyzeProgress: (current: Int, total: Int)?
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
            }
            .onChange(of: size) { _, newSize in
                canvasSize = newSize
            }
            .onChange(of: insights.count) {
                rebuildIfNeeded()
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search topics")
    }

    @ViewBuilder
    private var graphContent: some View {
        HStack(spacing: 0) {
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
                    with: .color(.secondary.opacity(opacity)),
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

                // Highlight ring for selected/hovered
                let isSelected = node.id == viewModel.selectedTopicID
                let isHovered = node.id == viewModel.hoveredTopicID
                let isConnected = viewModel.isConnectedToSelected(node.id)
                    || viewModel.isConnectedToHovered(node.id)

                if isSelected || isHovered {
                    let ringRect = rect.insetBy(dx: -3, dy: -3)
                    context.fill(
                        Circle().path(in: ringRect),
                        with: .color(.accentColor.opacity(0.3))
                    )
                }

                // Node fill
                let fillOpacity = isConnected ? max(opacity, 0.6) : opacity
                context.fill(
                    Circle().path(in: rect),
                    with: .color(node.color.opacity(fillOpacity))
                )

                // Label
                let showLabel = viewModel.scale > 0.6 || isSelected || isHovered
                if showLabel {
                    let labelText = Text(node.label)
                        .font(.system(size: max(9, 11 / viewModel.scale)))
                        .foregroundColor(.primary.opacity(opacity))
                    let labelPoint = CGPoint(
                        x: node.position.x,
                        y: node.position.y + node.radius + 8
                    )
                    context.draw(labelText, at: labelPoint, anchor: .top)
                }

                // Meeting count badge
                if isSelected || isHovered {
                    let badge = Text("\(node.meetingCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                    context.draw(badge, at: node.position, anchor: .center)
                }
            }
        }
        .background(Color.clear)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    viewModel.updateZoom(value.magnification, anchor: value.startAnchor.applying(canvasSize))
                }
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.startLocation == value.location {
                        viewModel.beginPan()
                    }
                    viewModel.updatePan(translation: value.translation)
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

            Text("\(viewModel.nodes.count) topics")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func rebuildIfNeeded() {
        guard canvasSize.width > 0 && canvasSize.height > 0 else { return }
        let topicInsights = insights.filter { !$0.topics.isEmpty }
        guard !topicInsights.isEmpty else { return }
        viewModel.buildGraph(from: topicInsights, canvasSize: canvasSize)
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
                let firstPass = try await service.analyze(segments: snapshots)
                let result: AnalysisResult
                if let r = firstPass {
                    result = r
                } else if let r = try await service.performFinalAnalysis(segments: snapshots) {
                    result = r
                } else {
                    continue
                }

                if let title = result.title, !title.isEmpty {
                    meeting.title = title
                }

                let insight = MeetingInsight(
                    summary: result.summary,
                    followUpQuestions: result.followUps,
                    topics: result.topics
                )
                insight.meeting = meeting
                modelContext.insert(insight)

                for item in result.actionItems {
                    let action = ActionItem(text: item.text, assignee: item.assignee)
                    action.meeting = meeting
                    modelContext.insert(action)
                }

                try? modelContext.save()
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
