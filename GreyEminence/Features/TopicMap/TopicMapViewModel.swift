import SwiftUI
import SwiftData

@Observable
@MainActor
final class TopicMapViewModel {
    var nodes: [TopicNode] = []
    var edges: [TopicEdge] = []
    var selectedTopicID: String?
    var hoveredTopicID: String?
    var searchText: String = ""

    // Zoom/pan
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero
    private var dragStartOffset: CGPoint = .zero
    private var isPanning: Bool = false
    private var zoomStartScale: CGFloat?

    // Simulation
    private(set) var isSimulating = false
    private var simulationTask: Task<Void, Never>?

    // Focus (radial ego view of the selected topic)
    private(set) var focusActive = false
    private var globalPositions: [String: CGPoint] = [:]
    private var focusTask: Task<Void, Never>?
    /// Latest canvas size, kept so selection (which can come from the sidebar or
    /// detail panel) can lay out the ego graph without the caller passing it.
    var lastCanvasSize: CGSize = .zero
    /// Max neighbours drawn in the ego ring; the rest are listed in the panel.
    let neighbourCap = 14

    // Aggregated data
    private(set) var topicMeetings: [String: [Meeting]] = [:]
    private var coOccurrence: [TopicPair: Int] = [:]
    var maxNodeCount = 40
    var minEdgeWeight = 2

    // MARK: - Graph Building

    /// `resolver` merges aliases into their canonical topic and drops topics
    /// whose kind is filtered out — before the top `maxNodeCount` are
    /// chosen, so hiding People makes room for other topics.
    func buildGraph(from insights: [MeetingInsight], canvasSize: CGSize, resolver: TopicResolver = TopicResolver()) {
        // Group insights by meeting, take latest per meeting
        var latestByMeeting: [UUID: MeetingInsight] = [:]
        for insight in insights {
            guard let meeting = insight.meeting else { continue }
            if let existing = latestByMeeting[meeting.id] {
                if insight.createdAt > existing.createdAt {
                    latestByMeeting[meeting.id] = insight
                }
            } else {
                latestByMeeting[meeting.id] = insight
            }
        }

        // Aggregate topic frequency and co-occurrence
        var frequency: [String: Int] = [:]
        var labelForms: [String: [String: Int]] = [:]  // normalized → [original: count]
        var meetingsByTopic: [String: Set<UUID>] = [:]
        var meetingObjectsByTopic: [String: [Meeting]] = [:]
        var kinds: [String: TopicKind] = [:]
        var aliasForms: [String: Set<String>] = [:]
        coOccurrence = [:]

        for (meetingID, insight) in latestByMeeting {
            let meeting = insight.meeting!
            // Each topic under the key it counts as, with the name to show.
            var labels: [String: String] = [:]
            for raw in insight.topics {
                guard let resolved = resolver.resolve(raw) else { continue }
                let written = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalize(raw) != resolved.key { aliasForms[resolved.key, default: []].insert(written) }
                if let kind = resolved.kind, kinds[resolved.key] == nil { kinds[resolved.key] = kind }
                if labels[resolved.key] == nil { labels[resolved.key] = resolved.displayName ?? written }
            }
            let unique = Array(labels.keys)

            for (i, norm) in unique.enumerated() {
                let original = labels[norm] ?? norm
                frequency[norm, default: 0] += 1
                labelForms[norm, default: [:]][original, default: 0] += 1
                meetingsByTopic[norm, default: []].insert(meetingID)
                if meetingObjectsByTopic[norm] == nil { meetingObjectsByTopic[norm] = [] }
                if !meetingObjectsByTopic[norm]!.contains(where: { $0.id == meeting.id }) {
                    meetingObjectsByTopic[norm]!.append(meeting)
                }

                for j in (i + 1)..<unique.count {
                    let pair = TopicPair(unique[i], unique[j])
                    coOccurrence[pair, default: 0] += 1
                }
            }
        }

        // Sort by frequency, take top N
        let sorted = frequency.sorted { $0.value > $1.value }.prefix(maxNodeCount)
        let topTopics = Set(sorted.map(\.key))

        topicMeetings = [:]
        for (norm, meetings) in meetingObjectsByTopic where topTopics.contains(norm) {
            let bestLabel = labelForms[norm]?.max(by: { $0.value < $1.value })?.key ?? norm
            topicMeetings[bestLabel] = meetings.sorted { $0.date > $1.date }
        }

        // Build nodes
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let circleRadius = min(canvasSize.width, canvasSize.height) * 0.4

        var newNodes: [TopicNode] = []
        var indexMap: [String: Int] = [:]

        for (i, (norm, count)) in sorted.enumerated() {
            let angle = CGFloat(i) / CGFloat(sorted.count) * 2 * .pi
            let pos = CGPoint(
                x: center.x + cos(angle) * circleRadius,
                y: center.y + sin(angle) * circleRadius
            )
            let bestLabel = labelForms[norm]?.max(by: { $0.value < $1.value })?.key ?? norm

            let node = TopicNode(
                id: norm,
                label: bestLabel,
                meetingCount: count,
                meetingIDs: meetingsByTopic[norm] ?? [],
                lastMeetingDate: meetingObjectsByTopic[norm]?.map(\.date).max(),
                position: pos,
                radius: TopicNode.radius(for: count),
                color: TopicNode.color(for: norm),
                kind: kinds[norm],
                aliases: (aliasForms[norm] ?? []).sorted()
            )
            indexMap[norm] = newNodes.count
            newNodes.append(node)
        }

        // Build edges (only co-occurrences at or above threshold)
        var newEdges: [TopicEdge] = []
        for (pair, weight) in coOccurrence {
            guard weight >= minEdgeWeight else { continue }
            guard let si = indexMap[pair.a], let ti = indexMap[pair.b] else { continue }
            newEdges.append(TopicEdge(sourceIndex: si, targetIndex: ti, weight: weight))
        }
        Self.markBackbone(&newEdges, nodeCount: newNodes.count, topK: 3)

        nodes = newNodes
        edges = newEdges
        lastCanvasSize = canvasSize

        // Reset view + focus state
        scale = 1.0
        offset = .zero
        selectedTopicID = nil
        focusActive = false
        focusTask?.cancel()
        globalPositions = [:]

        startSimulation(center: center)
    }

