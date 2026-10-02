import CoreGraphics
import Foundation

/// Where every node and arrow of a flow goes: top to bottom in layers, so
/// a sequence reads downward and branches spread sideways.
///
/// The usual layered layout, kept small: loops are found and set aside
/// (drawn as arrows back up the right-hand side), each node's layer is its
/// longest path from a start, an arrow that skips layers gets a waypoint in
/// each layer it passes so it runs between nodes rather than across them,
/// the order within each layer is swept toward the neighbours' average
/// position and the sweep with fewest crossings kept, and each node then
/// slides sideways toward what it connects to, so chains run straight.
struct FlowDiagramLayout: Equatable {
    struct Route: Equatable, Identifiable {
        let edge: FlowDiagram.Edge
        /// From the source's edge to the target's, through a waypoint pair
        /// (top and bottom of the row) for every layer it passes.
        let points: [CGPoint]
        /// Back up the side, for a retry or loop; nil for a downward arrow.
        let laneX: CGFloat?
        var id: String { edge.id }

        var from: CGPoint { points[0] }
        var to: CGPoint { points[points.count - 1] }

        /// Where the edge's label sits: on the first leg, so a decision's
        /// branch labels sit apart, by the decision.
        var labelPoint: CGPoint {
            if let laneX { return CGPoint(x: laneX, y: (from.y + to.y) / 2) }
            let next = points[1]
            return CGPoint(x: (from.x + next.x) / 2, y: (from.y + next.y) / 2)
        }
    }

    static let nodeWidth: CGFloat = 200
    static let nodeHeight: CGFloat = 64
    static let decisionHeight: CGFloat = 88
    static let rankGap: CGFloat = 52
    static let columnGap: CGFloat = 40
    static let margin: CGFloat = 24
    static let laneGap: CGFloat = 22
    /// The width an arrow passing through a layer takes up in it.
    static let waypointWidth: CGFloat = 12
    static let waypointGap: CGFloat = 18

    let frames: [String: CGRect]
    /// Layer of each node, from 0 at the top.
    let ranks: [String: Int]
    let routes: [Route]
    let size: CGSize

