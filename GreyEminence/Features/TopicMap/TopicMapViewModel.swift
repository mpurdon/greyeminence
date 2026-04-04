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

    // Simulation
    private(set) var isSimulating = false
    private var simulationTask: Task<Void, Never>?

    // Aggregated data
    private(set) var topicMeetings: [String: [Meeting]] = [:]
    private var coOccurrence: [TopicPair: Int] = [:]
    var maxNodeCount = 40
    var minEdgeWeight = 2

    // MARK: - Graph Building

    func buildGraph(from insights: [MeetingInsight], canvasSize: CGSize) {
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
        coOccurrence = [:]

        for (meetingID, insight) in latestByMeeting {
            let meeting = insight.meeting!
            let normalized = insight.topics.map { normalize($0) }
            let unique = Array(Set(normalized))

            for (i, norm) in unique.enumerated() {
                let original = insight.topics.first { normalize($0) == norm } ?? norm
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
                position: pos,
                radius: TopicNode.radius(for: count),
                color: TopicNode.color(for: norm)
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

        nodes = newNodes
        edges = newEdges

        // Reset view state
        scale = 1.0
        offset = .zero
        selectedTopicID = nil

        startSimulation(center: center)
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
            selectedTopicID = (selectedTopicID == id) ? nil : id
        } else {
            selectedTopicID = nil
        }
    }

    func beginPan() {
        dragStartOffset = offset
    }

    func updatePan(translation: CGSize) {
        offset = CGPoint(
            x: dragStartOffset.x + translation.width,
            y: dragStartOffset.y + translation.height
        )
    }

    func updateZoom(_ magnification: CGFloat, anchor: CGPoint) {
        let newScale = max(0.3, min(3.0, scale * magnification))
        // Zoom toward anchor point
        let factor = newScale / scale
        offset.x = anchor.x - (anchor.x - offset.x) * factor
        offset.y = anchor.y - (anchor.y - offset.y) * factor
        scale = newScale
    }

    func resetView(canvasSize: CGSize) {
        withAnimation(.easeInOut(duration: 0.3)) {
            scale = 1.0
            offset = .zero
        }
    }

    // MARK: - Visual State

    var searchMatches: Set<String> {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return Set(nodes.filter { $0.label.lowercased().contains(query) }.map(\.id))
    }

    var isSearchActive: Bool { !searchText.isEmpty }

    /// Nodes sorted by meeting count descending, then label ascending.
    var rankedNodes: [TopicNode] {
        let filtered: [TopicNode]
        if isSearchActive {
            filtered = nodes.filter { searchMatches.contains($0.id) }
        } else {
            filtered = nodes
        }
        return filtered.sorted {
            if $0.meetingCount != $1.meetingCount {
                return $0.meetingCount > $1.meetingCount
            }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    var maxMeetingCount: Int {
        nodes.map(\.meetingCount).max() ?? 1
    }

    func nodeOpacity(for node: TopicNode) -> Double {
        if !isSearchActive { return 1.0 }
        return searchMatches.contains(node.id) ? 1.0 : 0.12
    }

    func edgeOpacity(for edge: TopicEdge) -> Double {
        let baseOpacity = min(Double(edge.weight) / 5.0, 0.8)
        if !isSearchActive { return baseOpacity }
        let sourceMatch = searchMatches.contains(nodes[edge.sourceIndex].id)
        let targetMatch = searchMatches.contains(nodes[edge.targetIndex].id)
        return (sourceMatch && targetMatch) ? baseOpacity : 0.03
    }

    func edgeWidth(for edge: TopicEdge) -> CGFloat {
        CGFloat(min(edge.weight, 8)) * 0.5 + 0.5
    }

    var selectedNode: TopicNode? {
        guard let id = selectedTopicID else { return nil }
        return nodes.first { $0.id == id }
    }

    var selectedMeetings: [Meeting] {
        guard let node = selectedNode else { return [] }
        return topicMeetings[node.label] ?? []
    }

    var selectedCoTopics: [String] {
        guard let id = selectedTopicID,
              let idx = nodes.firstIndex(where: { $0.id == id }) else { return [] }
        var related: [String: Int] = [:]
        for edge in edges {
            if edge.sourceIndex == idx {
                related[nodes[edge.targetIndex].label] = edge.weight
            } else if edge.targetIndex == idx {
                related[nodes[edge.sourceIndex].label] = edge.weight
            }
        }
        return related.sorted { $0.value > $1.value }.map(\.key)
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
