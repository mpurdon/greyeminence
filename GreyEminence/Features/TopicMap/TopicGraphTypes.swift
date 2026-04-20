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