    init(_ flow: FlowDiagram) {
        // A model sometimes repeats an ID; the first node with it wins.
        var seenIDs = Set<String>()
        let nodes = flow.nodes.filter { seenIDs.insert($0.id).inserted }
        let ids = nodes.map(\.id)
        let edges = flow.validEdges
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        var successors: [String: [String]] = [:]
        var incoming: [String: Int] = [:]
        for edge in edges {
            successors[edge.from, default: []].append(edge.to)
            incoming[edge.to, default: 0] += 1
        }

        // Where to start walking: declared starts, else nodes nothing
        // points at, else the first node.
        var sources = nodes.filter { $0.kind == .start }.map(\.id)
        if sources.isEmpty { sources = ids.filter { (incoming[$0] ?? 0) == 0 } }
        if sources.isEmpty, let first = ids.first { sources = [first] }

        // Loops: an edge to a node still on the walk's stack goes back.
        func key(_ from: String, _ to: String) -> String { "\(from)→\(to)" }
        var backEdges = Set<String>()
        var state: [String: Int] = [:] // 1 on the stack, 2 done
        func walk(_ id: String) {
            state[id] = 1
            for next in successors[id] ?? [] {
                switch state[next] {
                case 1: backEdges.insert(key(id, next))
                case nil: walk(next)
                default: break
                }
            }
            state[id] = 2
        }
        for source in sources where state[source] == nil { walk(source) }
        for id in ids where state[id] == nil { walk(id) }

        let forward = edges.filter { !backEdges.contains(key($0.from, $0.to)) }

        // Layers: longest path from a source, over the loop-free edges.
        var rank: [String: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        var indegree: [String: Int] = [:]
        var next: [String: [String]] = [:]
        for edge in forward {
            indegree[edge.to, default: 0] += 1
            next[edge.from, default: []].append(edge.to)
        }
        var queue = ids.filter { (indegree[$0] ?? 0) == 0 }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for target in next[id] ?? [] {
                rank[target] = max(rank[target] ?? 0, (rank[id] ?? 0) + 1)
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 { queue.append(target) }
            }
        }

        // Arrows that skip layers: a waypoint in each layer passed, joined
        // into a chain the ordering and placement treat like nodes.
        var unitRank = rank
        var unitOrder = order
        var below: [String: [String]] = [:]
        var above: [String: [String]] = [:]
        var waypoints: [Int: [String]] = [:] // index in `edges` → its chain
        for (index, edge) in edges.enumerated() where !backEdges.contains(key(edge.from, edge.to)) {
            let top = rank[edge.from] ?? 0, bottom = rank[edge.to] ?? 0
            var chain: [String] = []
            if bottom - top > 1 {
                for r in (top + 1)..<bottom {
                    let id = "\u{1}\(index)·\(r)"
                    chain.append(id)
                    unitRank[id] = r
                    unitOrder[id] = order[edge.from] ?? 0
                }
            }
            waypoints[index] = chain
            let path = [edge.from] + chain + [edge.to]
            for (upper, lower) in zip(path, path.dropFirst()) {
                below[upper, default: []].append(lower)
                above[lower, default: []].append(upper)
            }
        }
        let isNode = Set(ids)

        // Order within layers: swept toward neighbours' average position,
        // keeping whichever ordering crosses least.
        let maxRank = rank.values.max() ?? 0
        var layers: [[String]] = (0...maxRank).map { r in
            unitRank.keys.filter { unitRank[$0] == r }.sorted { (unitOrder[$0] ?? 0, $0) < (unitOrder[$1] ?? 0, $1) }
        }
        func positions(_ layer: [String]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: layer.enumerated().map { ($1, Double($0) - Double(layer.count - 1) / 2) })
        }
        struct SortKey {
            let id: String
            let center: Double
            let order: Int
        }
        func sweep(_ layerIndex: Int, toward neighbourLayer: Int, neighbours: [String: [String]]) {
            let current = layers[layerIndex]
            let around = positions(layers[neighbourLayer])
            var keys: [SortKey] = []
            for (index, id) in current.enumerated() {
                let placed = (neighbours[id] ?? []).compactMap { around[$0] }
                let center = placed.isEmpty
                    ? Double(index) - Double(current.count - 1) / 2
                    : placed.reduce(0, +) / Double(placed.count)
                keys.append(SortKey(id: id, center: center, order: unitOrder[id] ?? 0))
            }
            keys.sort { a, b in a.center != b.center ? a.center < b.center : a.order < b.order }
            layers[layerIndex] = keys.map(\.id)
        }
        func crossings() -> Int {
            var total = 0
            for r in 0..<maxRank {
                let upper = positions(layers[r]), lower = positions(layers[r + 1])
                let links = layers[r].flatMap { id in (below[id] ?? []).compactMap { lower[$0].map { (upper[id] ?? 0, $0) } } }
                for i in links.indices { for j in links.indices where i < j {
                    let (a, b) = (links[i], links[j])
                    if (a.0 - b.0) * (a.1 - b.1) < 0 { total += 1 }
                } }
            }
            return total
        }
        var best = layers
        var fewest = crossings()
        for _ in 0..<8 where maxRank > 0 && fewest > 0 {
            for r in 1...maxRank { sweep(r, toward: r - 1, neighbours: above) }
            for r in stride(from: maxRank - 1, through: 0, by: -1) { sweep(r, toward: r + 1, neighbours: below) }
            let count = crossings()
            if count < fewest { fewest = count; best = layers }
        }
        layers = best

        // Across: each layer packed, then nodes slid toward the average of
        // what they connect to — alternately above and below — keeping
        // their order and spacing.
        func width(_ id: String) -> CGFloat { isNode.contains(id) ? Self.nodeWidth : Self.waypointWidth }
        func separation(_ a: String, _ b: String) -> CGFloat {
            let gap = isNode.contains(a) && isNode.contains(b) ? Self.columnGap : Self.waypointGap
            return (width(a) + width(b)) / 2 + gap
        }
        var x: [String: CGFloat] = [:]
        for layer in layers {
            var cursor: CGFloat = 0
            for (index, id) in layer.enumerated() {
                if index > 0 { cursor += separation(layer[index - 1], id) }
                x[id] = cursor
            }
            let shift = -cursor / 2
            for id in layer { x[id, default: 0] += shift }
        }
        for pass in 0..<8 where maxRank > 0 {
            let downward = pass.isMultiple(of: 2)
            let sequence = downward ? Array(1...maxRank) : Array(stride(from: maxRank - 1, through: 0, by: -1))
            for r in sequence {
                let layer = layers[r]
                let desired = layer.map { id -> CGFloat in
                    let linked = ((downward ? above[id] : below[id]) ?? []).compactMap { x[$0] }
                    return linked.isEmpty ? x[id] ?? 0 : linked.reduce(0, +) / CGFloat(linked.count)
                }
                let placed = Self.placeInOrder(desired: desired, separations: zip(layer, layer.dropFirst()).map(separation))
                for (id, value) in zip(layer, placed) { x[id] = value }
            }
        }
        let left = layers.flatMap { $0 }.map { (x[$0] ?? 0) - width($0) / 2 }.min() ?? 0
        let rightmost = layers.flatMap { $0 }.map { (x[$0] ?? 0) + width($0) / 2 }.max() ?? 0
        let contentWidth = rightmost - left
        for id in x.keys { x[id, default: 0] += Self.margin - left }

