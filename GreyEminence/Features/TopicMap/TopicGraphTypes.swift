import SwiftUI

struct TopicNode: Identifiable {
    let id: String          // normalized (lowercased) topic label
    let label: String       // display form (most frequent casing)
    let meetingCount: Int
    let meetingIDs: Set<UUID>
    let lastMeetingDate: Date?
    var position: CGPoint
    var velocity: CGPoint = .zero
    var radius: CGFloat
    let color: Color
    /// From the topic catalog; nil until the topic is classified.
    var kind: TopicKind? = nil
    /// Other names counted under this topic ("Carlos" under "Carlos Ayala
    /// Gonzalez"), as they were written.
    var aliases: [String] = []

    static func color(for id: String) -> Color {
        // Monochrome — all nodes use the same base color;
        // selection/hover state controls visual emphasis.
        .secondary
    }

    static func radius(for meetingCount: Int) -> CGFloat {
        let base: CGFloat = 4
        let scale: CGFloat = 4
        return base + log2(CGFloat(max(meetingCount, 1))) * scale
    }
}

struct TopicEdge {
    let sourceIndex: Int
    let targetIndex: Int
    let weight: Int         // co-occurrence count
    /// True for each node's strongest few incident edges — the "backbone" drawn
    /// in the unselected overview so it's a readable skeleton, not a hairball.
    var isBackbone = false
}

struct TopicPair: Hashable {
    let a: String
    let b: String

    init(_ x: String, _ y: String) {
        if x < y {
            a = x; b = y
        } else {
            a = y; b = x
        }
    }
}
