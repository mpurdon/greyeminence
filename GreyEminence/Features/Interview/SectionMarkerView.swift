import SwiftUI

/// A visual divider shown in the transcript when the interview section changes.
struct SectionMarkerView: View {
    let title: String
    let timestamp: String?

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.cyan.opacity(0.4))
                .frame(height: 1)
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 8))
                Text(title)
                    .font(.caption2.weight(.bold))
                if let timestamp {
                    Text(timestamp)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.cyan.opacity(0.1), in: Capsule())
            Rectangle()
                .fill(.cyan.opacity(0.4))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}