        // Down: a row per layer, as tall as its tallest node.
        let kinds = Dictionary(nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        func height(_ id: String) -> CGFloat { kinds[id] == .decision ? Self.decisionHeight : Self.nodeHeight }
        var frames: [String: CGRect] = [:]
        var rows: [ClosedRange<CGFloat>] = []
        var y = Self.margin
        for layer in layers {
            let rowHeight = layer.filter(isNode.contains).map(height).max() ?? Self.nodeHeight
            rows.append(y...(y + rowHeight))
            for id in layer where isNode.contains(id) {
                let h = height(id)
                frames[id] = CGRect(x: (x[id] ?? 0) - Self.nodeWidth / 2, y: y + (rowHeight - h) / 2, width: Self.nodeWidth, height: h)
            }
            y += rowHeight + Self.rankGap
        }

        // Routes: down from the bottom of one node through its waypoints to
        // the top of the next; loops out of the right side and back up a
        // lane of their own.
        let right = Self.margin + contentWidth
        var lane = 0
        var routes: [Route] = []
        for (index, edge) in edges.enumerated() {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            if let chain = waypoints[index] {
                let through = chain.flatMap { id -> [CGPoint] in
                    let row = rows[unitRank[id] ?? 0]
                    return [CGPoint(x: x[id] ?? 0, y: row.lowerBound), CGPoint(x: x[id] ?? 0, y: row.upperBound)]
                }
                routes.append(Route(
                    edge: edge,
                    points: [CGPoint(x: from.midX, y: from.maxY)] + through + [CGPoint(x: to.midX, y: to.minY)],
                    laneX: nil
                ))
            } else {
                lane += 1
                routes.append(Route(
                    edge: edge,
                    points: [CGPoint(x: from.maxX, y: from.midY), CGPoint(x: to.maxX, y: to.midY)],
                    laneX: right + CGFloat(lane) * Self.laneGap
                ))
            }
        }

        self.frames = frames
        self.ranks = rank
        self.routes = routes
        self.size = CGSize(
            width: right + CGFloat(lane) * Self.laneGap + Self.margin + (lane > 0 ? 40 : 0),
            height: y - Self.rankGap + Self.margin
        )
    }

    /// Positions as close as possible to `desired` (least squares) that keep
    /// their order with at least `separations[i]` between neighbours i and
    /// i+1: subtract each one's minimum offset, fit a non-decreasing
    /// sequence by pooling adjacent violators, add the offsets back.
    static func placeInOrder(desired: [CGFloat], separations: [CGFloat]) -> [CGFloat] {
        guard !desired.isEmpty else { return [] }
        var offsets: [CGFloat] = [0]
        for gap in separations { offsets.append(offsets[offsets.count - 1] + gap) }
        var blocks: [(mean: CGFloat, count: Int)] = []
        for (value, offset) in zip(desired, offsets) {
            blocks.append((value - offset, 1))
            while blocks.count > 1, blocks[blocks.count - 2].mean > blocks[blocks.count - 1].mean {
                let last = blocks.removeLast(), prior = blocks.removeLast()
                let count = prior.count + last.count
                blocks.append(((prior.mean * CGFloat(prior.count) + last.mean * CGFloat(last.count)) / CGFloat(count), count))
            }
        }
        let fitted = blocks.flatMap { Array(repeating: $0.mean, count: $0.count) }
        return zip(fitted, offsets).map { $0 + $1 }
    }
}