    /// Mark each node's top-`topK` strongest incident edges as backbone. The
    /// union is the readable skeleton shown when nothing is selected.
    static func markBackbone(_ edges: inout [TopicEdge], nodeCount: Int, topK: Int) {
        guard nodeCount > 0 else { return }
        var incident: [[Int]] = Array(repeating: [], count: nodeCount)
        for (ei, edge) in edges.enumerated() {
            incident[edge.sourceIndex].append(ei)
            incident[edge.targetIndex].append(ei)
        }
        var keep = Set<Int>()
        for edgeIdxs in incident {
            keep.formUnion(edgeIdxs.sorted { edges[$0].weight > edges[$1].weight }.prefix(topK))
        }
        for ei in keep { edges[ei].isBackbone = true }
    }

    // MARK: - Simulation

    private func startSimulation(center: CGPoint) {
        simulationTask?.cancel()
        isSimulating = true

        simulationTask = Task { [weak self] in
            var alpha: CGFloat = 1.0
            let decay: CGFloat = 0.96
            let minAlpha: CGFloat = 0.01
            let maxFrames = 200

            for _ in 0..<maxFrames {
                guard !Task.isCancelled else { return }
                guard let self, self.isSimulating else { return }

                ForceSimulation.step(nodes: &self.nodes, edges: self.edges, center: center, alpha: alpha)
                alpha *= decay
                if alpha < minAlpha { break }

                try? await Task.sleep(for: .milliseconds(16))
            }

            await MainActor.run { [weak self] in
                // Zero out all velocities so nodes are fully static
                if let self {
                    for i in 0..<self.nodes.count {
                        self.nodes[i].velocity = .zero
                    }
                    self.isSimulating = false
                }
            }
        }
    }

    func stopSimulation() {
        simulationTask?.cancel()
        isSimulating = false
    }

    // MARK: - Normalize

    private func normalize(_ topic: String) -> String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Hit Testing

    func topicAt(point: CGPoint) -> String? {
        // Convert screen point to graph coordinates
        let graphPoint = screenToGraph(point)
        for node in nodes.reversed() {
            // In the ego view, hidden topics sit at stale positions — ignore them.
            if focusActive && !focusVisibleIDs.contains(node.id) { continue }
            let dx = graphPoint.x - node.position.x
            let dy = graphPoint.y - node.position.y
            if hypot(dx, dy) <= node.radius + 4 {
                return node.id
            }
        }
        return nil
    }

    // MARK: - Coordinate Transform

