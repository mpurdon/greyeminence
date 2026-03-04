import Foundation
import SwiftUI

enum Speaker: Codable, Hashable, Sendable {
    case me
    case other(String)

    var displayName: String {
        switch self {
        case .me: "Me"
        case .other(let name): name
        }
    }

    var initials: String {
        switch self {
        case .me:
            return "ME"
        case .other(let name):
            let parts = name.split(separator: " ")
            if parts.count >= 2 {
                return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }
    }

    var isMe: Bool {
        if case .me = self { return true }
        return false
    }

    /// Stable color assignment based on speaker identity.
    var color: Color {
        switch self {
        case .me:
            return .blue
        case .other(let name):
            return Self.speakerColors[Self.colorIndex(for: name)]
        }
    }

    private static let speakerColors: [Color] = [
        .green,
        .orange,
        .purple,
        .pink,
        .teal,
        .indigo,
        .mint,
        .cyan,
    ]

    private static func colorIndex(for name: String) -> Int {
        // Stable hash-based color assignment so a given speaker name
        // always gets the same color within a session
        let hash = abs(name.hashValue)
        return hash % speakerColors.count
    }
}
