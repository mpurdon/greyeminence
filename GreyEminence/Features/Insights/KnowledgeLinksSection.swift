import SwiftUI

struct KnowledgeLinksSection: View {
    let topics: [String]
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            FlowLayout(spacing: 6) {
                ForEach(topics, id: \.self) { topic in
                    TopicBadge(topic: topic)
                }
            }
            .padding(.top, 4)
        } label: {
            Label {
                Text("Topics")
            } icon: {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.purple.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal)
    }
}

// MARK: - Topic Navigation Environment

private struct TopicMapViewModelKey: EnvironmentKey {
    static let defaultValue: TopicMapViewModel? = nil
}

extension EnvironmentValues {
    var topicMapViewModel: TopicMapViewModel? {
        get { self[TopicMapViewModelKey.self] }
        set { self[TopicMapViewModelKey.self] = newValue }
    }
}

// MARK: - Topic Badge

struct TopicBadge: View {
    let topic: String
    @Environment(\.topicMapViewModel) private var topicMapViewModel

    var body: some View {
        Button {
            topicMapViewModel?.pendingFocusTopic = topic
        } label: {
            Text(topic)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.purple.opacity(0.1), in: Capsule())
                .foregroundStyle(.purple)
        }
        .buttonStyle(.plain)
        .help("View in Topic Map")
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = CGPoint(
                x: bounds.minX + result.positions[index].x,
                y: bounds.minY + result.positions[index].y
            )
            subview.place(at: point, anchor: .topLeading, proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxHeight = max(maxHeight, y + rowHeight)
        }

        return (positions, CGSize(width: maxWidth, height: maxHeight))
    }
}