    func screenToGraph(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - offset.x) / scale,
            y: (point.y - offset.y) / scale
        )
    }

    func graphToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x * scale + offset.x,
            y: point.y * scale + offset.y
        )
    }

    // MARK: - Gestures

    func handleTap(at point: CGPoint) {
        if let id = topicAt(point: point) {
            setSelectedTopic((selectedTopicID == id) ? nil : id)
        } else {
            setSelectedTopic(nil)
        }
    }

    /// The single entry point for changing selection. Drives the radial ego view
    /// (enter on select, exit on deselect) so every caller — canvas tap, sidebar,
    /// detail panel — behaves consistently.
    func setSelectedTopic(_ id: String?) {
        guard id != selectedTopicID else { return }
        selectedTopicID = id
        if id != nil {
            enterFocus()
        } else {
            exitFocus()
        }
    }

    func updatePan(translation: CGSize) {
        if !isPanning {
            isPanning = true
            dragStartOffset = offset
        }
        offset = CGPoint(
            x: dragStartOffset.x + translation.width,
            y: dragStartOffset.y + translation.height
        )
    }

    func endPan() {
        isPanning = false
    }

    /// `magnification` is the cumulative scale ratio since the gesture started
    /// (matches `MagnifyGesture.Value.magnification`), so we apply it against
    /// the scale captured at gesture start rather than multiplying into the
    /// current scale each tick (which compounds exponentially).
    func updateZoom(_ magnification: CGFloat, anchor: CGPoint) {
        if zoomStartScale == nil { zoomStartScale = scale }
        let startScale = zoomStartScale ?? scale
        let newScale = max(0.3, min(3.0, startScale * magnification))
        let factor = newScale / scale
        offset.x = anchor.x - (anchor.x - offset.x) * factor
        offset.y = anchor.y - (anchor.y - offset.y) * factor
        scale = newScale
    }

    func endZoom() {
        zoomStartScale = nil
    }

    func resetView(canvasSize: CGSize) {
        withAnimation(.easeInOut(duration: 0.3)) {
            scale = 1.0
            offset = .zero
        }
    }

    /// Select a topic by its label/ID; the ego view centers it (used by external
    /// navigation and the "connected topics" list).
    func focusOnTopic(_ topicLabel: String, canvasSize: CGSize) {
        let normalized = topicLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard nodes.contains(where: { $0.id == normalized }) else { return }
        lastCanvasSize = canvasSize
        setSelectedTopic(normalized)
    }

    // MARK: - Radial ego view

    private func enterFocus() {
        guard let selID = selectedTopicID else { return }
        // Snapshot the global force layout the first time we leave the overview,
        // so deselecting restores it exactly.
        if !focusActive {
            globalPositions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        }
        focusActive = true
        stopSimulation()

        let size = lastCanvasSize
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let ring = min(size.width, size.height) * 0.32
        withAnimation(.easeInOut(duration: 0.4)) {
            scale = 1.0
            offset = .zero
        }

        var targets: [String: CGPoint] = [selID: center]
        let neighbours = cappedNeighbours
        let n = max(neighbours.count, 1)
        for (i, nb) in neighbours.enumerated() {
            let angle = -CGFloat.pi / 2 + CGFloat(i) / CGFloat(n) * 2 * .pi
            targets[nb.id] = CGPoint(x: center.x + cos(angle) * ring, y: center.y + sin(angle) * ring)
        }
        animatePositions(to: targets)
    }

    private func exitFocus() {
        guard focusActive else { return }
        focusActive = false
        guard !globalPositions.isEmpty else { return }
        animatePositions(to: globalPositions)
    }

    /// Tween `node.position` for the given ids from current → target over ~0.4s.
    private func animatePositions(to targets: [String: CGPoint]) {
        focusTask?.cancel()
        let starts = Dictionary(uniqueKeysWithValues: nodes.compactMap { node in
            targets[node.id].map { _ in (node.id, node.position) }
        })
        focusTask = Task { [weak self] in
            let frames = 25
            for f in 0...frames {
                guard !Task.isCancelled, let self else { return }
                let t = Self.easeOut(CGFloat(f) / CGFloat(frames))
                for i in self.nodes.indices {
                    let id = self.nodes[i].id
                    guard let start = starts[id], let target = targets[id] else { continue }
                    self.nodes[i].position = CGPoint(
                        x: start.x + (target.x - start.x) * t,
                        y: start.y + (target.y - start.y) * t
                    )
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private static func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - max(0, min(1, t)), 3) }

    /// A topic label queued from external navigation. The view clears this after focusing.
    var pendingFocusTopic: String?

    // MARK: - Visual State

    var searchMatches: Set<String> {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return Set(nodes.filter { $0.label.lowercased().contains(query) }.map(\.id))
    }

    var isSearchActive: Bool { !searchText.isEmpty }

    private var selectedIndex: Int? {
        guard let id = selectedTopicID else { return nil }
        return nodes.firstIndex { $0.id == id }
    }

    func nodeOpacity(for node: TopicNode) -> Double {
        if isSearchActive {
            return searchMatches.contains(node.id) ? 1.0 : 0.08
        }
        if focusActive {
            // Ego view: only the selected node and its ring are visible.
            return focusVisibleIDs.contains(node.id) ? 1.0 : 0.0
        }
        if let hov = hoveredTopicID {
            return (node.id == hov || isConnectedToHovered(node.id)) ? 1.0 : 0.3
        }
        return 0.6
    }

    func edgeOpacity(for edge: TopicEdge) -> Double {
        if isSearchActive {
            let s = searchMatches.contains(nodes[edge.sourceIndex].id)
            let t = searchMatches.contains(nodes[edge.targetIndex].id)
            return (s && t) ? 0.4 : 0.0
        }
        if focusActive {
            // Only the selected topic's spokes — not neighbour↔neighbour edges.
            return isSpokeOfSelected(edge) ? 0.9 : 0.0
        }
        // Overview: the readable backbone, with the hovered node's links brighter.
        if let hov = hoveredTopicID, let hovIdx = nodes.firstIndex(where: { $0.id == hov }) {
            if edge.sourceIndex == hovIdx || edge.targetIndex == hovIdx { return 0.55 }
            return edge.isBackbone ? 0.10 : 0.0
        }
        return edge.isBackbone ? 0.14 : 0.0
    }

    func edgeWidth(for edge: TopicEdge) -> CGFloat {
        let base = CGFloat(min(edge.weight, 8)) * 0.35 + 0.6
        return focusActive ? base * 1.7 : base
    }

    /// Edge connecting the selected node to one of its visible ring neighbours.
    private func isSpokeOfSelected(_ edge: TopicEdge) -> Bool {
        guard let selIdx = selectedIndex else { return false }
        let other: Int
        if edge.sourceIndex == selIdx { other = edge.targetIndex }
        else if edge.targetIndex == selIdx { other = edge.sourceIndex }
        else { return false }
        return focusVisibleIDs.contains(nodes[other].id)
    }

    var selectedNode: TopicNode? {
        guard let id = selectedTopicID else { return nil }
        return nodes.first { $0.id == id }
    }

    var selectedMeetings: [Meeting] {
        guard let node = selectedNode else { return [] }
        return topicMeetings[node.label] ?? []
    }

    struct Neighbour: Identifiable, Hashable {
        let id: String
        let label: String
        let weight: Int
    }

    /// Direct neighbours of the selected topic, ranked by shared-meeting count.
    var selectedNeighbours: [Neighbour] {
        guard let idx = selectedIndex else { return [] }
        var related: [Neighbour] = []
        for edge in edges {
            if edge.sourceIndex == idx {
                let n = nodes[edge.targetIndex]
                related.append(Neighbour(id: n.id, label: n.label, weight: edge.weight))
            } else if edge.targetIndex == idx {
                let n = nodes[edge.sourceIndex]
                related.append(Neighbour(id: n.id, label: n.label, weight: edge.weight))
            }
        }
        return related.sorted { $0.weight > $1.weight }
    }

    /// Neighbours drawn in the ego ring (the rest are listed in the panel).
    var cappedNeighbours: [Neighbour] { Array(selectedNeighbours.prefix(neighbourCap)) }
    var extraNeighbourCount: Int { max(0, selectedNeighbours.count - neighbourCap) }

    /// Topics visible in the ego view: the selected node plus its ring neighbours.
    var focusVisibleIDs: Set<String> {
        guard let id = selectedTopicID else { return [] }
        return Set([id] + cappedNeighbours.map(\.id))
    }

    /// Shared-meeting count between `nodeID` and the selected topic, if connected.
    func weightToSelected(_ nodeID: String) -> Int? {
        selectedNeighbours.first { $0.id == nodeID }?.weight
    }

    func isConnectedToSelected(_ nodeID: String) -> Bool {
        guard let selID = selectedTopicID,
              let selIdx = nodes.firstIndex(where: { $0.id == selID }),
              let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        return edges.contains { ($0.sourceIndex == selIdx && $0.targetIndex == nodeIdx)
            || ($0.sourceIndex == nodeIdx && $0.targetIndex == selIdx) }
    }

    func isConnectedToHovered(_ nodeID: String) -> Bool {
        guard let hovID = hoveredTopicID,
              let hovIdx = nodes.firstIndex(where: { $0.id == hovID }),
              let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return false }
        return edges.contains { ($0.sourceIndex == hovIdx && $0.targetIndex == nodeIdx)
            || ($0.sourceIndex == nodeIdx && $0.targetIndex == hovIdx) }
    }
}
