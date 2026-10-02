import SwiftUI

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    var confidence: Float?
    var onLinkSpeaker: ((Speaker) -> Void)?

    @State private var showContactPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Header line: speaker · timestamp · flags. Keeping these on their own
            // row lets the spoken text use the full width below instead of being
            // squeezed into the column to the right of the badge.
            HStack(spacing: 6) {
                SpeakerBadge(speaker: segment.speaker)
                    .contextMenu {
                        if onLinkSpeaker != nil {
                            Button("Link to Contact...") {
                                showContactPicker = true
                            }
                        }
                    }
                    .popover(isPresented: $showContactPicker) {
                        ContactPicker(
                            excludedContacts: [],
                            prioritizedContacts: segment.meeting?.presentAttendees ?? []
                        ) { contact in
                            onLinkSpeaker?(segment.speaker)
                            showContactPicker = false
                        }
                    }

                Text(segment.formattedTimestamp)
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.tertiary)

                if segment.isEdited {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Edited")
                }

                // Confidence dot (only shown for live, low-confidence segments)
                if let conf = confidence, conf < 0.6 {
                    Circle()
                        .fill(conf < 0.3 ? Color.red : Color.yellow)
                        .frame(width: 6, height: 6)
                        .help(String(format: "Confidence: %.0f%%", conf * 100))
                }

                Spacer(minLength: 0)
            }

            // Spoken text — full width, always wraps (never truncated/clipped).
            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .italic(!segment.isFinal)
                .textSelection(.enabled)
                .opacity(confidenceOpacity)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .opacity(segment.isFinal ? 1.0 : 0.7)
    }

    private var confidenceOpacity: Double {
        guard let conf = confidence else { return 1.0 }
        if conf >= 0.6 { return 1.0 }
        if conf >= 0.3 { return 0.8 }
        return 0.6
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
