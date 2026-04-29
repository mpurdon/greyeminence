import Foundation
import SwiftUI

enum ReProcessingState: String, Codable, CaseIterable, Sendable {
    case queued
    case transcribing
    case analyzing
    case reindexing
    case cancelling
    case failed

    var label: String {
        switch self {
        case .queued: "Queued"
        case .transcribing: "Re-transcribing"
        case .analyzing: "Analyzing"
        case .reindexing: "Indexing"
        case .cancelling: "Cancelling…"
        case .failed: "Failed"
        }
    }

    var stepDescription: String {
        switch self {
        case .queued: "Queued"
        case .transcribing: "Re-transcribing audio (WhisperKit large-v3)"
        case .analyzing: "Rebuilding AI summary and tasks"
        case .reindexing: "Updating semantic search index"
        case .cancelling: "Cancelling — finishing current sub-chunk"
        case .failed: "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .queued: .secondary
        case .transcribing: .blue
        case .analyzing: .purple
        case .reindexing: .teal
        case .cancelling: .secondary
        case .failed: .orange
        }
    }
}

struct StatusPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}
