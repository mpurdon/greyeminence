import SwiftUI

/// A flow drawn from its layout: nodes where `FlowDiagramLayout` puts them,
/// arrows underneath. Scrolls both ways when it's bigger than the pane.
struct FlowDiagramView: View {
    let flow: FlowDiagram
    /// Computed once by the caller, which also sizes around it.
    let layout: FlowDiagramLayout
    var selectedNodeID: String?
    var onSelect: ((String?) -> Void)?

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            FlowCanvas(flow: flow, layout: layout, selectedNodeID: selectedNodeID, onSelect: onSelect)
                .frame(width: layout.size.width, height: layout.size.height)
        }
    }
}

/// The drawing itself, at its natural size — also what the PDF and PNG
/// exports render.
struct FlowCanvas: View {
    let flow: FlowDiagram
    let layout: FlowDiagramLayout
    var selectedNodeID: String?
    var onSelect: ((String?) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onSelect?(nil) }
            Canvas { context, _ in
                for route in layout.routes {
                    draw(route, in: &context)
                }
            }
            ForEach(layout.routes) { route in
                if let label = route.edge.label?.nonEmpty {
                    Text(label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                        .overlay(Capsule().strokeBorder(.separator))
                        .fixedSize()
                        .position(route.labelPoint)
                }
            }
            ForEach(flow.nodes) { node in
                if let frame = layout.frames[node.id] {
                    FlowNodeView(node: node, isSelected: node.id == selectedNodeID)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .onTapGesture { onSelect?(node.id) }
                }
            }
        }
    }

    private func draw(_ route: FlowDiagramLayout.Route, in context: inout GraphicsContext) {
        var path = Path()
        let direction: CGVector
        path.move(to: route.from)
        if let laneX = route.laneX {
            // Out to the lane, up (or down) it, and back in.
            path.addLine(to: CGPoint(x: laneX, y: route.from.y))
            path.addLine(to: CGPoint(x: laneX, y: route.to.y))
            path.addLine(to: route.to)
            direction = CGVector(dx: route.to.x - laneX, dy: 0)
        } else {
            // Straight down through a layer it passes; an S-bend, leaving
            // and arriving vertically, between layers.
            for (start, end) in zip(route.points, route.points.dropFirst()) {
                if abs(start.x - end.x) < 0.5 {
                    path.addLine(to: end)
                } else {
                    let midY = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
                }
            }
            direction = CGVector(dx: 0, dy: 1)
        }
        let style = StrokeStyle(lineWidth: 1.4, dash: route.laneX == nil ? [] : [4, 3])
        context.stroke(path, with: .color(.secondary), style: style)
        context.fill(arrowhead(at: route.to, direction: direction), with: .color(.secondary))
    }

    private func arrowhead(at tip: CGPoint, direction: CGVector) -> Path {
        let length = max(hypot(direction.dx, direction.dy), 0.001)
        let (ux, uy) = (direction.dx / length, direction.dy / length)
        let size: CGFloat = 7
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * size * 0.6, y: base.y + ux * size * 0.6))
        path.addLine(to: CGPoint(x: base.x + uy * size * 0.6, y: base.y - ux * size * 0.6))
        path.closeSubpath()
        return path
    }
}

struct FlowNodeView: View {
    let node: FlowDiagram.Node
    var isSelected = false

    var body: some View {
        ZStack {
            shape
                .fill(tint.opacity(0.12))
            shape
                .stroke(isSelected ? Color.accentColor : tint.opacity(0.7), lineWidth: isSelected ? 2.5 : 1.2)
            VStack(spacing: 2) {
                Text(node.label)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                if let actor = node.actor?.nonEmpty {
                    Text(actor)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, node.kind == .decision ? 30 : 10)
            .padding(.vertical, 6)
        }
        .contentShape(shape)
        .help(node.note ?? node.label)
    }

    private var shape: AnyShape {
        switch node.kind {
        case .start, .end: AnyShape(Capsule())
        case .decision: AnyShape(Diamond())
        case .step: AnyShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var tint: Color {
        switch node.kind {
        case .start: .green
        case .end: .gray
        case .decision: .orange
        case .step: .accentColor
        }
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
