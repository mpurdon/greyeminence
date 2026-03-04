import SwiftUI

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timestamp
            Text(segment.formattedTimestamp)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)

            // Speaker badge
            SpeakerBadge(speaker: segment.speaker)

            // Text
            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .italic(!segment.isFinal)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(segment.isFinal ? 1.0 : 0.7)
    }
}

struct SpeakerBadge: View {
    let speaker: Speaker

    var body: some View {
        Text(speaker.displayName)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        speaker.color
    }
}
