import SwiftUI

struct TopicNode: Identifiable {
    let id: String          // normalized (lowercased) topic label
    let label: String       // display form (most frequent casing)
    let meetingCount: Int
    let meetingIDs: Set<UUID>
    var position: CGPoint
    var velocity: CGPoint = .zero
    var radius: CGFloat
    let color: Color

    static func color(for id: String) -> Color {
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    static func radius(for meetingCount: Int) -> CGFloat {
        let base: CGFloat = 12
        let scale: CGFloat = 8
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
