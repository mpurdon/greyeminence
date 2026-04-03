import CoreGraphics

enum ForceSimulation {
    static func step(
        nodes: inout [TopicNode],
        edges: [TopicEdge],
        center: CGPoint,
        damping: CGFloat = 0.85
    ) {
        let repulsionStrength: CGFloat = 8000
        let attractionStrength: CGFloat = 0.005
        let centerGravity: CGFloat = 0.01
        let maxRepulsionDist: CGFloat = 500

        let count = nodes.count
        guard count > 0 else { return }

        // Repulsion: every pair pushes apart
        for i in 0..<count {
            for j in (i + 1)..<count {
                var dx = nodes[i].position.x - nodes[j].position.x
                var dy = nodes[i].position.y - nodes[j].position.y
                let dist = max(hypot(dx, dy), 1)
                guard dist < maxRepulsionDist else { continue }

                // Scale repulsion by combined radii so larger nodes push harder
                let radiusScale = (nodes[i].radius + nodes[j].radius) / 24
                let force = repulsionStrength * radiusScale / (dist * dist)
                dx = dx / dist * force
                dy = dy / dist * force

                nodes[i].velocity.x += dx
                nodes[i].velocity.y += dy
                nodes[j].velocity.x -= dx
                nodes[j].velocity.y -= dy
            }
        }

        // Attraction along edges
        for edge in edges {
            let i = edge.sourceIndex
            let j = edge.targetIndex
            guard i < count, j < count else { continue }

            let dx = nodes[j].position.x - nodes[i].position.x
            let dy = nodes[j].position.y - nodes[i].position.y
            let dist = max(hypot(dx, dy), 1)

            let restLength = nodes[i].radius + nodes[j].radius + 40
            let displacement = dist - restLength
            let weightScale = CGFloat(min(edge.weight, 10)) / 3.0
            let force = attractionStrength * displacement * weightScale

            let fx = dx / dist * force
            let fy = dy / dist * force

            nodes[i].velocity.x += fx
            nodes[i].velocity.y += fy
            nodes[j].velocity.x -= fx
            nodes[j].velocity.y -= fy
        }

        // Center gravity
        for i in 0..<count {
            let dx = center.x - nodes[i].position.x
            let dy = center.y - nodes[i].position.y
            nodes[i].velocity.x += dx * centerGravity
            nodes[i].velocity.y += dy * centerGravity
        }

        // Apply velocity with damping
        for i in 0..<count {
            nodes[i].velocity.x *= damping
            nodes[i].velocity.y *= damping
            nodes[i].position.x += nodes[i].velocity.x
            nodes[i].position.y += nodes[i].velocity.y
        }
    }

    static func maxVelocity(in nodes: [TopicNode]) -> CGFloat {
        nodes.map { hypot($0.velocity.x, $0.velocity.y) }.max() ?? 0
    }
}
